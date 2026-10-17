# 贡献指南

## 开始之前

请先确认问题确实与本工具有关，并在 Issue 中说明 Windows 版本、系统架构、PowerShell 版本和完整错误信息。不要上传个人路径、下载日志或真实 MSIX 文件。

## 本地验证

使用 Windows PowerShell 5.1 运行：

```powershell
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-CodexMsixUpdater.ps1
```

测试只做语法检查、配置检查和隔离工作线程测试，不会安装或更新真实 Codex。改动查询或包校验逻辑时，还应使用 `-CheckOnly` 做一次只读检查。

## 提交改动

保持用户界面简单，避免把技术细节暴露给普通用户。涉及下载、包身份、架构或删除行为的改动，需要同步更新 README 和测试。提交前运行 `pwsh -NoProfile -File .\build-release.ps1`，确认发布包中没有 `.msix`、日志或临时文件。
