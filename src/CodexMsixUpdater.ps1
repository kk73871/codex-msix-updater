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
    # Use the native OS architecture so a 32-bit PowerShell process on x64/ARM64
    # Windows cannot make us select an x86 package or reject a valid package.
    try { $arch = [string][System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture } catch { }
    if ([string]::IsNullOrWhiteSpace($arch)) { $arch = [string]$env:PROCESSOR_ARCHITEW6432 }
    if ([string]::IsNullOrWhiteSpace($arch)) { $arch = [string]$env:PROCESSOR_ARCHITECTURE }
    switch ($arch.ToUpperInvariant()) {
        'X64' { return 'x64' }
        'AMD64' { return 'x64' }
        'ARM64' { return 'arm64' }
        default { throw "此工具支持 Windows x64 和 ARM64；当前 Windows 架构为 $arch。" }
    }
}

function Assert-SupportedWindows {
    $version = [Environment]::OSVersion.Version
    if ($version.Major -lt 10 -or ($version.Major -eq 10 -and $version.Build -lt 19041)) {
        throw "当前 Windows 版本为 $($version.ToString())。官方 Codex MSIX 要求 Windows 10 版本 2004（build 19041）或更高版本；Windows 7 不兼容。"
    }
}

function Get-UserAgent { return 'CodexMsixUpdater/1.0 (Windows)' }
function Write-QueueMessage { param($Queue,[string]$Kind,[string]$Text,[int64]$Done=0,[int64]$Total=0); $Queue.Enqueue([pscustomobject]@{Kind=$Kind;Text=$Text;Done=$Done;Total=$Total}) }
function Test-DeliveryHost { param([Uri]$Uri); return ($Uri.Host -eq $Config.downloadHostSuffix -or $Uri.Host.EndsWith('.' + $Config.downloadHostSuffix)) }
function Test-DownloadHost { param([Uri]$Uri); return ($Uri.Scheme -in @('https','http') -and (Test-DeliveryHost $Uri)) }

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
        $links.Add([pscustomobject]@{FileName=$fileName;Url=$uri.AbsoluteUri;Version=$v;Ring=$Ring;Architecture=$arch})
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
    $current=[Uri]$Url
    $tmp="$Path.download"
    try {
        for ($redirect=0; $redirect -lt 6; $redirect++) {
            if (-not (Test-DownloadHost $current)) { throw '微软清单提供的下载地址或重定向地址无效。' }
            $request=[Net.HttpWebRequest]::Create($current)
            $request.Method='GET'; $request.UserAgent=Get-UserAgent; $request.AllowAutoRedirect=$false
            $request.Timeout=30000; $request.ReadWriteTimeout=30000
            $response=$null; $input=$null; $output=$null
            try {
                $response=$request.GetResponse()
                $status=[int]$response.StatusCode
                if ($status -ge 300 -and $status -lt 400) {
                    $location=$response.Headers['Location']
                    if ([string]::IsNullOrWhiteSpace($location)) { throw '微软下载重定向缺少目标地址。' }
                    $current=[Uri]::new($current,$location)
                    continue
                }
                if ($status -ne 200) { throw "下载响应状态异常：$status。" }
                Write-QueueMessage $Queue 'progress' '正在下载官方 MSIX…' 0 $response.ContentLength
                $input=$response.GetResponseStream()
                $output=[IO.File]::Open($tmp,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
                $buffer=New-Object byte[] (128KB); [int64]$done=0; [int64]$total=$response.ContentLength
                $clock=[Diagnostics.Stopwatch]::StartNew(); [int64]$last=-1
                while (($read=$input.Read($buffer,0,$buffer.Length)) -gt 0) {
                    $output.Write($buffer,0,$read); $done += $read
                    if ($clock.ElapsedMilliseconds -ge ($last + 120)) {
                        Write-QueueMessage $Queue 'progress' '正在下载官方 MSIX…' $done $total
                        $last=$clock.ElapsedMilliseconds
                    }
                }
                $output.Flush(); $output.Dispose(); $output=$null
                if ($total -gt 0 -and $done -ne $total) { throw "下载长度不完整：已收到 $done / $total 字节。" }
                Write-QueueMessage $Queue 'progress' '正在下载官方 MSIX…' $done $total
                Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
                return
            } finally {
                if ($output) { $output.Dispose() }; if ($input) { $input.Dispose() }; if ($response) { $response.Dispose() }
            }
        }
        throw '微软下载重定向次数过多。'
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Invoke-InstallPackage {
    param([string]$Path)
    # Target only Codex; do not close apps using shared dependencies.
    Add-AppxPackage -Path $Path -ForceTargetApplicationShutdown -ErrorAction Stop
}
function Invoke-Worker {
    param($Queue,$DoCheckOnly,$DeleteAfterInstall)
    try {
        Assert-SupportedWindows
        if (-not (Get-Command -Name 'Get-AppxPackage' -ErrorAction SilentlyContinue)) { throw '当前 Windows 环境缺少 AppX 模块（Get-AppxPackage）；无法读取 Codex 安装状态。' }
        if (-not $DoCheckOnly -and -not (Get-Command -Name 'Add-AppxPackage' -ErrorAction SilentlyContinue)) { throw '当前 Windows 环境缺少 Add-AppxPackage；无法用 MSIX 更新 Codex。' }
        if (-not $DoCheckOnly) { $script:LogPath=Join-Path ([IO.Path]::GetTempPath()) ('CodexMsixUpdater-'+[Guid]::NewGuid().ToString('N')+'.log'); [IO.File]::WriteAllText($script:LogPath,"Codex 安装 / 更新日志`r`n",[Text.Encoding]::UTF8) }
        $candidate=Find-CodexPackage $Queue; $installed=@(Get-InstalledCodex); $installedVersion=$null; if ($installed.Count -gt 0) { $installedVersion=[Version]$installed[0].Version }
        $Queue.Enqueue([pscustomobject]@{Kind='result';InstalledVersion=[string]$installedVersion;AvailableVersion=[string]$candidate.Version;FileName=$candidate.FileName;Architecture=$candidate.Architecture;IsCurrent=[bool]($installedVersion -and $installedVersion -ge $candidate.Version)})
        if ($DoCheckOnly) { return }
        if ($installedVersion -and $installedVersion -ge $candidate.Version) { if ($script:LogPath){Remove-Item -LiteralPath $script:LogPath -Force -ErrorAction SilentlyContinue}; Write-QueueMessage $Queue 'done' '已是最新版本，无需下载；未删除任何安装包。'; return }
        $target=Find-CachedCodexPackage -Version $candidate.Version
        if (-not $target) { $target=Join-Path (Get-InstallFolder) ([IO.Path]::GetFileNameWithoutExtension($candidate.FileName)+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)+'.msix'); Download-VerifiedFile $candidate.Url $target $Queue } else { Write-QueueMessage $Queue 'log' '找到匹配版本的本地安装包，将直接复用。' }
        Write-QueueMessage $Queue 'verify' '正在校验安装包…'
        $manifest=Read-CodexManifest $target; if ($manifest.Version -ne $candidate.Version) { throw '安装包清单版本与查询结果不一致，停止安装。' }
        Write-QueueMessage $Queue 'install' 'Windows 正在安装；会自动关闭占用的 Codex。'
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

$form=New-Object Windows.Forms.Form; $form.Text='Codex 更新助手'; $form.StartPosition='CenterScreen'; $form.ClientSize=New-Object Drawing.Size(720,500); $form.BackColor=[Drawing.Color]::FromArgb(245,247,251); $form.Font=New-Object Drawing.Font('Segoe UI',10); $form.MaximizeBox=$false; $form.FormBorderStyle='FixedSingle'
$header=New-Object Windows.Forms.Panel; $header.Location=New-Object Drawing.Point(0,0); $header.Size=New-Object Drawing.Size(720,112); $header.BackColor=[Drawing.Color]::FromArgb(25,42,70); $form.Controls.Add($header)
$title=New-Object Windows.Forms.Label; $title.Text='Codex 更新助手'; $title.ForeColor=[Drawing.Color]::White; $title.Font=New-Object Drawing.Font('Segoe UI Semibold',24); $title.Location=New-Object Drawing.Point(32,18); $title.AutoSize=$true; $header.Controls.Add($title)
$sub=New-Object Windows.Forms.Label; $sub.Text=("无需 Microsoft Store，安全更新官方 Codex（{0}）" -f (Get-Architecture)); $sub.ForeColor=[Drawing.Color]::FromArgb(204,218,238); $sub.Location=New-Object Drawing.Point(35,63); $sub.AutoSize=$true; $header.Controls.Add($sub)
$statusCard=New-Object Windows.Forms.Panel; $statusCard.Location=New-Object Drawing.Point(24,132); $statusCard.Size=New-Object Drawing.Size(672,104); $statusCard.BackColor=[Drawing.Color]::White; $statusCard.BorderStyle='FixedSingle'; $form.Controls.Add($statusCard)
$statusDot=New-Object Windows.Forms.Panel; $statusDot.Location=New-Object Drawing.Point(22,25); $statusDot.Size=New-Object Drawing.Size(16,16); $statusDot.BackColor=[Drawing.Color]::FromArgb(38,166,110); $statusCard.Controls.Add($statusDot)
$state=New-Object Windows.Forms.Label; $state.Text='准备就绪'; $state.Location=New-Object Drawing.Point(52,17); $state.AutoSize=$true; $state.Font=New-Object Drawing.Font('Segoe UI Semibold',15); $state.ForeColor=[Drawing.Color]::FromArgb(25,42,70); $statusCard.Controls.Add($state)
$detail=New-Object Windows.Forms.Label; $detail.Text='点击“检查并安装”，工具会自动完成检查、下载和安装。'; $detail.Location=New-Object Drawing.Point(52,51); $detail.AutoSize=$true; $detail.ForeColor=[Drawing.Color]::FromArgb(86,101,122); $statusCard.Controls.Add($detail)
$stepCard=New-Object Windows.Forms.Panel; $stepCard.Location=New-Object Drawing.Point(24,256); $stepCard.Size=New-Object Drawing.Size(328,132); $stepCard.BackColor=[Drawing.Color]::White; $stepCard.BorderStyle='FixedSingle'; $form.Controls.Add($stepCard)
$stepTitle=New-Object Windows.Forms.Label; $stepTitle.Text='怎么使用'; $stepTitle.Location=New-Object Drawing.Point(18,14); $stepTitle.AutoSize=$true; $stepTitle.Font=New-Object Drawing.Font('Segoe UI Semibold',11); $stepTitle.ForeColor=[Drawing.Color]::FromArgb(25,42,70); $stepCard.Controls.Add($stepTitle)
$stepText=New-Object Windows.Forms.Label; $stepText.Text=('1. 保存 Codex 中的工作' + [Environment]::NewLine + '2. 点击“检查并安装”' + [Environment]::NewLine + '3. 自动退出 Codex 并完成更新'); $stepText.Location=New-Object Drawing.Point(18,43); $stepText.AutoSize=$true; $stepText.ForeColor=[Drawing.Color]::FromArgb(86,101,122); $stepCard.Controls.Add($stepText)
$settingCard=New-Object Windows.Forms.Panel; $settingCard.Location=New-Object Drawing.Point(368,256); $settingCard.Size=New-Object Drawing.Size(328,132); $settingCard.BackColor=[Drawing.Color]::White; $settingCard.BorderStyle='FixedSingle'; $form.Controls.Add($settingCard)
$settingTitle=New-Object Windows.Forms.Label; $settingTitle.Text='更新设置'; $settingTitle.Location=New-Object Drawing.Point(18,14); $settingTitle.AutoSize=$true; $settingTitle.Font=New-Object Drawing.Font('Segoe UI Semibold',11); $settingTitle.ForeColor=[Drawing.Color]::FromArgb(25,42,70); $settingCard.Controls.Add($settingTitle)
$deleteCheck=New-Object Windows.Forms.CheckBox; $deleteCheck.Text='成功后删除本次安装包'; $deleteCheck.Location=New-Object Drawing.Point(18,46); $deleteCheck.AutoSize=$true; $deleteCheck.Checked=$true; $deleteCheck.ForeColor=[Drawing.Color]::FromArgb(55,68,88); $settingCard.Controls.Add($deleteCheck)
$folder=New-Object Windows.Forms.LinkLabel; $folder.Text='打开安装包目录'; $folder.Location=New-Object Drawing.Point(18,85); $folder.AutoSize=$true; $folder.LinkColor=[Drawing.Color]::FromArgb(27,99,170); $settingCard.Controls.Add($folder)
$bar=New-Object Windows.Forms.ProgressBar; $bar.Location=New-Object Drawing.Point(24,408); $bar.Size=New-Object Drawing.Size(672,12); $bar.Minimum=0; $bar.Maximum=100; $bar.Visible=$false; $form.Controls.Add($bar)
$button=New-Object Windows.Forms.Button; $button.Text='检查并安装'; $button.Location=New-Object Drawing.Point(24,435); $button.Size=New-Object Drawing.Size(190,42); $button.BackColor=[Drawing.Color]::FromArgb(27,99,170); $button.ForeColor=[Drawing.Color]::White; $button.Font=New-Object Drawing.Font('Segoe UI Semibold',11); $button.FlatStyle='Flat'; $button.FlatAppearance.BorderSize=0; $button.Cursor=[Windows.Forms.Cursors]::Hand; $form.Controls.Add($button)
$hint=New-Object Windows.Forms.Label; $hint.Text='仅使用官方包，安装失败时不会删除安装包'; $hint.Location=New-Object Drawing.Point(244,447); $hint.AutoSize=$true; $hint.ForeColor=[Drawing.Color]::FromArgb(110,122,140); $form.Controls.Add($hint)
$log=New-Object Windows.Forms.RichTextBox; $log.Location=New-Object Drawing.Point(24,396); $log.Size=New-Object Drawing.Size(672,1); $log.ReadOnly=$true; $log.Visible=$false; $form.Controls.Add($log)
$queue=[Collections.Concurrent.ConcurrentQueue[object]]::new(); $script:ps=$null; $script:async=$null
function Start-Work {
    if ($script:ps) { return }
    $button.Enabled=$false; $deleteCheck.Enabled=$false; $bar.Value=0; $bar.Style='Marquee'; $bar.Visible=$true; $log.Clear(); $state.Text='正在检查…'; $statusDot.BackColor=[Drawing.Color]::FromArgb(245,166,35); $detail.Text='正在查询官方版本，请稍候。'; $hint.Text='安装时会自动退出 Codex，请先保存工作。'
    $script:ps=[PowerShell]::Create()
    $names=@('Get-InstallFolder','Write-QueueMessage','Get-Architecture','Assert-SupportedWindows','Get-UserAgent','Test-DeliveryHost','Test-DownloadHost','Get-OfficialStoreLinks','Find-CodexPackage','Get-InstalledCodex','Read-CodexManifest','Find-CachedCodexPackage','Download-VerifiedFile','Invoke-InstallPackage','Invoke-Worker')
    $defs=ConvertTo-WorkerDefinitions -Names $names
    [void]$script:ps.AddScript(($defs -join "`n"))
    $script:ps.Runspace.SessionStateProxy.SetVariable('Config',$script:Config)
    [void]$script:ps.AddScript('Invoke-Worker $args[0] $args[1] $args[2]').AddArgument($queue).AddArgument([bool]$CheckOnly).AddArgument([bool]$deleteCheck.Checked)
    $script:async=$script:ps.BeginInvoke()
}
function Update-WorkerMessage {
    param($Item)
    switch ($Item.Kind) {
        'progress' {
            $bar.Visible=$true
            if ($Item.Total -gt 0) {
                $percent=[int][Math]::Floor([Math]::Min(100.0,[Math]::Max(0.0,100.0*$Item.Done/$Item.Total)))
                $bar.Style='Continuous'; $bar.Value=$percent
                $state.Text="正在下载… $percent%"
                $detail.Text=("已下载 {0:N1} MB / {1:N1} MB" -f ($Item.Done/1MB),($Item.Total/1MB))
            } else {
                $bar.Style='Marquee'; $state.Text='正在下载…'
                $detail.Text=("已下载 {0:N1} MB（服务器未提供总大小）" -f ($Item.Done/1MB))
            }
            $hint.Text='正在下载官方安装包，请勿关闭窗口。'
        }
        'verify' {
            $bar.Style='Marquee'; $state.Text='正在校验…'; $detail.Text=$Item.Text
            $hint.Text='正在核对安装包版本和官方身份。'
        }
        'install' {
            $bar.Style='Marquee'; $state.Text='正在安装…'; $detail.Text=$Item.Text
            $hint.Text='安装结束后，即可重新打开 Codex。'
        }
        'log' { $log.AppendText("$($Item.Text)`r`n"); $detail.Text=$Item.Text }
        'done' {
            $state.Text='更新完成'; $statusDot.BackColor=[Drawing.Color]::FromArgb(38,166,110)
            $detail.Text=$Item.Text; $hint.Text='你现在可以打开 Codex 继续使用。'
            $bar.Visible=$false; $button.Enabled=$true; $deleteCheck.Enabled=$true
        }
        'error' {
            $state.Text='更新未完成'; $statusDot.BackColor=[Drawing.Color]::FromArgb(205,70,70)
            $detail.Text=$Item.Text; $hint.Text='安装包会保留，可再次点击“检查并安装”。'
            $bar.Visible=$false; $button.Enabled=$true; $deleteCheck.Enabled=$true
            [Windows.Forms.MessageBox]::Show($form,$Item.Text,'Codex 更新','OK','Error')|Out-Null
        }
    }
}
$button.Add_Click({Start-Work})
$folder.Add_LinkClicked({Start-Process explorer.exe -ArgumentList ('"{0}"' -f (Get-InstallFolder))})
$timer=New-Object Windows.Forms.Timer; $timer.Interval=120
$timer.Add_Tick({
    $item=$null
    while($queue.TryDequeue([ref]$item)){ Update-WorkerMessage $item }
    if($script:async -and $script:async.IsCompleted -and $script:ps){
        $script:ps.EndInvoke($script:async); $script:ps.Dispose(); $script:ps=$null; $script:async=$null
    }
})
$timer.Start()
if($PreviewPath){$form.Show();$form.Opacity=0;[Windows.Forms.Application]::DoEvents();$bmp=New-Object Drawing.Bitmap($form.Width,$form.Height);$form.DrawToBitmap($bmp,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)));$bmp.Save($PreviewPath,[Drawing.Imaging.ImageFormat]::Png);$bmp.Dispose();$form.Close();$timer.Stop();$form.Dispose();exit 0};[void]$form.ShowDialog();$timer.Stop();if($script:ps){$script:ps.Stop();$script:ps.Dispose()};$form.Dispose()
