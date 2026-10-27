# Harness Index

**DeepSeek Harness 插件与技能索引器。** 把本机装了哪些插件、哪些技能、各自能干什么、装在哪儿、调用过几次，汇总成一个本地只读页面，装完就更新。

> GitHub 仓库名：`dsh--check out your plugins and skills`

页面是「静室 / 技术目录」风格：深暖黑目录配纸白详情页，烬光橙与陶土只做一次信号；宋体大标题、等宽编号、发丝线，无阴影。无外部字体、无 CDN、无网络请求。

---

## 一、这个项目解决什么问题

DeepSeek Harness 的技能分散在五个位置，插件信息藏在 profile 的 `package.json` 里，Office 技能还压在 `app.asar` 内部。想知道「我到底装了什么」，原来的做法是逐个翻目录：

| 想回答的问题 | 原来的做法 | 用 Harness Index |
| --- | --- | --- |
| 装了哪些插件、哪些技能 | 翻 5 个目录，asar 里的还得解包 | 一页列全，标出来源与安装路径 |
| 某个技能到底干什么 | 打开 `SKILL.md` 读英文原文 | 一句话中文功能 + 标签；没收录的条目回退原文描述 |
| 版本、许可证、主页 | 逐个读 `package.json` | 列表里直接看 |
| 用过几次、是不是被禁用了 | 去 `dsh-skill-hub.json` 里找统计字段 | 合并进列表，带调用次数与最近使用时间 |
| 刚放的技能有没有被识别 | 重启后重新翻目录 | 3 秒轮询，自动出现、高亮并提示 |

一句话：**把「装了什么」从一堆目录变成一个能搜、能看正文的列表**。工具只读，不联网，不修改任何被扫描的文件。

## 二、主要功能

| 功能 | 说明 |
| --- | --- |
| 五类来源汇总 | 用户技能、插件附带技能、通用目录、内置 Office 技能、`app.asar` 内的沙箱诊断技能，全部收进同一个列表 |
| 中文功能摘要 | `app/curated.json` 为常见插件/技能提供中文名、一句话功能与标签；未知条目自动回退 `SKILL.md` 或 `package.json` 里的原始描述 |
| 元数据 | 版本、许可证、主页、安装路径、体积、内容 hash |
| 调用统计 | 合并 `~/.dsh/dsh-skill-hub.json` 中的启用/禁用状态、调用次数与最近使用时间 |
| 正文阅读 | 右侧面板直接渲染 `SKILL.md` 正文，包括从 `app.asar` 里抽出来的条目 |
| 自动刷新 | 每 3 秒检查一次文件系统；新增/删除后列表自动更新，新条目标记 12 秒并弹提示 |
| 搜索与键盘 | `/` 聚焦搜索，`↑` `↓` 移动，`Esc` 关闭详情 |
| 单实例 | `Local\HarnessIndex` 命名互斥量保证只跑一个服务；端口从 `28173` 起，占用时自动递增 |
| 本地且只读 | 只监听 `127.0.0.1`，零外部请求、零上传，被扫描的文件不改一个字节 |

## 三、安装方法

**前置条件**

- Windows 10 / 11
- Windows PowerShell 5.1（系统自带）
- 已安装 DeepSeek Harness（没有也能打开页面，只是列表为空）
- 不需要管理员权限

### 先拿到文件

任选其一：

- **下载发布包**：[HarnessIndex-v1.0.0.zip](https://github.com/HaJJJJJJ/dsh--check-out-your-plugins-and-skills/releases/download/v1.0.0/HarnessIndex-v1.0.0.zip)，解压到任意目录（例如 `%LOCALAPPDATA%\HarnessIndex` 或桌面上的一个文件夹）。完整性校验值见 [HarnessIndex-v1.0.0.zip.sha256](https://github.com/HaJJJJJJ/dsh--check-out-your-plugins-and-skills/releases/download/v1.0.0/HarnessIndex-v1.0.0.zip.sha256)，可用 `certutil -hashfile HarnessIndex-v1.0.0.zip SHA256` 核对。
- **克隆仓库**：`git clone https://github.com/HaJJJJJJ/dsh--check-out-your-plugins-and-skills.git`，直接用仓库里的文件。

下面的命令都在「解压后的目录」或「仓库根目录」里执行。

### 方式 A：安装到本机（推荐）

在解压后的目录（或仓库根目录）打开 PowerShell：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

脚本会做四件事：

1. 把程序复制到 `%LOCALAPPDATA%\HarnessIndex`；
2. 在桌面和开始菜单创建 **Harness Index** 快捷方式（目标是微软签名的 `powershell.exe`，参数指向安装目录里的 `server.ps1`）；
3. 对从 zip 解压出来的文件执行 `Unblock-File`；
4. 首次启动时用 Edge 的应用窗口打开页面，没有 Edge 就回退默认浏览器。

### 方式 B：免安装

双击 `Start Harness Index.cmd`，直接从当前目录运行。整个目录可以复制到另一台 Windows 电脑照此使用，不写注册表、不建服务、不需要管理员权限。

### 方式 C：源码调试

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\server.ps1 -NoBrowser
```

然后手动打开 `http://127.0.0.1:28173/`，控制台里能看到扫描日志。

### 为什么没有 exe

Windows 11 的**智能应用控制（SAC）** 会拦截无可信签名的 exe。本项目不发布 PE 文件，快捷方式运行的是微软签名的 `powershell.exe`，程序本体是 `.ps1` + HTML/CSS/JS。原因、诊断命令和「以后要发 exe 该怎么签名」见 [docs/SMART-APP-CONTROL.md](docs/SMART-APP-CONTROL.md)。

### 卸载

删除桌面与开始菜单的 **Harness Index** 快捷方式，再删除 `%LOCALAPPDATA%\HarnessIndex`。程序不写注册表、不注册服务。

## 四、使用方法

界面分三栏：

- **左轨**：全部 / 插件 / 技能 筛选，技能来源（用户目录、插件附带、内置、通用目录），运行状态；
- **中栏**：搜索框、分组列表、索引号、名称、一句话功能、版本与状态；
- **右栏**：完整描述、元数据、路径复制、`SKILL.md` 正文、该插件提供的技能清单。

常用操作：

| 操作 | 方式 |
| --- | --- |
| 搜索 | 顶部搜索框，或按 `/` 聚焦 |
| 选择条目 | `↑` `↓`，或直接点 |
| 关闭详情/弹窗 | `Esc` |
| 复制安装路径 | 右栏「路径」右侧的复制按钮 |
| 保存技能正文 | 右栏正文区的保存按钮 |
| 过滤来源 | 左轨来源项 |
| 只看启用/禁用 | 左轨运行状态项 |

### 新增一个技能

把技能放到用户目录或通用目录：

```text
%USERPROFILE%\.dsh\skills\<技能名>\SKILL.md
%USERPROFILE%\.agents\skills\<技能名>\SKILL.md
```

不用重启，最多 3 秒后出现在列表里并被高亮。技能的 `SKILL.md` 需要带 frontmatter：

```markdown
---
name: weekly-report
description: 当需要把一周的提交记录整理成周报草稿时使用。
---
```

没有在 `app/curated.json` 里收录的新技能，页面会把 `description` 直接当摘要显示，不会漏掉。

### 指定 DSH 安装位置

常见安装路径会自动发现。装在别处时，在 `data\config.json` 里写：

```json
{
  "dshRoot": "D:\\Apps\\Deepseekharness"
}
```

### 页面上的状态是怎么来的

- **启用 / 禁用**：读 `~/.dsh/dsh-skill-hub.json` 里的 `disabled` 列表；
- **调用次数、最近使用**：读同一个文件里的 `skillStats`。

这两项显示的是 DSH 自己的统计，本工具只读不改。

## 五、输入输出示例

### 5.1 输入

**① 一个技能：`SKILL.md`**

```text
%USERPROFILE%\.dsh\skills\weekly-report\SKILL.md
```

```markdown
---
name: weekly-report
description: 当需要把一周的提交记录整理成周报草稿时使用，按项目分组并列出未完成事项。
---

# Weekly Report

1. 读取本周的提交记录；
2. 按项目分组；
3. 输出 Markdown 周报草稿。
```

**② 一个插件：profile 的 `package.json`**

```text
%USERPROFILE%\.dsh\profiles\<profile>\package.json
```

```json
{
  "dependencies": {
    "@tt-a1i/archify-dsh": "^1.0.0",
    "billion-context": "^0.1.206"
  }
}
```

插件自带的技能在 `node_modules\<包名>\skills\<技能名>\SKILL.md`，会被归到「插件附带」来源。

**③ 启用状态与调用统计：`~/.dsh/dsh-skill-hub.json`**

```json
{
  "version": 4,
  "disabled": ["some-skill"],
  "skillStats": {
    "lastTotals": [
      { "name": "dsh-ppt", "count": 1, "lastUsed": 1792643447168 }
    ]
  }
}
```

**④ 可选的安装路径覆盖：`data\config.json`**

```json
{ "dshRoot": "D:\\Apps\\Deepseekharness" }
```

### 5.2 输出

**① 页面列表**（示意）

```text
#   名称           一句话功能                                   版本     状态
01  archify-dsh    把系统架构、流程与时序做成可探索的独立 HTML   1.0.0    启用
02  modlens        给纯文本模型接上眼睛：读取截图与图表          0.4.1    启用
03  office-docx    创建、读取、编辑和校验 Word 文档              1.2.0    启用
04  weekly-report  把一周提交记录整理成周报草稿                  本地      启用
```

**② `GET /api/ping`**：判断服务是否在跑、跑在哪个端口

```json
{
  "app": "harness-index",
  "version": "1.0.0",
  "port": 28173,
  "pid": 99288,
  "startedAt": 1793105247612
}
```

**③ `GET /api/catalog`**：整份索引（示例为截断）

```json
{
  "app": "harness-index",
  "appVersion": "1.0.0",
  "revision": "c7e8ea26190e",
  "generatedAt": "2026-10-27T20:47:47.2405514+08:00",
  "dsh": { "root": "<DSH_ROOT>", "home": "%USERPROFILE%\\.dsh", "profile": "desktop" },
  "totals": { "entries": 47, "plugins": 11, "skills": 36 },
  "sources": ["用户目录", "插件附带", "内置", "通用目录"],
  "roots": ["..."],
  "plugins": [
    {
      "id": "plugin:@tt-a1i/archify-dsh",
      "type": "plugin",
      "name": "@tt-a1i/archify-dsh",
      "label": "Archify 架构图",
      "summary": "把系统架构、流程与时序做成可探索的独立 HTML，带明暗主题与多格式导出。",
      "tags": ["架构图", "可视化", "HTML"],
      "version": "1.0.0",
      "kind": "社区",
      "license": "MIT",
      "homepage": "https://github.com/tt-a1i/archify",
      "path": "%USERPROFILE%\\.dsh\\profiles\\desktop\\node_modules\\@tt-a1i\\archify-dsh",
      "uses": 0,
      "disabled": false,
      "skillIds": ["skill:plugin:@tt-a1i/archify-dsh:archify"]
    }
  ],
  "skills": [
    {
      "id": "skill:plugin:@tt-a1i/archify-dsh:archify",
      "type": "skill",
      "name": "archify",
      "label": "架构图",
      "source": "plugin",
      "sourceLabel": "插件附带",
      "plugin": "@tt-a1i/archify-dsh",
      "path": "%USERPROFILE%\\.dsh\\profiles\\desktop\\node_modules\\@tt-a1i\\archify-dsh\\skills\\archify\\SKILL.md",
      "location": "file",
      "size": 11647,
      "hasBody": true,
      "uses": 0,
      "disabled": false
    }
  ],
  "recentChanges": []
}
```

**④ `GET /api/body?id=<技能 id>`**：取某个技能的 `SKILL.md` 正文

```json
{
  "ok": true,
  "id": "skill:plugin:@tt-a1i/archify-dsh:archify",
  "name": "archify",
  "path": "%USERPROFILE%\\.dsh\\profiles\\desktop\\node_modules\\@tt-a1i\\archify-dsh\\skills\\archify\\SKILL.md",
  "location": "file",
  "text": "---\nname: archify\ndescription: Create polished, validated architecture diagrams...\n---\n\n# Archify\n..."
}
```

> 以上示例里的本机路径都做了脱敏：真实返回值是绝对路径，所以 `data/` 目录不进 Git，也不该随发行包分发（`.gitignore` 已忽略）。

## 六、数据来源

| 来源 | 路径 | 说明 |
| --- | --- | --- |
| 用户技能 | `%USERPROFILE%\.dsh\skills\*\SKILL.md` | 用户自己安装的技能 |
| 插件附带 | `%USERPROFILE%\.dsh\profiles\<profile>\node_modules\<包>\skills\*\SKILL.md` | 只收录真正向 DSH 注册技能的资源 |
| 通用目录 | `%USERPROFILE%\.agents\skills\*\SKILL.md` | 存在时才显示 |
| 内置技能 | `<DSH_ROOT>\resources\runtime\office-skills\*\SKILL.md` | Office 系列 |
| 内置技能 | `<DSH_ROOT>\resources\app.asar` | 沙箱诊断技能，直接从 asar 读取 |
| 插件 | `%USERPROFILE%\.dsh\profiles\<profile>\package.json` 的直接依赖 | 读取包名、版本、描述、许可证、主页 |

`~/.dsh/dsh-skill-hub.json` 中的启用/禁用状态与调用次数会合并进列表；`app/curated.json` 为已知条目提供中文名称、一句话功能与标签，未知条目自动回退原始描述。

## 七、项目结构

```text
server.ps1                 本地 HTTP 服务 + 扫描器（Windows PowerShell 5.1）
install.ps1                安装到 %LOCALAPPDATA%，创建快捷方式
Start Harness Index.cmd    免安装启动入口
app/                       页面（index.html / app.css / app.js / curated.json）
assets/                    图标（icon.ico / icon-64.png / icon-256.png）
docs/                      智能应用控制与签名说明
data/                      运行时生成：port.txt、state.json、server.log、asar-cache.json（不进 Git）
.github/workflows/         推送 v* 标签时自动打包并发布 Release
```

## 八、开发与调试

前台运行（控制台有日志）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\server.ps1 -NoBrowser
```

打开 `http://127.0.0.1:28173/`。端口固定从 `28173` 开始，占用时递增；单实例由 `Local\HarnessIndex` 命名互斥量保证。

`server.ps1` 必须保存为 **UTF-8 with BOM**，否则 Windows PowerShell 5.1 会按 ANSI 读取，中文字符串乱码并触发语法错误。改完脚本用下面的命令校验：

```powershell
$t = $null; $e = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
  (Resolve-Path .\server.ps1), [ref]$t, [ref]$e)
if ($e.Count) { $e | ForEach-Object { $_.Message } } else { 'PARSE OK' }
```

## 九、常见问题

- **页面打不开**：看 `data\server.log`，端口在 `data\port.txt` 里。
- **端口被占用**：服务会自动往后找；再次双击快捷方式会读 `port.txt` 打开正确地址。
- **新技能没出现**：确认目录里是 `SKILL.md`（大小写不敏感），且 frontmatter 有 `name` / `description`。
- **双击没反应**：先在 PowerShell 里前台运行 `server.ps1 -NoBrowser` 看报错；如果只有双击失败，检查快捷方式参数是否指向正确的安装目录。
- **被安全软件拦截**：先读 [docs/SMART-APP-CONTROL.md](docs/SMART-APP-CONTROL.md)，不要直接关闭 SAC。
- **列表数量与别人不同**：这是读取本机安装的结果，不同 DSH 版本、不同插件组合下列表本来就不同，不是固定清单。

## 十、许可证

[Apache License 2.0](LICENSE)。使用时保留版权与许可声明；修改后的分发需在文件中说明改动。

## 十一、隐私与安全

- 只监听 `127.0.0.1`，不发起任何外部网络请求，不上传任何数据；
- 不写入、不修改被扫描的技能与插件；
- 唯一的写入位置是程序自己的 `data/` 目录（端口号、扫描状态、日志、asar 缓存）；
- `data/` 含本机绝对路径与端口信息，已加入 `.gitignore`，分发时不要带上。
