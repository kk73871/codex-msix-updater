# Codex MSIX Updater

当 Microsoft Store 无法打开时，这个 Windows 小工具会从公开的 Microsoft Store 清单接口查找匹配当前电脑架构的官方 Codex MSIX，验证包身份后完成安装更新。

## 普通用户

普通用户不需要阅读源码，也不需要手动输入 PowerShell 命令：

1. 打开 GitHub 项目的 **Releases** 页面，下载最新的 `CodexMsixUpdater.exe`。
2. 双击 EXE，在界面中点击“检查并安装”。

如果 Windows 弹出来源确认，请选择允许运行。普通用户不需要安装 PowerShell，也不需要手动解压 ZIP。

更新前请先保存 Codex 中的工作。下载时会显示百分比和已下载大小；服务器未提供总大小时，显示已下载大小和动态进度条。安装时由 Windows 自动关闭目标 Codex 应用包关联的进程，并继续安装，无需手动查找或结束后台进程；工具不会按进程名称关闭程序，也不会删除其他安装包。

工具会把安装包缓存到 `%LOCALAPPDATA%\CodexMsixUpdater\packages`。勾选“安装成功后删除本次使用的安装包”后，只删除本次实际安装并完成版本回读的那一个 MSIX；最新版、下载失败、校验失败或安装失败时会保留文件。

支持 Windows 10（版本 2004 / build 19041 及更高版本）和 Windows 11 的 x64、ARM64 系统。工具按 Windows 原生架构选择 Codex MSIX，即使启动器落在 32 位 PowerShell 或 ARM64 的模拟环境中，也不会按进程架构误选安装包。需要系统自带 Windows PowerShell 5.1、AppX 安装能力，以及能够访问 `delivery.mp.microsoft.com` 的网络。

Windows 7 不兼容。当前官方 Codex MSIX 的 `TargetDeviceFamily` 最低版本是 `Windows.Desktop 10.0.19041.0`；更新器会在查询前直接提示系统版本过低，不会下载或删除安装包。

## 下载与校验

Release 页面只手动上传一个文件：

- `CodexMsixUpdater.exe`：普通用户直接双击使用的单文件启动程序。

开发者可使用 GitHub 自动生成的 **Source code (zip)** 或 **Source code (tar.gz)** 查看和二次开发；普通用户只需下载 EXE。GitHub 会自动在每个 Release 下显示这两个源码快照。

## 开发者

仓库中的目录用途如下：

| 路径 | 用途 |
| --- | --- |
| `src/` | PowerShell 主程序和双击启动器 |
| `config/` | 产品 ID、包身份和查询地址等配置 |
| `tests/` | 不执行真实安装的静态检查和隔离工作线程测试 |
| `.github/workflows/` | GitHub Actions 自动验证和标签发布流程 |
| `build-release.ps1` | 生成单文件 EXE |
| `LICENSE` | 开源许可 |

本地检查：

```powershell
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\CodexMsixUpdater.ps1 -CheckOnly
```

运行测试：

```powershell
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-CodexMsixUpdater.ps1
```

生成发布文件（PowerShell 7）：

```powershell
pwsh -NoProfile -File .\build-release.ps1
```

查询接口是第三方公开 Store 清单接口，项目不上传用户数据。下载使用清单给出的微软 CDN 地址和协议，避免把 CDN 返回的 HTTP 地址强行改成证书名称不匹配的 HTTPS 地址；MSIX 签名和包身份仍由 Windows 安装器验证。接口或官方包身份发生变化时，应同步检查 `config/appsettings.json`、查询解析逻辑和测试，再发布新的 Release。

## 发布流程

项目只维护一个 `v1.0.0` Release。维护者更新源码后，将 `v1.0.0` 标签移动到新提交并推送；`.github/workflows/release.yml` 会重新运行测试、构建 EXE、清理其他手动上传的 Release 文件，并只上传 `CodexMsixUpdater.exe`。GitHub 自动生成的 ZIP 和 TAR.GZ 源码快照仍由平台提供。不要把近 1 GB 的真实 MSIX、日志、临时图片或个人机器配置提交到仓库。

贡献代码前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)；发现安全问题请阅读 [SECURITY.md](SECURITY.md)。
