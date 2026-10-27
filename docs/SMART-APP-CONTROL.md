# 为什么会被“智能应用控制”拦截，以及本项目的处理方式

## 现象

双击 `HarnessIndex.exe` 时出现：

> 智能应用控制已阻止可能不安全的文件
> 此文件已被阻止，因为来自 Internet 的此类型文件可能存在危险。

这不是文件真的来自 Internet，也不一定是下载标记的问题。Windows 11 的 **智能应用控制（Smart App Control，SAC）** 处于“强制”状态时，会拦截没有可信数字签名的可执行文件。`HarnessIndex.exe` 是本地用 `csc.exe` 编译的 .NET 程序，**没有代码签名**，所以被 SAC 拒绝。

本机实测：

```powershell
Get-AuthenticodeSignature .\HarnessIndex.exe
# Status: NotSigned

Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' |
  Select-Object VerifiedAndReputablePolicyState
# 1 = 强制开启
```

`HarnessIndex.exe` 上也没有 `Zone.Identifier` 数据流，说明不是“从网上下载后忘记解除锁定”这么简单。点弹窗里的“正常/仍要运行”不会把它加入白名单；SAC 没有“只允许这一个文件”的普通用户开关。

## 不要做的事

- **不要为了一个工具关闭智能应用控制。** 关闭 SAC 会降低整台机器的应用信任防线；而且关闭后通常需要重置 Windows 才能重新开启。
- **不要用自签名证书“签名”后分发。** 自签名证书只在你自己的机器上受信任，别人的机器仍然会拦截；它也不是 GitHub 发行版的可信签名。
- **不要把未签名的 exe 放进 GitHub Release 让用户“右键解除锁定”。** 这会把同一个问题传给每一个用户，且容易被杀毒软件标记。

## 本项目采用的方案：不发布 PE 文件

启动器不再是一个自定义 exe，而是：

```text
桌面快捷方式
  └─ 目标：C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe   （微软签名）
       └─ 参数：-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "<安装目录>\server.ps1"
```

也就是说，用户运行的是 **Windows 自带的、由微软签名的 PowerShell**，项目只提供 `.ps1` 脚本、HTML/CSS/JS 和图标。发布包里没有需要签名的 PE 文件，SAC 不会因为“未签名应用”拦截它。

安装脚本还会做两件降低摩擦的事：

1. 用 `Unblock-File` 去掉从 GitHub zip 解压后可能带上的“来自 Internet”标记；
2. 把快捷方式指向 `powershell.exe`，而不是项目目录里的某个 exe。

如果企业或学校机器另外启用了 AppLocker / WDAC / 受限语言模式，仍可能需要管理员放行 PowerShell 脚本；那是另一套策略，不是 SAC。

## 如果以后确实要发布原生 exe

只有两条正路：

### 1. 使用受信任的代码签名证书

- 购买 OV/EV 代码签名证书，或使用 **Azure Trusted Signing**、**SignPath.io**（对开源项目有免费额度）等托管签名服务；
- 用 `signtool.exe` 对 exe 签名并加时间戳；
- 先在干净的 Windows 11（开启 SAC）虚拟机里验证；
- 新证书需要积累 SmartScreen 信誉，刚签名的文件仍可能提示“未知发布者”，直到下载量/时间足够。

### 2. 上架 Microsoft Store / 通过受信任的包管理器分发

Store 或 winget 的签名与信任链由平台处理，适合面向普通用户，但审核和打包成本更高。

## 给 GitHub 项目的发布规则

- Release 里只放 **zip 源码包**（`server.ps1`、`app/`、`assets/`、`install.ps1` 等）；
- 不要提交或上传 `*.exe`；
- 用 `.github/workflows/release.yml` 自动打包并生成 SHA-256；
- 在 README 里明确写“无 PE 文件，不需要代码签名”，减少用户误解。

这样处理的结果不是“这台机器能打开”，而是：**换一台 Windows 11、SAC 开启的机器，按 README 安装后也能正常启动**，并且不会要求用户降低系统安全设置。
