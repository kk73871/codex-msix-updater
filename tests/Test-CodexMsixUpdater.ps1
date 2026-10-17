#requires -version 5.1
[CmdletBinding()]
param([string]$Root)
$ErrorActionPreference='Stop'
$Root = if ($Root) { $Root } else { Split-Path -Parent $PSScriptRoot }
$scriptPath=Join-Path $Root 'src\CodexMsixUpdater.ps1'
$tokens=$null;$errors=$null
[void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors | ForEach-Object Message | Out-String)}
if((Get-Content (Join-Path $Root 'config\appsettings.json') -Raw -Encoding UTF8 | ConvertFrom-Json).packageName -ne 'OpenAI.Codex'){throw 'config packageName check failed'}
$cmd=Get-Content (Join-Path $Root 'src\Start-CodexMsixUpdater.cmd') -Raw
if($cmd -notmatch 'WindowsPowerShell\\v1\.0\\powershell\.exe'){throw 'launcher check failed'}

$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
$workerFunction = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-Worker' }, $true)
if($workerFunction.Count -ne 1) { throw 'Invoke-Worker function not found.' }
$converterFunction = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'ConvertTo-WorkerDefinitions' }, $true)
$startFunction = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Start-Work' }, $true)
if($converterFunction.Count -ne 1 -or $startFunction.Count -ne 1) { throw 'Worker definition helper or UI worker entry point not found.' }
$namesAssignment = $startFunction[0].FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $node.Left.VariablePath.UserPath -eq 'names' }, $true)
if($namesAssignment.Count -ne 1) { throw 'Worker function list not found in UI entry point.' }
$names = & ([ScriptBlock]::Create('$names=' + $namesAssignment[0].Right.Extent.Text + ';$names'))
$rootFolder = Join-Path ([IO.Path]::GetTempPath()) ('CodexMsixUpdater-test-' + [Guid]::NewGuid().ToString('N'))
$selected = Join-Path $rootFolder 'OpenAI.Codex_2.0.0_x64__2p2nqsd0c76g0.msix'
$other = Join-Path $rootFolder 'OpenAI.Codex_1.9.0_x64__2p2nqsd0c76g0.msix'
$mockFunctions = @'
function Get-InstallFolder { return $TestRoot }
function Write-QueueMessage { param($Queue,$Kind,$Text,$Done,$Total); $Queue.Enqueue([pscustomobject]@{Kind=$Kind;Text=$Text;Done=$Done;Total=$Total}) }
function Get-Architecture { return 'x64' }
function Get-UserAgent { return 'CodexMsixUpdater-test' }
function Test-DeliveryHost { param([Uri]$Uri); return $Uri.Host.EndsWith('delivery.mp.microsoft.com') }
function Test-DownloadHost { param([Uri]$Uri); return $Uri.Scheme -eq 'https' }
function Get-OfficialStoreLinks { param($Ring,$Queue); return @() }
function Find-CodexPackage { param($Queue); return [pscustomobject]@{Version=[Version]'2.0.0';FileName='OpenAI.Codex_2.0.0_x64__2p2nqsd0c76g0.msix';Architecture='x64';Url='https://example.invalid/package'} }
function Get-InstalledCodex { if(-not $script:InstalledVersion){$script:InstalledVersion='1.0.0'}; return [pscustomobject]@{Version=$script:InstalledVersion;Publisher=$Config.publisher;PackageFamilyName=$Config.packageFamilyName} }
function Find-CachedCodexPackage { param([Version]$Version); return $SelectedPath }
function Read-CodexManifest { param([string]$Path); return [pscustomobject]@{Name='OpenAI.Codex';Architecture='x64';Publisher=$Config.publisher;Version=[Version]'2.0.0'} }
function Invoke-InstallPackage { param([string]$Path); $script:InstalledPath=$Path; $script:InstalledVersion='2.0.0' }
function Download-VerifiedFile { param([string]$Url,[string]$Path,$Queue); throw 'Network download is disabled in tests.' }
function Add-AppxPackage { param([string]$Path); }
function Get-AppxPackage { param([string]$Name); return @() }
function Get-Process { [CmdletBinding()] param([string]$Name); return @() }
'@
$Config = [pscustomobject]@{ packageName='OpenAI.Codex'; publisher='Test publisher'; packageFamilyName='OpenAI.Codex_2p2nqsd0c76g0' }
$TestRoot=$rootFolder;$SelectedPath=$selected
. ([ScriptBlock]::Create($mockFunctions))
. ([ScriptBlock]::Create($workerFunction[0].Extent.Text))
. ([ScriptBlock]::Create($converterFunction[0].Extent.Text))
$workerDefinitions=ConvertTo-WorkerDefinitions -Names $names
$workerDefinitions += 'function Get-Process { [CmdletBinding()] param([string]$Name); return @() }'
if($names -notcontains 'Get-UserAgent' -or $workerDefinitions.Count -ne ($names.Count+1)){throw 'UI worker function definitions are incomplete.'}
New-Item -ItemType Directory -Path $rootFolder | Out-Null
$ps = [PowerShell]::Create()
try {
    [void]$ps.AddScript(($workerDefinitions -join "`n") + "`n" + $mockFunctions)
    $ps.Runspace.SessionStateProxy.SetVariable('Config',$Config)
    $ps.Runspace.SessionStateProxy.SetVariable('TestRoot',$rootFolder)
    $ps.Runspace.SessionStateProxy.SetVariable('SelectedPath',$selected)
    $ps.Runspace.SessionStateProxy.SetVariable('LogPath',$null)
    $q = [Collections.Concurrent.ConcurrentQueue[object]]::new()
    [void]$ps.AddScript('$script:InstalledVersion="1.0.0";$script:InstalledPath=$null;Invoke-Worker $args[0] $false $true').AddArgument($q)
    [IO.File]::WriteAllText($selected,'selected');[IO.File]::WriteAllText($other,'other')
    [void]$ps.Invoke()
    if($ps.HadErrors){throw ('isolated worker error: '+($ps.Streams.Error -join '; '))}
    $messages=@();$item=$null;while($q.TryDequeue([ref]$item)){$messages+=$item}
    if($messages.Kind -contains 'error'){throw ('update worker failed: '+(($messages|Where-Object Kind -eq 'error').Text -join '; '))}
    if(Test-Path -LiteralPath $selected){throw 'selected package was not deleted'}
    if(-not (Test-Path -LiteralPath $other)){throw 'other package was deleted'}
    if(-not (($messages|Where-Object Kind -eq 'done').Text -match '已删除本次成功安装所用的安装包')){throw 'missing update success message'}

    $ps.Commands.Clear();$q=[Collections.Concurrent.ConcurrentQueue[object]]::new();$ps.Runspace.SessionStateProxy.SetVariable('LogPath',$null)
    [void]$ps.AddScript('$script:InstalledVersion="2.0.0";Invoke-Worker $args[0] $false $true').AddArgument($q)
    [IO.File]::WriteAllText($selected,'selected')
    [void]$ps.Invoke()
    if($ps.HadErrors){throw ('current-version worker error: '+($ps.Streams.Error -join '; '))}
    if(-not (Test-Path -LiteralPath $selected) -or -not (Test-Path -LiteralPath $other)){throw 'current-version branch modified a package'}

    $ps.Commands.Clear();$q=[Collections.Concurrent.ConcurrentQueue[object]]::new()
    [void]$ps.AddScript('$script:InstalledVersion="1.0.0";Invoke-Worker $args[0] $false $false').AddArgument($q)
    [void]$ps.Invoke()
    if($ps.HadErrors){throw ('keep-package worker error: '+($ps.Streams.Error -join '; '))}
    if(-not (Test-Path -LiteralPath $selected) -or -not (Test-Path -LiteralPath $other)){throw 'unchecked delete option modified a package'}
    Write-Output 'Windows PowerShell 5.1 GUI worker serialization passed; delete-one, current-version keep, and unchecked keep passed.'
}
finally {
    $ps.Dispose()
    if(Test-Path -LiteralPath $selected -PathType Leaf){[IO.File]::Delete($selected)}
    if(Test-Path -LiteralPath $other -PathType Leaf){[IO.File]::Delete($other)}
    if(Test-Path -LiteralPath $rootFolder -PathType Container){foreach($file in Get-ChildItem -LiteralPath $rootFolder -File -Filter 'Codex-failed-*.log' -ErrorAction SilentlyContinue){[IO.File]::Delete($file.FullName)};[IO.Directory]::Delete($rootFolder,$false)}
}
Write-Output 'Static checks passed.'
