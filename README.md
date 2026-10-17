# Codex MSIX Updater

当 Microsoft Store 无法打开时，这个 Windows 小工具会从公开的 Microsoft Store 清单接口查找匹配当前电脑架构的官方 Codex MSIX，验证包身份后完成安装更新。

## 普通用户

普通用户不需要阅读源码，也不需要手动输入 PowerShell 命令：

1. 打开 GitHub 项目的 **Releases** 页面，下载最新的 `CodexMsixUpdater.exe`。
2. 双击 EXE，在界面中点击“检查并安装”。

如果 Windows 弹出来源确认，请选择允许运行。普通用户不需要安装 PowerShell，也不需要手动解压 ZIP。

更新前请先完全退出 Codex。工具不会强制关闭 Codex，也不会删除其他安装包。

工具会把安装包缓存到 `%LOCALAPPDATA%\CodexMsixUpdater\packages`。勾选“安装成功后删除本次使用的安装包”后，只删除本次实际安装并完成版本回读的那一个 MSIX；最新版、下载失败、校验失败或安装失败时会保留文件。

支持 Windows 10/11 x64 和 ARM64。需要系统自带 Windows PowerShell 5.1、AppX 安装能力，以及能够访问 `delivery.mp.microsoft.com` 的网络。

## 下载与校验

Release 页面提供：

- `CodexMsixUpdater.exe`：普通用户直接双击使用的单文件启动程序。
- `CodexMsixUpdater-portable.zip`：包含源码入口、配置和备用启动器的完整便携包。
- `CodexMsixUpdater-portable.zip.sha256`：便携 ZIP 的 SHA-256 校验值。

GitHub 自动生成的 **Source code (zip)** 是源码快照，适合查看和二次开发；普通用户直接下载 EXE 即可。

## 开发者

仓库中的目录用途如下：

| 路径 | 用途 |
| --- | --- |
| `src/` | PowerShell 主程序和双击启动器 |
| `config/` | 产品 ID、包身份和查询地址等配置 |
| `tests/` | 不执行真实安装的静态检查和隔离工作线程测试 |
| `.github/workflows/` | GitHub Actions 自动验证和标签发布流程 |
| `build-release.ps1` | 生成便携 ZIP 和 SHA-256 文件 |
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

查询接口是第三方公开 Store 清单接口，项目不上传用户数据。接口或官方包身份发生变化时，应同步检查 `config/appsettings.json`、查询解析逻辑和测试，再发布新的 Release。

## 发布流程

维护者完成测试后创建版本标签，例如 `v1.1.0` 并推送到 GitHub。`.github/workflows/release.yml` 会重新运行测试、构建单文件 EXE 和便携 ZIP、生成校验文件，并把它们上传到同名 GitHub Release。不要把近 1 GB 的真实 MSIX、日志、临时图片或个人机器配置提交到仓库。

贡献代码前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)；发现安全问题请阅读 [SECURITY.md](SECURITY.md)。
