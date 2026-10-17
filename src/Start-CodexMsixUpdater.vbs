Option Explicit
Dim shell, fso, scriptPath, powershellPath, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptPath = fso.BuildPath(fso.GetParentFolderName(WScript.ScriptFullName), "CodexMsixUpdater.ps1")
powershellPath = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
If Not fso.FileExists(scriptPath) Then
  MsgBox "找不到更新器脚本：" & scriptPath, vbCritical, "Codex 更新"
  WScript.Quit 2
End If
If Not fso.FileExists(powershellPath) Then
  MsgBox "找不到 Windows PowerShell 5.1。", vbCritical, "Codex 更新"
  WScript.Quit 3
End If
command = Chr(34) & powershellPath & Chr(34) & " -NoLogo -NoProfile -ExecutionPolicy Bypass -File " & Chr(34) & scriptPath & Chr(34)
shell.Run command, 0, False
