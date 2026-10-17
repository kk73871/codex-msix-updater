#requires -version 5.1
[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [string]$PreviewPath,
    [string]$ConfigPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:Root = Split-Path -Parent $PSScriptRoot
$script:ConfigFile = if ($ConfigPath) { $ConfigPath } else { Join-Path $script:Root 'config\appsettings.json' }
$script:Config = $null
$script:LogPath = $null

function Read-Config {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "找不到配置文件：$Path" }
    $cfg = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($key in @('productId','queryEndpoint','queryPage','publisher','packageName','packageFamilyName','downloadHostSuffix','retailRing','fallbackRing')) {
        if ([string]::IsNullOrWhiteSpace([string]$cfg.$key)) { throw "配置项为空：$key" }
    }
    if (([Uri]$cfg.queryEndpoint).Scheme -ne 'https' -or ([Uri]$cfg.queryPage).Scheme -ne 'https') { throw '查询地址必须使用 HTTPS。' }
    return $cfg
}

function Get-InstallFolder {
    $folder = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexMsixUpdater\packages'
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    return $folder
}

function Get-Architecture {
    $arch = $null
    try { $arch = [string][System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture } catch { }
    if ([string]::IsNullOrWhiteSpace($arch)) { $arch = [string]$env:PROCESSOR_ARCHITECTURE }
    switch ($arch.ToUpperInvariant()) {
        'X64' { return 'x64' }
        'AMD64' { return 'x64' }
        'ARM64' { return 'arm64' }
        default { throw "此工具支持 Windows x64 和 ARM64；当前架构为 $arch。" }
    }
}

function Get-UserAgent { return 'CodexMsixUpdater/1.0 (Windows)' }
function Write-QueueMessage { param($Queue,[string]$Kind,[string]$Text,[int64]$Done=0,[int64]$Total=0); $Queue.Enqueue([pscustomobject]@{Kind=$Kind;Text=$Text;Done=$Done;Total=$Total}) }
function Test-DeliveryHost { param([Uri]$Uri); return ($Uri.Host -eq $Config.downloadHostSuffix -or $Uri.Host.EndsWith('.' + $Config.downloadHostSuffix)) }
function Test-DownloadHost { param([Uri]$Uri); return ($Uri.Scheme -eq 'https' -and (Test-DeliveryHost $Uri)) }

function Get-OfficialStoreLinks {
    param([string]$Ring,$Queue)
    Write-QueueMessage $Queue 'log' ("正在查询 Microsoft Store 清单（$Ring）…")
    $body = @{ type='ProductId'; url=[string]$Config.productId; ring=$Ring; lang='en-US' }
    $headers = @{ 'User-Agent'=(Get-UserAgent); Accept='text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'; 'Accept-Language'='en-US,en;q=0.9'; Referer=[string]$Config.queryPage; Origin=([string]$Config.queryPage).TrimEnd('/') }
    $response = Invoke-WebRequest -Uri ([string]$Config.queryEndpoint) -Method Post -Body $body -Headers $headers -UseBasicParsing -TimeoutSec 35
    $links = New-Object System.Collections.Generic.List[object]
    $arch = Get-Architecture
    $pattern = '<a\b[^>]*href\s*=\s*["''](?<url>[^"'']+)["''][^>]*>(?<text>.*?)</a>'
    foreach ($m in [regex]::Matches($response.Content,$pattern,[Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::Singleline)) {
        $raw = [Net.WebUtility]::HtmlDecode($m.Groups['url'].Value).Trim(); $anchor = [Net.WebUtility]::HtmlDecode(([regex]::Replace($m.Groups['text'].Value,'<[^>]+>',''))).Trim()
        $uri=$null; if (-not [Uri]::TryCreate($raw,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -notin @('http','https') -or -not (Test-DeliveryHost $uri)) { continue }
        $fileName = if ($anchor -match '\.msix$') { $anchor } else { [IO.Path]::GetFileName($uri.AbsolutePath) }
        $escapedName=[regex]::Escape([string]$Config.packageName); $escapedArch=[regex]::Escape($arch)
        $vm=[regex]::Match($fileName,"^${escapedName}_(?<version>\d+(?:\.\d+){1,3})_${escapedArch}__[a-z0-9]+\.msix$",[Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $vm.Success) { continue }
        $v=$null; if (-not [Version]::TryParse($vm.Groups['version'].Value,[ref]$v)) { continue }
        $secureUri=[UriBuilder]$uri; $secureUri.Scheme='https'; $secureUri.Port=-1
        $links.Add([pscustomobject]@{FileName=$fileName;Url=$secureUri.Uri.AbsoluteUri;Version=$v;Ring=$Ring;Architecture=$arch})
    }
    return $links
}

function Find-CodexPackage { param($Queue)
    $items=@(Get-OfficialStoreLinks ([string]$Config.retailRing) $Queue)
    if ($items.Count -eq 0) { $items=@(Get-OfficialStoreLinks ([string]$Config.fallbackRing) $Queue) }
    if ($items.Count -eq 0) { throw "未找到官方 $($Config.packageName) $(Get-Architecture) MSIX。" }
    return ($items | Sort-Object Version -Descending | Select-Object -First 1)
}

function Get-InstalledCodex {
    return @(Get-AppxPackage -Name ([string]$Config.packageName) -ErrorAction Stop | Sort-Object { [Version]$_.Version } -Descending | Select-Object -First 1)
}

function Read-CodexManifest {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw '安装包文件不存在。' }
    if ([IO.Path]::GetExtension($Path) -ine '.msix') { throw '只接受 .msix 文件。' }
    if ((Get-Item -LiteralPath $Path).Length -lt 1MB) { throw '安装包体积异常小，下载可能不完整。' }
    $archive=[IO.Compression.ZipFile]::OpenRead($Path)
    try {
        if ($null -eq $archive.GetEntry('AppxSignature.p7x')) { throw '安装包缺少签名。' }
        $entry=$archive.GetEntry('AppxManifest.xml'); if ($null -eq $entry) { throw '安装包缺少 AppxManifest.xml。' }
        $stream=$entry.Open(); $settings=New-Object Xml.XmlReaderSettings; $settings.DtdProcessing='Prohibit'; $settings.XmlResolver=$null; $reader=[Xml.XmlReader]::Create($stream,$settings)
        try { $xml=New-Object Xml.XmlDocument; $xml.XmlResolver=$null; $xml.Load($reader) } finally { $reader.Dispose(); $stream.Dispose() }
        $id=$xml.SelectSingleNode("/*[local-name()='Package']/*[local-name()='Identity']"); if ($null -eq $id) { throw '无法读取安装包身份。' }
        $name=[string]$id.GetAttribute('Name'); $arch=[string]$id.GetAttribute('ProcessorArchitecture'); $pub=[string]$id.GetAttribute('Publisher'); $ver=[string]$id.GetAttribute('Version')
        if ($name -ne $Config.packageName) { throw "包身份不是 $($Config.packageName)，而是 $name。" }
        if ($arch -ne (Get-Architecture)) { throw "包架构是 $arch，不是当前系统架构。" }
        if ($pub -ne $Config.publisher) { throw "包发布者不匹配：$pub。" }
        return [pscustomobject]@{Name=$name;Architecture=$arch;Publisher=$pub;Version=[Version]$ver}
    } finally { $archive.Dispose() }
}

function Find-CachedCodexPackage {
    param([Version]$Version)
    foreach($file in @(Get-ChildItem -LiteralPath (Get-InstallFolder) -File -Filter "$($Config.packageName)_*.msix" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        try { $manifest=Read-CodexManifest $file.FullName } catch { continue }
        if ($manifest.Version -eq $Version) { return $file.FullName }
    }
    return $null
}

function Download-VerifiedFile {
    param([string]$Url,[string]$Path,$Queue)
    $current=$Url
    for ($i=0;$i -lt 5;$i++) {
        $u=[Uri]$current; if (-not (Test-DownloadHost $u)) { throw '下载地址或重定向不在微软 delivery.mp.microsoft.com HTTPS 边界内。' }
        $req=[Net.HttpWebRequest]::Create($u); $req.Method='GET'; $req.UserAgent=(Get-UserAgent); $req.AllowAutoRedirect=$false; $req.Timeout=30000; $req.ReadWriteTimeout=30000
        $res=$req.GetResponse()
        if ([int]$res.StatusCode -ge 300 -and [int]$res.StatusCode -lt 400) { $next=$res.Headers['Location']; $res.Dispose(); if ([string]::IsNullOrWhiteSpace($next)) { throw '微软下载重定向缺少 Location。' }; $current=([Uri]::new($u,$next)).AbsoluteUri; continue }
        if ([int]$res.StatusCode -ne 200) { $res.Dispose(); throw "下载响应状态异常：$([int]$res.StatusCode)。" }
        $total=$res.ContentLength; $tmp="$Path.download"; $input=$null; $output=$null
        try { $input=$res.GetResponseStream(); $output=[IO.File]::Open($tmp,[IO.FileMode]::CreateNew); $buf=New-Object byte[] (1024*128); [int64]$done=0; $clock=[Diagnostics.Stopwatch]::StartNew(); [int64]$last=0; do { $n=$input.Read($buf,0,$buf.Length); if ($n -gt 0) { $output.Write($buf,0,$n); $done += $n; if ($clock.ElapsedMilliseconds-$last -ge 150) { Write-QueueMessage $Queue 'progress' '正在下载官方 MSIX…' $done $total; $last=$clock.ElapsedMilliseconds } } } while ($n -gt 0); if ($total -gt 0 -and $done -ne $total) { throw '下载长度与微软服务器声明不符，请重试。' }; $output.Dispose(); $output=$null; $input.Dispose(); $input=$null; $res.Dispose(); Move-Item -LiteralPath $tmp -Destination $Path; return } catch { if ($output) {$output.Dispose()}; if ($input) {$input.Dispose()}; $res.Dispose(); if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }; throw }
    }
    throw '微软下载重定向次数过多。'
}

function Invoke-InstallPackage {
    param([string]$Path)
    Add-AppxPackage -Path $Path -ErrorAction Stop
}

function Invoke-Worker {
    param($Queue,$DoCheckOnly,$DeleteAfterInstall)
    try {
        if (-not (Get-Command -Name 'Get-AppxPackage' -ErrorAction SilentlyContinue)) { throw '当前 Windows 环境缺少 AppX 模块（Get-AppxPackage）；无法读取 Codex 安装状态。' }
        if (-not $DoCheckOnly -and -not (Get-Command -Name 'Add-AppxPackage' -ErrorAction SilentlyContinue)) { throw '当前 Windows 环境缺少 Add-AppxPackage；无法用 MSIX 更新 Codex。' }
        if (-not $DoCheckOnly) { $script:LogPath=Join-Path ([IO.Path]::GetTempPath()) ('CodexMsixUpdater-'+[Guid]::NewGuid().ToString('N')+'.log'); [IO.File]::WriteAllText($script:LogPath,"Codex 安装 / 更新日志`r`n",[Text.Encoding]::UTF8) }
        $candidate=Find-CodexPackage $Queue; $installed=@(Get-InstalledCodex); $installedVersion=$null; if ($installed.Count -gt 0) { $installedVersion=[Version]$installed[0].Version }
        $Queue.Enqueue([pscustomobject]@{Kind='result';InstalledVersion=[string]$installedVersion;AvailableVersion=[string]$candidate.Version;FileName=$candidate.FileName;Architecture=$candidate.Architecture;IsCurrent=[bool]($installedVersion -and $installedVersion -ge $candidate.Version)})
        if ($DoCheckOnly) { return }
        if ($installedVersion -and $installedVersion -ge $candidate.Version) { if ($script:LogPath){Remove-Item -LiteralPath $script:LogPath -Force -ErrorAction SilentlyContinue}; Write-QueueMessage $Queue 'done' '已是最新版本，无需下载；未删除任何安装包。'; return }
        if (@(Get-Process -Name Codex -ErrorAction SilentlyContinue).Count -gt 0) { throw '检测到 Codex 正在运行，请先关闭后再重试。' }
        $target=Find-CachedCodexPackage -Version $candidate.Version
        if (-not $target) { $target=Join-Path (Get-InstallFolder) ([IO.Path]::GetFileNameWithoutExtension($candidate.FileName)+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)+'.msix'); Download-VerifiedFile $candidate.Url $target $Queue } else { Write-QueueMessage $Queue 'log' '找到匹配版本的本地安装包，将直接复用。' }
        $manifest=Read-CodexManifest $target; if ($manifest.Version -ne $candidate.Version) { throw '安装包清单版本与查询结果不一致，停止安装。' }
        if (@(Get-Process -Name Codex -ErrorAction SilentlyContinue).Count -gt 0) { throw '检测到 Codex 正在运行，请先关闭后再重试。' }
        Invoke-InstallPackage $target
        $after=@(Get-InstalledCodex); if ($after.Count -eq 0 -or [Version]$after[0].Version -lt $manifest.Version -or $after[0].Publisher -ne $Config.publisher -or $after[0].PackageFamilyName -ne $Config.packageFamilyName) { throw '安装命令返回后，未能读回目标版本和官方身份。' }
        if ($script:LogPath){Remove-Item -LiteralPath $script:LogPath -Force -ErrorAction SilentlyContinue}
        $text="已更新到 $($after[0].Version)。"; if ($DeleteAfterInstall) { try { Remove-Item -LiteralPath $target -Force -ErrorAction Stop; $text += '已删除本次成功安装所用的安装包。' } catch { $text += '删除本次安装包失败，文件仍保留。' } } else { $text += '安装包已保留。' }; Write-QueueMessage $Queue 'done' $text
    } catch { if ($script:LogPath) { $failure=Join-Path (Get-InstallFolder) ('Codex-failed-'+[DateTime]::Now.ToString('yyyyMMdd-HHmmss-fff')+'.log'); Move-Item -LiteralPath $script:LogPath -Destination $failure -Force -ErrorAction SilentlyContinue; $Queue.Enqueue([pscustomobject]@{Kind='logpath';Text=$failure}) }; Write-QueueMessage $Queue 'error' $_.Exception.Message }
}

function ConvertTo-WorkerDefinitions {
    param([string[]]$Names)
    foreach ($name in $Names) {
        $function = Get-Command -Name $name -CommandType Function -ErrorAction Stop
        "function $name {`n$($function.ScriptBlock.ToString())`n}"
    }
}

$script:Config=Read-Config $script:ConfigFile
if ($CheckOnly) { $q=[Collections.Concurrent.ConcurrentQueue[object]]::new(); Invoke-Worker $q $true $false; $item=$null; while ($q.TryDequeue([ref]$item)) { if ($item.Kind -eq 'result') { $item | ConvertTo-Json -Compress } elseif ($item.Kind -eq 'error') { [Console]::Error.WriteLine($item.Text); exit 1 } }; exit 0 }
if ($PSVersionTable.PSVersion.Major -gt 5 -and -not $PreviewPath) { throw '请使用同目录的 Start-CodexMsixUpdater.cmd 启动，以确保使用 Windows PowerShell 5.1。' }

$form=New-Object Windows.Forms.Form; $form.Text='Codex 更新'; $form.StartPosition='CenterScreen'; $form.ClientSize=New-Object Drawing.Size(620,390); $form.BackColor=[Drawing.Color]::FromArgb(246,248,252); $form.Font=New-Object Drawing.Font('Segoe UI',10); $form.MaximizeBox=$false
$header=New-Object Windows.Forms.Panel; $header.Dock='Top'; $header.Height=104; $header.BackColor=[Drawing.Color]::FromArgb(22,31,49); $form.Controls.Add($header)
$title=New-Object Windows.Forms.Label; $title.Text='Codex 更新'; $title.ForeColor=[Drawing.Color]::White; $title.Font=New-Object Drawing.Font('Segoe UI Semibold',24); $title.Location=New-Object Drawing.Point(28,17); $title.AutoSize=$true; $header.Controls.Add($title)
$sub=New-Object Windows.Forms.Label; $sub.Text=("获取官方 {0} 版本" -f (Get-Architecture)); $sub.ForeColor=[Drawing.Color]::FromArgb(179,198,226); $sub.Location=New-Object Drawing.Point(31,65); $sub.AutoSize=$true; $header.Controls.Add($sub)
$state=New-Object Windows.Forms.Label; $state.Text='准备就绪'; $state.Location=New-Object Drawing.Point(28,130); $state.AutoSize=$true; $state.Font=New-Object Drawing.Font('Segoe UI Semibold',14); $form.Controls.Add($state)
$detail=New-Object Windows.Forms.Label; $detail.Text='点击下方按钮检查版本并安装更新。'; $detail.Location=New-Object Drawing.Point(28,166); $detail.AutoSize=$true; $form.Controls.Add($detail)
$bar=New-Object Windows.Forms.ProgressBar; $bar.Location=New-Object Drawing.Point(28,210); $bar.Size=New-Object Drawing.Size(564,16); $bar.Minimum=0; $bar.Maximum=100; $bar.Visible=$false; $form.Controls.Add($bar)
$deleteCheck=New-Object Windows.Forms.CheckBox; $deleteCheck.Text='安装成功后删除本次使用的安装包'; $deleteCheck.Location=New-Object Drawing.Point(28,240); $deleteCheck.AutoSize=$true; $deleteCheck.Checked=$true; $form.Controls.Add($deleteCheck)
$log=New-Object Windows.Forms.RichTextBox; $log.Location=New-Object Drawing.Point(28,270); $log.Size=New-Object Drawing.Size(564,44); $log.ReadOnly=$true; $log.BorderStyle='None'; $log.BackColor=[Drawing.Color]::FromArgb(237,242,249); $form.Controls.Add($log)
$button=New-Object Windows.Forms.Button; $button.Text='检查并安装'; $button.Location=New-Object Drawing.Point(28,337); $button.Size=New-Object Drawing.Size(180,42); $form.Controls.Add($button)
$folder=New-Object Windows.Forms.LinkLabel; $folder.Text='打开安装包目录'; $folder.Location=New-Object Drawing.Point(470,349); $folder.AutoSize=$true; $form.Controls.Add($folder)
$queue=[Collections.Concurrent.ConcurrentQueue[object]]::new(); $script:ps=$null; $script:async=$null
function Start-Work {
    if ($script:ps) { return }
    $button.Enabled=$false; $deleteCheck.Enabled=$false; $bar.Visible=$true; $log.Clear(); $state.Text='正在检查…'
    $script:ps=[PowerShell]::Create()
    $names=@('Get-InstallFolder','Write-QueueMessage','Get-Architecture','Get-UserAgent','Test-DeliveryHost','Test-DownloadHost','Get-OfficialStoreLinks','Find-CodexPackage','Get-InstalledCodex','Read-CodexManifest','Find-CachedCodexPackage','Download-VerifiedFile','Invoke-InstallPackage','Invoke-Worker')
    $defs=ConvertTo-WorkerDefinitions -Names $names
    [void]$script:ps.AddScript(($defs -join "`n"))
    $script:ps.Runspace.SessionStateProxy.SetVariable('Config',$script:Config)
    [void]$script:ps.AddScript('Invoke-Worker $args[0] $args[1] $args[2]').AddArgument($queue).AddArgument([bool]$CheckOnly).AddArgument([bool]$deleteCheck.Checked)
    $script:async=$script:ps.BeginInvoke()
}
$button.Add_Click({Start-Work}); $folder.Add_LinkClicked({Start-Process explorer.exe -ArgumentList ('"{0}"' -f (Get-InstallFolder))}); $timer=New-Object Windows.Forms.Timer; $timer.Interval=120; $timer.Add_Tick({$item=$null;while($queue.TryDequeue([ref]$item)){if($item.Kind -eq 'progress' -and $item.Total -gt 0){$bar.Value=[Math]::Min(100,[Math]::Max(0,[int](100*$item.Done/$item.Total)));$detail.Text=("{0}  {1:N1} MB / {2:N1} MB" -f $item.Text,($item.Done/1MB),($item.Total/1MB))}elseif($item.Kind -eq 'log'){$log.AppendText("$($item.Text)`r`n");$detail.Text=$item.Text}elseif($item.Kind -eq 'done'){$state.Text='完成';$detail.Text=$item.Text;$bar.Visible=$false;$button.Enabled=$true;$deleteCheck.Enabled=$true}elseif($item.Kind -eq 'error'){$state.Text='需要处理';$detail.Text=$item.Text;$bar.Visible=$false;$button.Enabled=$true;$deleteCheck.Enabled=$true;[Windows.Forms.MessageBox]::Show($form,$item.Text,'Codex 更新','OK','Error')|Out-Null}}if($script:async -and $script:async.IsCompleted -and $script:ps){$script:ps.EndInvoke($script:async);$script:ps.Dispose();$script:ps=$null;$script:async=$null}});$timer.Start()
if($PreviewPath){$form.Show();$form.Opacity=0;[Windows.Forms.Application]::DoEvents();$bmp=New-Object Drawing.Bitmap($form.Width,$form.Height);$form.DrawToBitmap($bmp,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)));$bmp.Save($PreviewPath,[Drawing.Imaging.ImageFormat]::Png);$bmp.Dispose();$form.Close();$timer.Stop();$form.Dispose();exit 0};[void]$form.ShowDialog();$timer.Stop();if($script:ps){$script:ps.Stop();$script:ps.Dispose()};$form.Dispose()
