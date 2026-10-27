#requires -version 5.1
# DSH Inventory - local read-only index server.
# Scans the DeepSeek Harness installation and serves a small static app.
param(
    [switch]$NoBrowser,
    [switch]$ForceNew
)

$ErrorActionPreference = 'Stop'
$script:AppDir      = $PSScriptRoot
$script:AppVersion  = '1.0.0'
$script:DataDir     = Join-Path $script:AppDir 'data'
$script:StatePath   = Join-Path $script:DataDir 'state.json'
$script:CachePath   = Join-Path $script:DataDir 'asar-cache.json'
$script:LogPath     = Join-Path $script:DataDir 'server.log'
$script:PortPath    = Join-Path $script:DataDir 'port.txt'
$script:CuratedPath = Join-Path $script:AppDir 'app\curated.json'
$script:BasePort    = 28173
$script:MaxPort     = 28193
$script:IdleSeconds = 300
$script:LastHit     = Get-Date
$script:StartedAt   = 0
$script:Port        = 0
$script:Catalog     = $null
$script:CatalogAt   = [datetime]::MinValue
$script:State       = $null
$script:Curated     = $null
$script:CuratedAt   = [datetime]::MinValue
$script:HubDisabled = @()
$script:HubStats    = @{}
$script:AsarText    = $null
$script:AsarKey     = ''
$script:AsarEntryKey = ''
$script:SeenSkills  = @{}
$script:Changes     = $null
$script:InstanceMutex = $null

function Get-EpochMs {
    param([datetime]$Date)
    $epoch = [datetime]::SpecifyKind([datetime]'1970-01-01', [System.DateTimeKind]::Utc)
    return [long](($Date.ToUniversalTime() - $epoch).TotalMilliseconds)
}

function Write-Log {
    param([string]$Message)
    try {
        $line = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $Message
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    } catch { }
}

function Read-TextFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Write-TextFile {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-ShortHash {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
        return ([System.BitConverter]::ToString($bytes)).Replace('-', '').Substring(0, 12).ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-FirstSentence {
    param([string]$Text, [int]$Max = 108)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $clean = ($Text -replace '\s+', ' ').Trim()
    $m = [regex]::Match($clean, '^(.+?[\.\u3002\uff01\uff1f])(\s|$)')
    if ($m.Success) { $clean = $m.Groups[1].Value.Trim() }
    if ($clean.Length -gt $Max) { $clean = $clean.Substring(0, $Max - 1).TrimEnd() + [char]0x2026 }
    return $clean
}

# ---------------------------------------------------------------- discovery

function Resolve-DshRoot {
    $configPath = Join-Path $script:DataDir 'config.json'
    if (Test-Path -LiteralPath $configPath) {
        try {
            $cfg = (Read-TextFile $configPath) | ConvertFrom-Json
            if ($cfg.dshRoot -and (Test-Path -LiteralPath (Join-Path $cfg.dshRoot 'resources\app.asar'))) {
                return (Resolve-Path -LiteralPath $cfg.dshRoot).Path
            }
        } catch { }
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($proc in Get-Process -ErrorAction SilentlyContinue) {
            $p = $null
            try { $p = $proc.Path } catch { $p = $null }
            if ($p -and ($p -like '*DeepSeek Harness.exe')) {
                $dir = Split-Path -Parent $p
                if (-not $candidates.Contains($dir)) { $candidates.Add($dir) }
            }
        }
    } catch { }

    try {
        $keys = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        foreach ($k in $keys) {
            $entries = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
            foreach ($e in $entries) {
                if ($e.DisplayName -notlike '*DeepSeek*Harness*') { continue }
                if ($e.InstallLocation) { $candidates.Add($e.InstallLocation.Trim('"', ' ')) }
                if ($e.DisplayIcon) {
                    $icon = ($e.DisplayIcon -replace ',.*$', '').Trim('"', ' ')
                    if ($icon) { $candidates.Add((Split-Path -Parent $icon)) }
                }
            }
        }
    } catch { }

    $candidates.Add((Join-Path $env:USERPROFILE 'Desktop\Deepseekharness'))
    $candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness'))
    $candidates.Add((Join-Path $env:ProgramFiles 'DeepSeek Harness'))
    if (${env:ProgramFiles(x86)}) { $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'DeepSeek Harness')) }

    foreach ($c in $candidates) {
        if (-not $c) { continue }
        try {
            $full = [System.IO.Path]::GetFullPath($c)
            if (Test-Path -LiteralPath (Join-Path $full 'resources\app.asar')) { return $full }
        } catch { }
    }
    return $null
}

function Resolve-Profile {
    $dshHome = Join-Path $env:USERPROFILE '.dsh'
    $profiles = Join-Path $dshHome 'profiles'
    $names = @('desktop')
    $dirs = @()
    if (Test-Path -LiteralPath $profiles) {
        $dirs = @(Get-ChildItem -LiteralPath $profiles -Directory -ErrorAction SilentlyContinue)
    }
    $profileDir = $null
    foreach ($name in $names) {
        $candidate = Join-Path $profiles $name
        if (Test-Path -LiteralPath $candidate) { $profileDir = $candidate; break }
    }
    if (-not $profileDir -and $dirs.Count -gt 0) {
        $profileDir = ($dirs | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).FullName
    }
    return [pscustomobject]@{
        Home        = $dshHome
        ProfileDir  = $profileDir
        ProfileName = if ($profileDir) { Split-Path -Leaf $profileDir } else { '' }
    }
}

function Resolve-DepDir {
    param([string]$Name, [string]$NodeModules)
    if ($Name -like '@*/*') {
        $parts = $Name.Split('/')
        return (Join-Path $NodeModules (Join-Path $parts[0] $parts[1]))
    }
    return (Join-Path $NodeModules $Name)
}

# ---------------------------------------------------------------- asar

function Read-AsarEntry {
    param([string]$AsarPath, [string]$Entry)
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($AsarPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $br = New-Object System.IO.BinaryReader($fs)
        $null = $br.ReadUInt32()
        $headerSize = [int64]$br.ReadUInt32()
        $null = $br.ReadUInt32()
        $jsonSize = [int64]$br.ReadUInt32()
        $fs.Position = 16
        $jsonBytes = $br.ReadBytes([int]$jsonSize)
        $json = [System.Text.Encoding]::UTF8.GetString($jsonBytes)
        $root = $json | ConvertFrom-Json
        $node = $root
        foreach ($seg in $Entry.Split('/')) {
            if (-not $node.files) { return $null }
            $prop = $node.files.PSObject.Properties[$seg]
            if (-not $prop) { return $null }
            $node = $prop.Value
        }
        $offset = [int64]$node.offset
        $size = [int64]$node.size
        $dataStart = 8 + $headerSize
        $fs.Position = $dataStart + $offset
        $bytes = $br.ReadBytes([int]$size)
        return [System.Text.Encoding]::UTF8.GetString($bytes)
    } catch {
        Write-Log ('asar read failed: ' + $_.Exception.Message)
        return $null
    } finally {
        if ($fs) { $fs.Close() }
    }
}

function Get-AsarText {
    param([string]$AsarPath, [string]$Entry)
    if (-not (Test-Path -LiteralPath $AsarPath)) { return $null }
    $fi = Get-Item -LiteralPath $AsarPath
    $key = ([string]$fi.Length) + ':' + ([string]$fi.LastWriteTimeUtc.Ticks)
    if ($script:AsarKey -eq $key -and $script:AsarEntryKey -eq $Entry -and $null -ne $script:AsarText) {
        return $script:AsarText
    }
    if (Test-Path -LiteralPath $script:CachePath) {
        try {
            $cache = (Read-TextFile $script:CachePath) | ConvertFrom-Json
            if ($cache.key -eq $key -and $cache.entry -eq $Entry -and $cache.text) {
                $script:AsarKey = $key
                $script:AsarEntryKey = $Entry
                $script:AsarText = [string]$cache.text
                return $script:AsarText
            }
        } catch { }
    }
    $text = Read-AsarEntry $AsarPath $Entry
    if ($null -ne $text) {
        $script:AsarKey = $key
        $script:AsarEntryKey = $Entry
        $script:AsarText = $text
        try {
            Write-TextFile $script:CachePath (([ordered]@{ key = $key; entry = $Entry; text = $text }) | ConvertTo-Json -Depth 4 -Compress)
        } catch { }
    }
    return $text
}

# ---------------------------------------------------------------- frontmatter

function Clean-YamlValue {
    param([string]$Value)
    $v = $Value.Trim()
    if ($v.Length -ge 2 -and $v.StartsWith('"') -and $v.EndsWith('"')) {
        $v = $v.Substring(1, $v.Length - 2)
        $v = $v.Replace('\"', '"').Replace('\n', ' ')
    } elseif ($v.Length -ge 2 -and $v.StartsWith("'") -and $v.EndsWith("'")) {
        $v = $v.Substring(1, $v.Length - 2).Replace("''", "'")
    }
    return ($v -replace '\s+', ' ').Trim()
}

function Get-SkillMeta {
    param([string]$Text, [string]$FallbackName)
    $name = $FallbackName
    $desc = ''
    if ([string]::IsNullOrWhiteSpace($Text)) { return [pscustomobject]@{ Name = $name; Description = '' } }
    $m = [regex]::Match($Text, '(?s)\A\uFEFF?---\s*\r?\n(.*?)\r?\n---')
    if ($m.Success) {
        $lines = $m.Groups[1].Value -split '\r?\n'
        for ($i = 0; $i -lt $lines.Length; $i++) {
            $line = $lines[$i]
            if ($line -match '^name:\s*(.+?)\s*$') {
                $name = Clean-YamlValue $Matches[1]
            } elseif ($line -match '^description:\s*(.*)$') {
                $v = $Matches[1].Trim()
                if ($v -match '^[>|][+-]?$') {
                    $parts = New-Object System.Collections.Generic.List[string]
                    for ($j = $i + 1; $j -lt $lines.Length; $j++) {
                        if ($lines[$j] -match '^\s+') { $parts.Add($lines[$j].Trim()) } else { break }
                    }
                    $desc = ($parts -join ' ')
                } else {
                    $desc = Clean-YamlValue $v
                }
            }
        }
    } else {
        $h = [regex]::Match($Text, '(?m)^#\s+(.+)$')
        if ($h.Success) { $name = $h.Groups[1].Value.Trim() }
        $p = [regex]::Match($Text, '(?ms)^#\s+.+?\r?\n\s*\r?\n(.+?)(\r?\n\s*\r?\n|\z)')
        if ($p.Success) { $desc = $p.Groups[1].Value.Trim() }
    }
    $desc = ($desc -replace '\s+', ' ').Trim()
    if (-not $name) { $name = $FallbackName }
    return [pscustomobject]@{ Name = $name; Description = $desc }
}

# ---------------------------------------------------------------- curated / hub

function Get-CuratedEntry {
    param([string]$Bucket, [string]$Key)
    if (-not $script:Curated -or -not $Key) { return $null }
    $b = $script:Curated.PSObject.Properties[$Bucket]
    if (-not $b) { return $null }
    $entry = $b.Value.PSObject.Properties[$Key]
    if ($entry) { return $entry.Value }
    return $null
}

function Read-Curated {
    if (-not (Test-Path -LiteralPath $script:CuratedPath)) { return }
    $fi = Get-Item -LiteralPath $script:CuratedPath
    if ($script:Curated -and $fi.LastWriteTimeUtc -le $script:CuratedAt) { return }
    try {
        $script:Curated = (Read-TextFile $script:CuratedPath) | ConvertFrom-Json
        $script:CuratedAt = $fi.LastWriteTimeUtc
    } catch {
        Write-Log ('curated.json parse failed: ' + $_.Exception.Message)
    }
}

function Read-HubState {
    $script:HubDisabled = @()
    $script:HubStats = @{}
    $hubPath = Join-Path $env:USERPROFILE '.dsh\dsh-skill-hub.json'
    if (-not (Test-Path -LiteralPath $hubPath)) { return }
    try {
        $hub = (Read-TextFile $hubPath) | ConvertFrom-Json
        if ($hub.disabled) { $script:HubDisabled = @($hub.disabled | ForEach-Object { [string]$_ }) }
        if ($hub.skillStats -and $hub.skillStats.lastTotals) {
            foreach ($s in @($hub.skillStats.lastTotals)) {
                if ($s -and $s.name) {
                    $script:HubStats[[string]$s.name] = [pscustomobject]@{
                        count    = [int]$s.count
                        lastUsed = [long]$s.lastUsed
                    }
                }
            }
        }
    } catch {
        Write-Log ('skill-hub state parse failed: ' + $_.Exception.Message)
    }
}

function Test-SkillDisabled {
    param([string]$Name, [string]$Dir, [string]$Id)
    foreach ($d in $script:HubDisabled) {
        if (-not $d) { continue }
        if ($d -eq $Name -or $d -eq $Dir -or $d -eq $Id) { return $true }
        if ($d.EndsWith('\' + $Dir) -or $d.EndsWith('/' + $Dir)) { return $true }
    }
    return $false
}

function Get-HubStat {
    param([string]$Name, [string]$Dir)
    if ($script:HubStats.ContainsKey($Name)) { return $script:HubStats[$Name] }
    if ($script:HubStats.ContainsKey($Dir)) { return $script:HubStats[$Dir] }
    return [pscustomobject]@{ count = 0; lastUsed = 0 }
}

# ---------------------------------------------------------------- scan

function Find-SkillDirs {
    param([string]$Root, [int]$Depth = 0)
    if ($Depth -gt 3 -or -not (Test-Path -LiteralPath $Root)) { return }
    $own = @(Get-ChildItem -LiteralPath $Root -File -Filter 'SKILL.md' -ErrorAction SilentlyContinue)
    if ($own.Count -gt 0) { Write-Output $Root; return }
    foreach ($child in @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)) {
        if ($child.Name -eq 'node_modules' -or $child.Name -eq '.git') { continue }
        Find-SkillDirs -Root $child.FullName -Depth ($Depth + 1)
    }
}

function Add-SkillItem {
    param(
        [string]$SkillDir,
        [string]$SkillFile,
        [string]$Source,
        [string]$SourceLabel,
        [string]$Root,
        [string]$PluginName,
        [string]$PluginLabel,
        [string]$AsarEntry
    )
    $key = $SkillFile.ToLowerInvariant()
    if ($script:SeenSkills.ContainsKey($key)) { return }
    $script:SeenSkills[$key] = $true

    $text = $null
    if ($AsarEntry) {
        $text = Get-AsarText $script:AsarPath $AsarEntry
    } else {
        $text = Read-TextFile $SkillFile
    }
    if ($null -eq $text) { return }

    $dirName = Split-Path -Leaf $SkillDir
    $meta = Get-SkillMeta $text $dirName
    $rel = ''
    if ($Root -and $SkillDir.Length -gt $Root.Length) {
        $rel = $SkillDir.Substring($Root.Length).TrimStart('\', '/')
    }
    if (-not $rel) { $rel = $dirName }
    $rel = $rel.Replace('\', '/')

    $id = 'skill:' + $Source + ':' + $rel
    if ($Source -eq 'plugin' -and $PluginName) { $id = 'skill:plugin:' + $PluginName + ':' + $rel }

    $curated = Get-CuratedEntry 'skills' $meta.Name
    if (-not $curated) { $curated = Get-CuratedEntry 'skills' $dirName }

    $label = if ($curated -and $curated.label) { [string]$curated.label } else { $meta.Name }
    $summary = ''
    if ($curated -and $curated.summary) {
        $summary = [string]$curated.summary
    } elseif ($meta.Description) {
        $summary = Get-FirstSentence $meta.Description
    } else {
        $summary = '未提供说明。'
    }
    $tags = @()
    if ($curated -and $curated.tags) { $tags = @($curated.tags | ForEach-Object { [string]$_ }) }

    $hub = Get-HubStat $meta.Name $dirName
    $disabled = Test-SkillDisabled $meta.Name $dirName $id

    if ($AsarEntry) {
        $fi = Get-Item -LiteralPath $script:AsarPath
        $updatedAt = Get-EpochMs $fi.LastWriteTimeUtc
        $size = [System.Text.Encoding]::UTF8.GetByteCount($text)
        $path = $script:AsarPath + ' > ' + $AsarEntry
        $location = 'asar'
    } else {
        $fi = Get-Item -LiteralPath $SkillFile
        $updatedAt = Get-EpochMs $fi.LastWriteTimeUtc
        $size = $fi.Length
        $path = $SkillFile
        $location = 'file'
    }

    $item = [ordered]@{
        id          = $id
        type        = 'skill'
        name        = $meta.Name
        dirName     = $dirName
        rowTitle    = $meta.Name
        label       = $label
        summary     = $summary
        description = $meta.Description
        tags        = $tags
        source      = $Source
        sourceLabel = $SourceLabel
        plugin      = $PluginName
        pluginLabel = $PluginLabel
        path        = $path
        entry       = $AsarEntry
        location    = $location
        size        = [long]$size
        updatedAt   = [long]$updatedAt
        disabled    = [bool]$disabled
        uses        = [int]$hub.count
        lastUsed    = [long]$hub.lastUsed
        hasBody     = $true
    }
    $script:Skills.Add($item) | Out-Null
}

function Get-Skills {
    param([string]$DshHome, [string]$ProfileDir)

    $script:Skills = New-Object System.Collections.ArrayList
    $script:SeenSkills = @{}

    $userRoot = Join-Path $DshHome 'skills'
    if (Test-Path -LiteralPath $userRoot) {
        foreach ($dir in @(Find-SkillDirs -Root $userRoot)) {
            Add-SkillItem -SkillDir $dir -SkillFile (Join-Path $dir 'SKILL.md') -Source 'user' -SourceLabel '用户目录' -Root $userRoot
        }
    }

    $agentsRoot = Join-Path $env:USERPROFILE '.agents\skills'
    if (Test-Path -LiteralPath $agentsRoot) {
        foreach ($dir in @(Find-SkillDirs -Root $agentsRoot)) {
            Add-SkillItem -SkillDir $dir -SkillFile (Join-Path $dir 'SKILL.md') -Source 'agents' -SourceLabel '通用目录' -Root $agentsRoot
        }
    }

    $officeRoot = Join-Path $script:DshRoot 'resources\runtime\office-skills'
    if (Test-Path -LiteralPath $officeRoot) {
        foreach ($dir in @(Find-SkillDirs -Root $officeRoot)) {
            Add-SkillItem -SkillDir $dir -SkillFile (Join-Path $dir 'SKILL.md') -Source 'builtin' -SourceLabel '内置' -Root $officeRoot
        }
    }

    # Skills shipped inside installed plugins (profile dependencies).
    if ($ProfileDir) {
        $profilePkgPath = Join-Path $ProfileDir 'package.json'
        if (Test-Path -LiteralPath $profilePkgPath) {
            $profilePkg = $null
            try { $profilePkg = (Read-TextFile $profilePkgPath) | ConvertFrom-Json } catch { }
            if ($profilePkg -and $profilePkg.dependencies) {
                $nodeModules = Join-Path $ProfileDir 'node_modules'
                foreach ($dep in $profilePkg.dependencies.PSObject.Properties) {
                    $pkgName = $dep.Name
                    $depDir = Resolve-DepDir $pkgName $nodeModules
                    $skillsRoot = Join-Path $depDir 'skills'
                    if (-not (Test-Path -LiteralPath $skillsRoot)) { continue }

                    # Only count skills the plugin actually registers with DSH:
                    # either a filesystem skill provider in its patch, or a
                    # "./skills/*" export consumed by its own plugin entry.
                    $declaresSkills = $false
                    $patchPath = Join-Path $depDir 'cordis.patch.yml'
                    if (Test-Path -LiteralPath $patchPath) {
                        $patchText = Read-TextFile $patchPath
                        if ($patchText -and $patchText -match 'dsh-skill-filesystem') { $declaresSkills = $true }
                    }
                    if (-not $declaresSkills) {
                        try {
                            $pkgMeta = (Read-TextFile (Join-Path $depDir 'package.json')) | ConvertFrom-Json
                            if ($pkgMeta -and $pkgMeta.exports) {
                                foreach ($exp in $pkgMeta.exports.PSObject.Properties) {
                                    if ($exp.Name -like '*skill*' -or ([string]$exp.Value) -like '*skill*') { $declaresSkills = $true; break }
                                }
                            }
                        } catch { }
                    }
                    if (-not $declaresSkills) { continue }

                    $shortName = $pkgName
                    if ($shortName.Contains('/')) { $shortName = $shortName.Split('/')[-1] }
                    foreach ($dir in @(Find-SkillDirs -Root $skillsRoot)) {
                        Add-SkillItem -SkillDir $dir -SkillFile (Join-Path $dir 'SKILL.md') -Source 'plugin' -SourceLabel '插件附带' -Root $skillsRoot -PluginName $pkgName -PluginLabel $shortName
                    }
                }
            }
        }
    }

    if (Test-Path -LiteralPath $script:AsarPath) {
        $diagEntry = 'dsh/node_modules/@deepseek-ai/dsh-sandbox-windows-acl/assets/diagnose-windows-sandbox-acl/SKILL.md'
        Add-SkillItem -SkillDir 'diagnose-windows-sandbox-acl' -SkillFile ($script:AsarPath + '::' + $diagEntry) -Source 'builtin' -SourceLabel '内置' -Root '' -AsarEntry $diagEntry
    }

    return $script:Skills
}

function Get-Plugins {
    param([string]$ProfileDir)

    $plugins = New-Object System.Collections.ArrayList
    $nodeModules = Join-Path $ProfileDir 'node_modules'
    if (-not (Test-Path -LiteralPath $nodeModules)) { return $plugins }

    $profilePkgPath = Join-Path $ProfileDir 'package.json'
    if (-not (Test-Path -LiteralPath $profilePkgPath)) { return $plugins }
    try {
        $profilePkg = (Read-TextFile $profilePkgPath) | ConvertFrom-Json
    } catch {
        Write-Log ('profile package.json parse failed: ' + $_.Exception.Message)
        return $plugins
    }
    if (-not $profilePkg.dependencies) { return $plugins }

    foreach ($dep in $profilePkg.dependencies.PSObject.Properties) {
        $pkgName = $dep.Name
        $spec = [string]$dep.Value
        $depDir = Resolve-DepDir $pkgName $nodeModules
        if (-not (Test-Path -LiteralPath (Join-Path $depDir 'package.json'))) { continue }
        try {
            $pkg = (Read-TextFile (Join-Path $depDir 'package.json')) | ConvertFrom-Json
        } catch {
            Write-Log ('plugin package parse failed: ' + $pkgName)
            continue
        }

        $shortName = $pkgName
        if ($shortName.Contains('/')) { $shortName = $shortName.Split('/')[-1] }

        $pkgDescription = ''
        if ($pkg.description) { $pkgDescription = ([string]$pkg.description -replace '\s+', ' ').Trim() }

        $homepage = ''
        if ($pkg.homepage) {
            $homepage = [string]$pkg.homepage
        } elseif ($pkg.repository) {
            if ($pkg.repository -is [string]) {
                $homepage = [string]$pkg.repository
            } elseif ($pkg.repository.url) {
                $homepage = [string]$pkg.repository.url
            }
        }
        if ($homepage) {
            $homepage = $homepage -replace '^git\+', '' -replace '#readme$', '' -replace '\.git$', ''
        }

        $license = ''
        if ($pkg.license) {
            if ($pkg.license -is [string]) { $license = [string]$pkg.license }
            elseif ($pkg.license.type) { $license = [string]$pkg.license.type }
        }

        $curated = Get-CuratedEntry 'plugins' $pkgName
        $label = if ($curated -and $curated.label) { [string]$curated.label } else { $shortName }
        $summary = ''
        if ($curated -and $curated.summary) { $summary = [string]$curated.summary }
        elseif ($pkgDescription) { $summary = Get-FirstSentence $pkgDescription }
        else { $summary = '未提供说明。' }
        $tags = @()
        if ($curated -and $curated.tags) { $tags = @($curated.tags | ForEach-Object { [string]$_ }) }

        $skillIds = @()
        $uses = 0
        $lastUsed = 0
        foreach ($s in $script:Skills) {
            if ($s.plugin -eq $pkgName) {
                $skillIds += $s.id
                $uses += [int]$s.uses
                if ($s.lastUsed -gt $lastUsed) { $lastUsed = [long]$s.lastUsed }
            }
        }

        $pkgFile = Join-Path $depDir 'package.json'
        $fi = Get-Item -LiteralPath $pkgFile
        $item = [ordered]@{
            id          = 'plugin:' + $pkgName
            type        = 'plugin'
            name        = $pkgName
            shortName   = $shortName
            rowTitle    = $shortName
            label       = $label
            summary     = $summary
            description = $pkgDescription
            tags        = $tags
            version     = if ($pkg.version) { [string]$pkg.version } else { '' }
            kind        = if ($spec -like 'file:*') { '本地' } else { '社区' }
            homepage    = $homepage
            license     = $license
            path        = $depDir
            updatedAt   = (Get-EpochMs $fi.LastWriteTimeUtc)
            skillIds    = $skillIds
            uses        = $uses
            lastUsed    = $lastUsed
            disabled    = $false
            size        = 0
        }
        $plugins.Add($item) | Out-Null
    }
    return $plugins
}

# ---------------------------------------------------------------- catalog

function Get-CatalogJson {
    param([switch]$Force)

    if (-not $Force -and $script:Catalog -and ((Get-Date) - $script:CatalogAt).TotalMilliseconds -lt 1200) {
        return $script:CatalogJson
    }

    Read-Curated
    Read-HubState

    $script:DshRoot = Resolve-DshRoot
    $prof = Resolve-Profile
    $script:AsarPath = if ($script:DshRoot) { Join-Path $script:DshRoot 'resources\app.asar' } else { '' }

    $skills = @()
    $plugins = @()
    if ($script:DshRoot) {
        $skills = @(Get-Skills $prof.Home $prof.ProfileDir)
        $plugins = @(Get-Plugins $prof.ProfileDir)
    }

    $plugins = @($plugins | Sort-Object { $_.shortName.ToLowerInvariant() })
    $skills = @($skills | Sort-Object { $_.name.ToLowerInvariant() })

    $now = Get-EpochMs (Get-Date)

    # state + change log
    $prev = @{}
    $prevInitialized = $false
    if ($script:State) {
        $prevInitialized = [bool]$script:State.initialized
        if ($script:State.items) {
            foreach ($p in $script:State.items.PSObject.Properties) { $prev[$p.Name] = $p.Value }
        }
    }

    $events = @()
    if ($script:State -and $script:State.events) { $events = @($script:State.events) }
    $newItems = [ordered]@{}
    $dirty = $false

    $all = @($plugins) + @($skills)
    foreach ($item in $all) {
        $hashText = @(
            [string]$item.type,
            [string]$item.name,
            [string]$item.version,
            [string]$item.description,
            [string]$item.updatedAt,
            [string]$item.disabled,
            [string]$item.plugin
        ) -join '|'
        $hash = Get-ShortHash $hashText
        $item['hash'] = $hash

        $old = $prev[$item.id]
        if ($old) {
            $item['firstSeen'] = [long]$old.firstSeen
            $item['addedAt'] = [long]$old.addedAt
            if ($old.hash -ne $hash) {
                $events += [ordered]@{
                    at = $now; kind = 'updated'; type = $item.type; name = $item.name;
                    label = $item.label; id = $item.id
                }
                $dirty = $true
            }
        } else {
            $item['firstSeen'] = $now
            $item['addedAt'] = 0
            if ($prevInitialized) {
                $item['addedAt'] = $now
                $events += [ordered]@{
                    at = $now; kind = 'added'; type = $item.type; name = $item.name;
                    label = $item.label; id = $item.id
                }
            }
            $dirty = $true
        }

        $newItems[$item.id] = [ordered]@{
            hash      = $hash
            firstSeen = $item.firstSeen
            addedAt   = $item.addedAt
            name      = $item.name
            label     = $item.label
            type      = $item.type
            path      = $item.path
        }
    }

    foreach ($oldId in $prev.Keys) {
        if (-not $newItems.Contains($oldId)) {
            $old = $prev[$oldId]
            $events += [ordered]@{
                at = $now; kind = 'removed'; type = $old.type; name = $old.name;
                label = $old.label; id = $oldId
            }
            $dirty = $true
        }
    }

    $events = @($events | Sort-Object { [long]$_.at })
    if ($events.Count -gt 60) { $events = @($events | Select-Object -Last 60) }

    $revSource = (($all | Sort-Object { $_.id } | ForEach-Object {
        [string]$_.id + ':' + [string]$_.hash + ':' + [string]$_.uses + ':' + [string]$_.lastUsed + ':' + [string]$_.disabled
    }) -join '|')
    $revision = Get-ShortHash $revSource

    if ($dirty -or -not (Test-Path -LiteralPath $script:StatePath)) {
        $stateOut = [ordered]@{
            version     = 1
            initialized = $true
            revision    = $revision
            items       = $newItems
            events      = @($events)
        }
        try {
            Write-TextFile $script:StatePath ($stateOut | ConvertTo-Json -Depth 8)
            $script:State = (Read-TextFile $script:StatePath) | ConvertFrom-Json
        } catch {
            Write-Log ('state write failed: ' + $_.Exception.Message)
        }
    } elseif ($script:State.revision -ne $revision) {
        $script:State.revision = $revision
    }

    $recent = @($events | Where-Object { ([long]$_.at) -gt ($now - 172800000) } | Sort-Object { [long]$_.at } -Descending | Select-Object -First 6)

    $sourceDefs = @(
        [ordered]@{ id = 'user'; label = '用户目录'; en = 'USER'; count = @($skills | Where-Object { $_.source -eq 'user' }).Count },
        [ordered]@{ id = 'plugin'; label = '插件附带'; en = 'BUNDLED'; count = @($skills | Where-Object { $_.source -eq 'plugin' }).Count },
        [ordered]@{ id = 'builtin'; label = '内置'; en = 'BUILT-IN'; count = @($skills | Where-Object { $_.source -eq 'builtin' }).Count }
    )
    $agentsCount = @($skills | Where-Object { $_.source -eq 'agents' }).Count
    if ($agentsCount -gt 0) {
        $sourceDefs += [ordered]@{ id = 'agents'; label = '通用目录'; en = 'AGENTS'; count = $agentsCount }
    }

    $roots = New-Object System.Collections.ArrayList
    $userSkillsPath = Join-Path $prof.Home 'skills'
    $roots.Add([ordered]@{ label = '用户技能'; path = $userSkillsPath; count = @($skills | Where-Object { $_.source -eq 'user' }).Count; exists = (Test-Path -LiteralPath $userSkillsPath) }) | Out-Null
    if ($prof.ProfileDir) {
        $pluginPath = Join-Path $prof.ProfileDir 'node_modules'
        $roots.Add([ordered]@{ label = '插件包'; path = $pluginPath; count = @($skills | Where-Object { $_.source -eq 'plugin' }).Count; exists = (Test-Path -LiteralPath $pluginPath) }) | Out-Null
    }
    if ($script:DshRoot) {
        $officePath = Join-Path $script:DshRoot 'resources\runtime\office-skills'
        $roots.Add([ordered]@{ label = 'Office 内置'; path = $officePath; count = @($skills | Where-Object { $_.source -eq 'builtin' -and -not $_.entry }).Count; exists = (Test-Path -LiteralPath $officePath) }) | Out-Null
        $roots.Add([ordered]@{ label = 'app.asar'; path = $script:AsarPath; count = @($skills | Where-Object { $_.source -eq 'builtin' -and $_.entry }).Count; exists = (Test-Path -LiteralPath $script:AsarPath) }) | Out-Null
    }

    $catalog = [ordered]@{
        app           = 'harness-index'
        appVersion    = $script:AppVersion
        revision      = $revision
        generatedAt   = (Get-Date).ToString('o')
        startedAt     = $script:StartedAt
        idleSeconds   = $script:IdleSeconds
        dsh           = [ordered]@{
            root    = $script:DshRoot
            home    = $prof.Home
            profile = $prof.ProfileName
        }
        totals        = [ordered]@{
            entries = $all.Count
            plugins = $plugins.Count
            skills  = $skills.Count
        }
        sources       = $sourceDefs
        roots         = $roots
        plugins       = $plugins
        skills        = $skills
        recentChanges = $recent
    }

    $json = $catalog | ConvertTo-Json -Depth 10 -Compress
    $script:Catalog = $catalog
    $script:CatalogJson = $json
    $script:CatalogAt = Get-Date
    return $json
}

# ---------------------------------------------------------------- http

function Read-RequestHeaders {
    param($Stream)
    $buffer = New-Object byte[] 4096
    $sb = New-Object System.Text.StringBuilder
    $deadline = (Get-Date).AddSeconds(3)
    while ((Get-Date) -lt $deadline) {
        if ($Stream.DataAvailable) {
            $n = $Stream.Read($buffer, 0, $buffer.Length)
            if ($n -le 0) { break }
            [void]$sb.Append([System.Text.Encoding]::ASCII.GetString($buffer, 0, $n))
            if ($sb.ToString().Contains("`r`n`r`n") -or $sb.Length -gt 65536) { break }
        } else {
            Start-Sleep -Milliseconds 10
        }
    }
    return $sb.ToString()
}

function Send-Response {
    param($Stream, [int]$Status, [string]$ContentType, [byte[]]$Body, [bool]$HeadOnly = $false)
    $text = switch ($Status) {
        200 { 'OK' }
        400 { 'Bad Request' }
        404 { 'Not Found' }
        405 { 'Method Not Allowed' }
        500 { 'Internal Server Error' }
        default { 'OK' }
    }
    $head = 'HTTP/1.1 ' + $Status + ' ' + $text + "`r`n"
    $head += 'Content-Type: ' + $ContentType + "`r`n"
    $head += 'Content-Length: ' + $Body.Length + "`r`n"
    $head += "Cache-Control: no-store`r`n"
    $head += "Connection: close`r`n"
    $head += "X-Content-Type-Options: nosniff`r`n"
    $head += "Referrer-Policy: no-referrer`r`n"
    if ($ContentType -like 'text/html*') {
        $head += "Content-Security-Policy: default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'`r`n"
    }
    $head += "`r`n"
    $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
    $Stream.Write($hb, 0, $hb.Length)
    if (-not $HeadOnly -and $Body.Length -gt 0) { $Stream.Write($Body, 0, $Body.Length) }
    $Stream.Flush()
}

function Send-Json {
    param($Stream, [int]$Status, $Object, [bool]$HeadOnly = $false)
    $json = $Object | ConvertTo-Json -Depth 12 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    Send-Response $Stream $Status 'application/json; charset=utf-8' $bytes $HeadOnly
}

function Send-Text {
    param($Stream, [int]$Status, [string]$Text, [string]$ContentType = 'text/plain; charset=utf-8', [bool]$HeadOnly = $false)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    Send-Response $Stream $Status $ContentType $bytes $HeadOnly
}

function Handle-Request {
    param($Client)
    $stream = $Client.GetStream()
    $stream.ReadTimeout = 5000
    $stream.WriteTimeout = 5000

    $raw = Read-RequestHeaders $stream
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    $line = ($raw -split "`r`n")[0]
    $parts = $line -split ' '
    if ($parts.Length -lt 2) { Send-Text $stream 400 'Bad request'; return }
    $method = $parts[0].ToUpperInvariant()
    $target = $parts[1]
    $headOnly = ($method -eq 'HEAD')
    if ($method -ne 'GET' -and $method -ne 'HEAD') { Send-Text $stream 405 'Method not allowed'; return }

    $path = $target
    $query = ''
    $qi = $target.IndexOf('?')
    if ($qi -ge 0) {
        $path = $target.Substring(0, $qi)
        $query = $target.Substring($qi + 1)
    }
    try { $path = [System.Uri]::UnescapeDataString($path) } catch { }
    $params = @{}
    if ($query) {
        foreach ($pair in $query.Split('&')) {
            if (-not $pair) { continue }
            $kv = $pair.Split('=', 2)
            $k = $kv[0]
            $v = if ($kv.Length -gt 1) { $kv[1].Replace('+', ' ') } else { '' }
            try { $k = [System.Uri]::UnescapeDataString($k) } catch { }
            try { $v = [System.Uri]::UnescapeDataString($v) } catch { }
            $params[$k] = $v
        }
    }

    switch ($path) {
        '/api/ping' {
            Send-Json $stream 200 ([ordered]@{
                app = 'harness-index'; version = $script:AppVersion; port = $script:Port;
                pid = $PID; startedAt = $script:StartedAt
            }) $headOnly
            return
        }
        '/api/catalog' {
            try {
                $json = Get-CatalogJson
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                Send-Response $stream 200 'application/json; charset=utf-8' $bytes $headOnly
            } catch {
                Write-Log ('catalog failed: ' + $_.Exception.ToString())
                Send-Json $stream 500 ([ordered]@{ ok = $false; error = $_.Exception.Message }) $headOnly
            }
            return
        }
        '/api/body' {
            try {
                $id = [string]$params['id']
                $null = Get-CatalogJson -Force
                $item = $null
                foreach ($s in @($script:Catalog.skills)) {
                    if ($s.id -eq $id) { $item = $s; break }
                }
                if (-not $item) { Send-Json $stream 404 ([ordered]@{ ok = $false; error = 'Skill not found' }) $headOnly; return }
                $text = $null
                if ($item.location -eq 'asar') {
                    $text = Get-AsarText $script:AsarPath $item.entry
                } else {
                    $text = Read-TextFile $item.path
                }
                if ($null -eq $text) { Send-Json $stream 500 ([ordered]@{ ok = $false; error = 'Unable to read file' }) $headOnly; return }
                Send-Json $stream 200 ([ordered]@{
                    ok = $true; id = $item.id; name = $item.name; path = $item.path;
                    location = $item.location; text = $text
                }) $headOnly
            } catch {
                Send-Json $stream 500 ([ordered]@{ ok = $false; error = $_.Exception.Message }) $headOnly
            }
            return
        }
    }

    $static = @{
        '/' = @('app\index.html', 'text/html; charset=utf-8')
        '/index.html' = @('app\index.html', 'text/html; charset=utf-8')
        '/app.css' = @('app\app.css', 'text/css; charset=utf-8')
        '/app.js' = @('app\app.js', 'application/javascript; charset=utf-8')
        '/curated.json' = @('app\curated.json', 'application/json; charset=utf-8')
        '/favicon.ico' = @('assets\icon.ico', 'image/x-icon')
        '/favicon.png' = @('assets\icon-64.png', 'image/png')
        '/icon.png' = @('assets\icon-256.png', 'image/png')
    }
    $entry = $static[$path]
    if (-not $entry) {
        Send-Text $stream 404 'Not found'
        return
    }
    $full = Join-Path $script:AppDir $entry[0]
    if (-not (Test-Path -LiteralPath $full)) {
        Send-Text $stream 404 'Not found'
        return
    }
    $bytes = [System.IO.File]::ReadAllBytes($full)
    Send-Response $stream 200 $entry[1] $bytes $headOnly
}

function Start-Browser {
    param([string]$Url)
    $edgeCandidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe')
    )
    $edge = $null
    foreach ($c in $edgeCandidates) { if ($c -and (Test-Path -LiteralPath $c)) { $edge = $c; break } }
    try {
        if ($edge) {
            Start-Process -FilePath $edge -ArgumentList @("--app=$Url", '--window-size=1440,940', '--no-first-run') | Out-Null
        } else {
            Start-Process $Url | Out-Null
        }
    } catch {
        Write-Log ('browser start failed: ' + $_.Exception.Message)
        try { Start-Process $Url | Out-Null } catch { }
    }
}

function Test-LocalPort {
    param([int]$Port)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne(120)) { return $false }
        $client.EndConnect($ar)
        return $true
    } catch {
        return $false
    } finally {
        try { $client.Close() } catch { }
    }
}

function Find-Instance {
    for ($p = $script:BasePort; $p -le $script:MaxPort; $p++) {
        if (-not (Test-LocalPort $p)) { continue }
        try {
            $resp = Invoke-WebRequest -Uri ('http://127.0.0.1:' + $p + '/api/ping') -UseBasicParsing -TimeoutSec 2
            $obj = $resp.Content | ConvertFrom-Json
            if ($obj.app -eq 'harness-index') { return [pscustomobject]@{ Port = $p; Info = $obj } }
        } catch { }
    }
    return $null
}

# ---------------------------------------------------------------- main

if (-not (Test-Path -LiteralPath $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
if (Test-Path -LiteralPath $script:LogPath) {
    try {
        $li = Get-Item -LiteralPath $script:LogPath
        if ($li.Length -gt 524288) { Remove-Item -LiteralPath $script:LogPath -Force }
    } catch { }
}

$script:StartedAt = Get-EpochMs (Get-Date)

if (Test-Path -LiteralPath $script:StatePath) {
    try { $script:State = (Read-TextFile $script:StatePath) | ConvertFrom-Json } catch { $script:State = $null }
}

Read-HubState

# One instance per desktop session. The OS releases this mutex if the process dies.
try {
    $script:InstanceMutex = [System.Threading.Mutex]::new($false, 'Local\HarnessIndex')
} catch {
    $script:InstanceMutex = $null
}

if (-not $ForceNew -and $script:InstanceMutex) {
    $acquired = $false
    try {
        $acquired = $script:InstanceMutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        $acquired = $true
    }
    if (-not $acquired) {
        $runningPort = $script:BasePort
        try {
            if (Test-Path -LiteralPath $script:PortPath) {
                $rawPort = (Read-TextFile $script:PortPath).Trim()
                $parsedPort = 0
                if ([int]::TryParse($rawPort, [ref]$parsedPort) -and $parsedPort -ge $script:BasePort -and $parsedPort -le $script:MaxPort) {
                    $runningPort = $parsedPort
                }
            }
        } catch { }
        if (-not (Test-LocalPort $runningPort)) {
            $found = Find-Instance
            if ($found) { $runningPort = $found.Port }
        }
        Write-Log ('instance already running on port ' + $runningPort)
        if (-not $NoBrowser) { Start-Browser ('http://127.0.0.1:' + $runningPort + '/') }
        exit 0
    }
}

$listener = $null
for ($p = $script:BasePort; $p -le $script:MaxPort; $p++) {
    try {
        $candidate = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $p)
        $candidate.Start()
        $listener = $candidate
        $script:Port = $p
        break
    } catch {
        if ($candidate) { try { $candidate.Stop() } catch { } }
    }
}
if (-not $listener) {
    Write-Log 'no free port'
    exit 1
}

$url = 'http://127.0.0.1:' + $script:Port + '/'
try { [IO.File]::WriteAllText($script:PortPath, [string]$script:Port) } catch { }
Write-Log ('listening on ' + $url + ' pid=' + $PID)
if (-not $NoBrowser) { Start-Browser $url }

$script:LastHit = Get-Date
try {
    while ($true) {
        if ($listener.Pending()) {
            $client = $listener.AcceptTcpClient()
            try {
                $script:LastHit = Get-Date
                Handle-Request $client
            } catch {
                Write-Log ('request failed: ' + $_.Exception.Message)
            } finally {
                try { $client.Close() } catch { }
            }
        } else {
            if (((Get-Date) - $script:LastHit).TotalSeconds -gt $script:IdleSeconds) { break }
            Start-Sleep -Milliseconds 90
        }
    }
} finally {
    try { $listener.Stop() } catch { }
    Write-Log 'server stopped'
}
