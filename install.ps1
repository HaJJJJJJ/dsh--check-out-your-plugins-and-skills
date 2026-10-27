[CmdletBinding()]
param(
    [string]$InstallDir = '',
    [switch]$NoLaunch,
    [switch]$NoStartMenu
)

$ErrorActionPreference = 'Stop'

$source = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    $localAppData = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    }
    $InstallDir = Join-Path $localAppData 'HarnessIndex'
}
$InstallDir = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
if ($InstallDir -eq 'C:' -or $InstallDir -eq $env:SystemRoot.TrimEnd('\')) {
    throw '拒绝安装到系统盘根目录或 Windows 目录。'
}

if (-not (Test-Path -LiteralPath (Join-Path $source 'server.ps1'))) {
    throw "找不到 server.ps1。请从项目根目录运行 install.ps1。当前目录：$source"
}
if (-not (Test-Path -LiteralPath (Join-Path $source 'app\index.html'))) {
    throw "找不到 app\index.html。项目文件不完整。"
}

$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $psExe)) {
    throw "找不到 Windows PowerShell：$psExe"
}

Write-Host "安装到：$InstallDir"
foreach ($dir in @($InstallDir, (Join-Path $InstallDir 'app'), (Join-Path $InstallDir 'assets'), (Join-Path $InstallDir 'data'), (Join-Path $InstallDir 'docs'))) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir | Out-Null
    }
}

Copy-Item -LiteralPath (Join-Path $source 'server.ps1') -Destination (Join-Path $InstallDir 'server.ps1') -Force
Copy-Item -Path (Join-Path $source 'app\*') -Destination (Join-Path $InstallDir 'app') -Recurse -Force
Copy-Item -Path (Join-Path $source 'assets\*') -Destination (Join-Path $InstallDir 'assets') -Recurse -Force

foreach ($doc in @('README.md', 'DESIGN.md', 'LICENSE', 'Start Harness Index.cmd')) {
    $srcDoc = Join-Path $source $doc
    if (Test-Path -LiteralPath $srcDoc) {
        Copy-Item -LiteralPath $srcDoc -Destination (Join-Path $InstallDir $doc) -Force
    }
}

$docsSource = Join-Path $source 'docs'
if (Test-Path -LiteralPath $docsSource) {
    Copy-Item -Path (Join-Path $docsSource '*') -Destination (Join-Path $InstallDir 'docs') -Recurse -Force
}

# 从 GitHub 下载的 zip 可能带“来自 Internet”标记；解除标记，避免脚本被拦截。
Get-ChildItem -LiteralPath $InstallDir -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue
}

$serverPath = Join-Path $InstallDir 'server.ps1'
$iconPath = Join-Path $InstallDir 'assets\icon.ico'
$shell = New-Object -ComObject WScript.Shell
$desktop = [Environment]::GetFolderPath('Desktop')
if ([string]::IsNullOrWhiteSpace($desktop)) {
    throw '找不到桌面目录。'
}
$shortcutPath = Join-Path $desktop 'Harness Index.lnk'

function New-HarnessShortcut {
    param([string]$Path)
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $psExe
    $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $serverPath + '"'
    $shortcut.WorkingDirectory = $InstallDir
    $shortcut.IconLocation = $iconPath + ',0'
    $shortcut.Description = '本机 DeepSeek Harness 插件与技能索引'
    $shortcut.WindowStyle = 7
    $shortcut.Save()
}

New-HarnessShortcut -Path $shortcutPath

if (-not $NoStartMenu) {
    $startMenu = [Environment]::GetFolderPath('StartMenu')
    if (-not [string]::IsNullOrWhiteSpace($startMenu)) {
        $programs = Join-Path $startMenu 'Programs'
        if (-not (Test-Path -LiteralPath $programs)) {
            New-Item -ItemType Directory -Path $programs | Out-Null
        }
        New-HarnessShortcut -Path (Join-Path $programs 'Harness Index.lnk')
    }
}

Write-Host ''
Write-Host "完成。快捷方式：$shortcutPath"
Write-Host "启动目标：$psExe"
Write-Host '双击快捷方式即可。首次启动需要 2-5 秒；服务只监听 127.0.0.1。'
Write-Host '卸载：删除桌面/开始菜单快捷方式，再删除上面的安装目录即可。'

if (-not $NoLaunch) {
    Start-Process -FilePath $shortcutPath
}
