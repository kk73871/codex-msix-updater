#requires -version 7.0
[CmdletBinding()]
param([string]$OutputDirectory = (Join-Path $PSScriptRoot 'dist'))

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($PSScriptRoot)
$dist = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $dist.StartsWith($root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'OutputDirectory must stay inside the project.' }
New-Item -ItemType Directory -Path $dist -Force | Out-Null

$stream = [IO.MemoryStream]::new()
$zip = [IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
try {
    foreach ($relative in @('config/appsettings.json','src/CodexMsixUpdater.ps1')) {
        $path = Join-Path $root $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required runtime file is missing: $relative" }
        $item = Get-Item -LiteralPath $path
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Runtime input contains a reparse point: $relative" }
        $entry = $zip.CreateEntry($relative.Replace('\','/'),[IO.Compression.CompressionLevel]::Optimal)
        $input = [IO.File]::OpenRead($path)
        $output = $entry.Open()
        try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
    }
} finally { $zip.Dispose() }
$payloadBytes = $stream.ToArray()
$stream.Dispose()
$payload = [Convert]::ToBase64String($payloadBytes)
$sha = [Security.Cryptography.SHA256]::Create()
try { $buildId = [BitConverter]::ToString($sha.ComputeHash($payloadBytes)).Replace('-','').Substring(0,16) } finally { $sha.Dispose() }

# Compile a small .NET Framework launcher so ordinary users can double-click one EXE.
$launcherPath = Join-Path $dist 'CodexMsixUpdater.exe'
$launcherSourcePath = Join-Path $dist 'CodexMsixUpdater.Launcher.cs'
$launcherSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Text;

public static class Program
{
    private const string Payload = "__PAYLOAD__";
    private const string BuildId = "__BUILD_ID__";

    public static int Main()
    {
        try
        {
            string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexMsixUpdater", "runtime");
            Directory.CreateDirectory(root);
            string marker = Path.Combine(root, "runtime.version");
            if (!File.Exists(marker) || File.ReadAllText(marker).Trim() != BuildId)
            {
                using (MemoryStream input = new MemoryStream(Convert.FromBase64String(Payload)))
                using (ZipArchive archive = new ZipArchive(input, ZipArchiveMode.Read))
                {
                    string rootFull = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
                    foreach (ZipArchiveEntry entry in archive.Entries)
                    {
                        string target = Path.GetFullPath(Path.Combine(root, entry.FullName));
                        if (!target.StartsWith(rootFull, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Invalid runtime path.");
                        string parent = Path.GetDirectoryName(target);
                        if (!String.IsNullOrEmpty(parent)) Directory.CreateDirectory(parent);
                        if (!String.IsNullOrEmpty(entry.Name)) entry.ExtractToFile(target, true);
                    }
                }
                File.WriteAllText(marker, BuildId, Encoding.UTF8);
            }

            string script = Path.Combine(root, "src", "CodexMsixUpdater.ps1");
            string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
            ProcessStartInfo start = new ProcessStartInfo();
            start.FileName = powershell;
            start.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\"";
            start.WorkingDirectory = Path.GetDirectoryName(script);
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            Process.Start(start);
            return 0;
        }
        catch (Exception error)
        {
            try { MessageBox(error.Message); } catch { }
            return 1;
        }
    }

    private static void MessageBox(string message)
    {
        System.Windows.Forms.MessageBox.Show(message, "Codex 更新助手", System.Windows.Forms.MessageBoxButtons.OK, System.Windows.Forms.MessageBoxIcon.Error);
    }
}
'@
$launcherSource = $launcherSource.Replace('__PAYLOAD__',$payload).Replace('__BUILD_ID__',$buildId)
[IO.File]::WriteAllText($launcherSourcePath,$launcherSource,[Text.UTF8Encoding]::new($false))
try {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) { throw '找不到 Windows .NET Framework 编译器，无法生成 EXE。' }
    & $csc /nologo /target:winexe /out:$launcherPath /reference:System.Windows.Forms.dll /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll $launcherSourcePath
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) { throw 'EXE 编译失败。' }
} finally {
    if (Test-Path -LiteralPath $launcherSourcePath -PathType Leaf) { Remove-Item -LiteralPath $launcherSourcePath -Force }
}

Get-Item -LiteralPath $launcherPath | Select-Object FullName,Length,LastWriteTime
