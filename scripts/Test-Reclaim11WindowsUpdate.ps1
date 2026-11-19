# Offline execution fixtures only. Never runs a real wipe, registry write or task operation.
[CmdletBinding()]
param([string]$RepoRoot = "")
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$ps1 = Join-Path $RepoRoot "godbrain_core\reclaim11\ps1"
$reaper = Join-Path $ps1 "grim_reaper.ps1"
$temp = Join-Path ([IO.Path]::GetTempPath()) ("reclaim11-wu-test-" + [guid]::NewGuid().ToString("N"))
[void][IO.Directory]::CreateDirectory($temp)
$oldRoot = $env:SystemRoot
$oldDrive = $env:SystemDrive
$oldTi = $env:RECLAIM11_AS_TI
$oldTemp = $env:TEMP
$testPwsh = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$global:WuFixtureEvents = [Collections.Generic.List[object]]::new()
$global:WuFixturePolicy = @{}
$global:WuFixtureIgnoreWrite = $false
$global:WuFixtureFailBackup = $false
$global:WuFixtureBlocked = ""
$global:WuFixtureWorkersGone = $false

class Reclaim11WuFixtureKey {
    [hashtable]$Values
    Reclaim11WuFixtureKey([hashtable]$values) { $this.Values = $values }
    [string[]] GetValueNames() { return [string[]]@($this.Values.Keys) }
    [Microsoft.Win32.RegistryValueKind] GetValueKind([string]$name) { return $this.Values[$name].kind }
    [object] GetValue([string]$name) { return $this.Values[$name].value }
    [object] GetValue([string]$name, [object]$fallback, [Microsoft.Win32.RegistryValueOptions]$options) {
        if ($options -ne [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) { throw "Expanded backup" }
        return $this.Values[$name].value
    }
    [void] Close() { }
}
function Assert-Wu([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Add-WuEvent([string]$Kind, [string]$Target) {
    $global:WuFixtureEvents.Add([pscustomobject]@{ kind = $Kind; target = $Target })
}
function Test-Path {
    param([string]$LiteralPath, [string]$Path)
    $p = if ($LiteralPath) { $LiteralPath } else { $Path }
    if ($p -like "$temp*") { return Microsoft.PowerShell.Management\Test-Path -LiteralPath $p }
    if ($p -like "$ps1*") { return Microsoft.PowerShell.Management\Test-Path -LiteralPath $p }
    if ($p -like "HKLM:*") {
        if ($p -like "*Image File Execution Options*") {
            return $global:WuFixtureBlocked -eq "ifeo" -or
                ($global:WuFixtureBlocked -eq "worker-ifeo" -and $p -like "*usoclient.exe")
        }
        return $true
    }
    if ($p -like "C:\Windows\System32\*.exe" -or $p -like "C:\Windows\SysWOW64\*.exe" -or $p -like "C:\Windows\System32\drivers\*.sys") { return $true }
    return $false
}
function Get-Item {
    param([string]$LiteralPath)
    if ($LiteralPath -like "*Image File Execution Options*") {
        return [Reclaim11WuFixtureKey]::new(@{ Debugger = @{ kind = "String"; value = "synthetic-stub.exe" } })
    }
    if ($LiteralPath -like "*WindowsUpdate\AU") { return [Reclaim11WuFixtureKey]::new($global:WuFixturePolicy) }
    throw "Unexpected fixture Get-Item $LiteralPath"
}
function Get-ItemProperty {
    param([string]$LiteralPath, [string]$Path, [string]$Name)
    if ($LiteralPath -like "*SecureBoot*") { return [pscustomobject]@{ UEFISecureBootEnabled = 0 } }
    if ($LiteralPath -like "*Policies\Explorer") {
        if ($global:WuFixtureBlocked -eq "hide") { return [pscustomobject]@{ SettingsPageVisibility = "hide:windowsupdate" } }
        return [pscustomobject]@{ SettingsPageVisibility = "hide:gaming-gamebar" }
    }
    if ($LiteralPath -like "*Policies*WindowsUpdate") {
        if ($global:WuFixtureBlocked -eq "ux") { return [pscustomobject]@{ SetDisableUXWUAccess = 1 } }
        if ($global:WuFixtureBlocked -eq "deadline") { return [pscustomobject]@{ ConfigureDeadlineForQualityUpdates = 0 } }
        return [pscustomobject]@{}
    }
    if ($Name) { return [pscustomobject]@{ $Name = @() } }
    return $null
}
function Get-Service {
    param([string]$Name)
    if ($Name -in @("UsoSvc", "WaaSMedicSvc")) { throw "Worker removal must not require service availability: $Name" }
    if ($global:WuFixtureBlocked -eq "service") { throw "Fixture service missing: $Name" }
    if ($global:WuFixtureBlocked -eq "disabled") { return [pscustomobject]@{ Name = $Name; StartType = "Disabled" } }
    return [pscustomobject]@{ Name = $Name; StartType = "Manual" }
}
function New-Item {
    param([string]$Path, [string]$ItemType, [switch]$Force)
    if ($Path -like "HKLM:*") { Add-WuEvent "registry-create" $Path; return }
    if ($Path -notlike "$temp*") { throw "Forbidden fixture directory $Path" }
    if ($global:WuFixtureFailBackup) { throw "Fixture backup failure" }
    Microsoft.PowerShell.Management\New-Item @PSBoundParameters
}
function New-ItemProperty {
    param([string]$Path, [string]$Name, $Value, [string]$PropertyType, [switch]$Force)
    Add-WuEvent "registry-write" "$Path : $Name"
    if ($Name -eq "NoAutoUpdate") {
        Assert-Wu (@(Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $temp -Filter windows-update-policy.json -Recurse).Count -gt 0) "Policy write without backup"
        if (-not $global:WuFixtureIgnoreWrite) { $global:WuFixturePolicy.NoAutoUpdate = @{ kind = "DWord"; value = $Value } }
    }
}
function Remove-Item {
    param([string[]]$LiteralPath, [switch]$Recurse, [switch]$Force)
    foreach ($p in $LiteralPath) {
        if ($p -like "$temp*") { Microsoft.PowerShell.Management\Remove-Item -LiteralPath $p -Recurse:$Recurse -Force:$Force }
        else { Add-WuEvent "remove" $p }
    }
}
function Remove-ItemProperty { param([string]$LiteralPath, [string]$Name) Add-WuEvent "registry-remove-value" "$LiteralPath : $Name" }
function Set-ItemProperty { param([string]$LiteralPath, [string]$Path, [string]$Name, $Value, $Type) Add-WuEvent "registry-write" "$LiteralPath$Path : $Name" }
function Copy-Item { param([string]$LiteralPath, [string]$Destination, [switch]$Force) Add-WuEvent "stub" $Destination }
function Get-ChildItem { param([string]$LiteralPath, [string]$Path, [switch]$Recurse, [switch]$File, [switch]$Force) return @() }
function Get-Process { param([string]$Name) Add-WuEvent "process-stop" $Name; return @() }
function Stop-Process {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)]$InputObject, [switch]$Force)
    process { throw "Fixture must not stop an actual process" }
}
function Start-Transcript { param([string]$Path, [switch]$Force) }
function Stop-Transcript { }
function sc.exe {
    Add-WuEvent "service" ($args -join " ")
    if ($args[0] -eq "query") {
        if ($global:WuFixtureWorkersGone -and $args[1] -in @("UsoSvc", "WaaSMedicSvc")) { "FAILED 1060" }
        else { "RUNNING" }
    }
}
function schtasks.exe { Add-WuEvent "task" ($args -join " ") }
function takeown.exe { Add-WuEvent "acl" ($args -join " ") }
function icacls.exe { Add-WuEvent "acl" ($args -join " ") }
function Get-ScheduledTask {
    foreach ($path in @("\Microsoft\Windows\Windows Defender\", "\Microsoft\Windows\WindowsUpdate\", "\Microsoft\Windows\WaaSMedic\", "\Microsoft\Windows\UpdateOrchestrator\", "\Unrelated\")) {
        [pscustomobject]@{ TaskPath = $path; TaskName = "Fixture" }
    }
}
function Import-WuFunction([string]$Path, [string]$Name) {
    $tokens = $null; $errors = $null
    $source = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $ast = [Management.Automation.Language.Parser]::ParseInput($source, $Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ("Source parse errors in ${Path}: " + ($errors.Message -join "; ")) }
    $function = $ast.Find({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $Name }.GetNewClosure(), $true)
    Assert-Wu ($null -ne $function) "Missing $Name"
    Set-Item -Path "Function:script:$Name" -Value $function.Body.GetScriptBlock()
}
try {
    $env:SystemRoot = Join-Path $temp "Windows"
    $env:SystemDrive = $temp
    $env:RECLAIM11_AS_TI = "1"
    $env:TEMP = $temp
    [void][IO.Directory]::CreateDirectory($env:SystemRoot)
    [IO.File]::WriteAllBytes((Join-Path $env:SystemRoot "reclaim11-stub.exe"), [byte[]]@(0x4d, 0x5a))
    [IO.File]::WriteAllText((Join-Path $env:SystemRoot "reclaim11-winpe.log"), '{"id":"reclaim11-winpe-fixture"}')
    foreach ($remove in @($false, $true)) {
        $global:WuFixtureEvents.Clear()
        $global:WuFixturePolicy = @{ NoAutoUpdate = @{ kind = "ExpandString"; value = "%SYNTHETIC%" } }
        $output = & $reaper -RemoveWindowsUpdate:$remove 6>&1 | Out-String
        $wu = @($global:WuFixtureEvents | Where-Object {
            $_.target -match '(?i)wuauserv|wuauclt|WindowsUpdate' -and
            $_.target -notlike "*Policies\Microsoft\Windows\WindowsUpdate\AU : NoAutoUpdate"
        })
        if ($remove) {
            foreach ($kind in @("stub", "service", "task", "remove", "process-stop", "registry-write")) {
                Assert-Wu (@($wu | Where-Object kind -eq $kind).Count -gt 0) "Explicit removal lost $kind"
            }
            Assert-Wu (@($global:WuFixtureEvents | Where-Object target -like "*NoAutoUpdate").Count -eq 0) "Removal wrote preservation policy"
        } else {
            Assert-Wu ($wu.Count -eq 0) ("Default leaked destructive core WU operations: " + ($wu | ConvertTo-Json -Compress))
            Assert-Wu ($global:WuFixturePolicy.NoAutoUpdate.value -eq 1 -and $global:WuFixturePolicy.NoAutoUpdate.kind -eq "DWord") "Policy not verified"
            $backups = @(Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $temp -Filter windows-update-policy.json -Recurse)
            $before = (Get-Content -LiteralPath $backups[0].FullName -Raw | ConvertFrom-Json).before
            Assert-Wu ($before.kind -eq "ExpandString" -and $before.value -ceq "%SYNTHETIC%") "Backup expanded or lost original type/value"
        }
        foreach ($service in @("UsoSvc", "WaaSMedicSvc")) {
            Assert-Wu (@($global:WuFixtureEvents | Where-Object { $_.kind -eq "service" -and $_.target -ceq "delete $service" }).Count -eq 1) "Profile lost worker service deletion: $service"
            $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$service"
            Assert-Wu (@($global:WuFixtureEvents | Where-Object { $_.kind -eq "remove" -and $_.target -ceq $key }).Count -eq 1) "Profile lost worker service-key removal: $service"
        }
        foreach ($exe in @("UsoCoreWorker.exe", "MoUsoCoreWorker.exe", "usoclient.exe", "WaaSMedicAgent.exe")) {
            $path = "C:\Windows\System32\$exe"
            Assert-Wu (@($global:WuFixtureEvents | Where-Object { $_.kind -eq "stub" -and $_.target -ceq $path }).Count -eq 1) "Profile lost worker stub: $exe"
        }
        foreach ($exe in @("WaaSMedicAgent.exe", "usoclient.exe", "UsoCoreWorker.exe", "MoUsoCoreWorker.exe", "musnotification.exe", "musnotificationux.exe", "UpdateNotificationMgr.exe")) {
            $key = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$exe : Debugger"
            Assert-Wu (@($global:WuFixtureEvents | Where-Object { $_.kind -eq "registry-write" -and $_.target -ceq $key }).Count -eq 1) "Profile lost worker IFEO: $exe"
        }
        foreach ($folder in @("WaaSMedic", "UpdateOrchestrator")) {
            $task = "/Delete /TN \Microsoft\Windows\$folder\Fixture /F"
            Assert-Wu (@($global:WuFixtureEvents | Where-Object { $_.kind -eq "task" -and $_.target -ceq $task }).Count -eq 1) "Profile lost worker task deletion: $folder"
        }
        foreach ($name in @("UsoCoreWorker", "MoUsoCoreWorker", "usoclient", "WaaSMedicAgent", "MusNotification", "MusNotificationUx")) {
            Assert-Wu (@($global:WuFixtureEvents | Where-Object { $_.kind -eq "process-stop" -and $_.target -ceq $name }).Count -eq 1) "Profile lost worker process selection: $name"
        }
        Assert-Wu (@($global:WuFixtureEvents | Where-Object target -like "*WinDefend").Count -gt 0) "Defender selection changed"
        Assert-Wu (@($global:WuFixtureEvents | Where-Object target -like "*Unrelated*").Count -eq 0) "Deleted unrelated task"
        Write-Output "PASS: full mocked core WU profile removal=$remove; exact USO/Medic operations in both modes"
    }
    foreach ($blocked in @("service", "disabled", "ifeo", "ux", "hide", "deadline", "backup", "readback")) {
        $global:WuFixtureEvents.Clear()
        $global:WuFixtureBlocked = $blocked
        $global:WuFixtureFailBackup = $blocked -eq "backup"
        $global:WuFixtureIgnoreWrite = $blocked -eq "readback"
        $global:WuFixturePolicy = @{ NoAutoUpdate = @{ kind = "DWord"; value = 0 } }
        $failed = $false
        try { & $reaper 6>&1 | Out-Null } catch { $failed = $true }
        Assert-Wu $failed "Failed condition reported success: $blocked"
        Assert-Wu (@($global:WuFixtureEvents | Where-Object { $_.kind -in @("service", "stub", "remove", "task", "process-stop") }).Count -eq 0) "Wipe continued after $blocked"
        if ($blocked -ne "readback") {
            Assert-Wu ($global:WuFixturePolicy.NoAutoUpdate.value -eq 0) "Policy changed after $blocked"
        }
        Write-Output "PASS: fail before wipe, $blocked"
    }
    $global:WuFixtureBlocked = ""; $global:WuFixtureFailBackup = $false; $global:WuFixtureIgnoreWrite = $false
    $global:WuFixtureWorkersGone = $true
    $global:WuFixtureBlocked = "worker-ifeo"
    $global:WuFixturePolicy = @{ NoAutoUpdate = @{ kind = "DWord"; value = 0 } }
    $global:WuFixtureEvents.Clear()
    & $reaper 6>&1 | Out-Null
    Assert-Wu ($global:WuFixturePolicy.NoAutoUpdate.value -eq 1) "Missing or already-blocked workers refused core WU mode"
    foreach ($service in @("UsoSvc", "WaaSMedicSvc")) {
        Assert-Wu (@($global:WuFixtureEvents | Where-Object { $_.kind -eq "service" -and $_.target -ceq "delete $service" }).Count -eq 0) "Already-gone worker service was deleted again"
    }
    Assert-Wu (@($global:WuFixtureEvents | Where-Object { $_.kind -eq "stub" -and $_.target -like "*usoclient.exe" }).Count -eq 1) "Existing worker IFEO prevented cleanup"
    $global:WuFixtureWorkersGone = $false
    $global:WuFixtureBlocked = ""
    Write-Output "PASS: missing USO/Medic and existing worker IFEO allowed without repair"
    $global:WuFixturePolicy = @{}
    & $reaper 6>&1 | Out-Null
    $before = @(Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $temp -Filter windows-update-policy.json -Recurse |
        ForEach-Object { (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).before } |
        Where-Object { -not $_.present })
    Assert-Wu ($before.Count -eq 1) "Originally absent policy was not preserved"
    $global:WuFixtureEvents.Clear()
    foreach ($remove in @($false, $true)) {
        $output = & $reaper -WhatIf -RemoveWindowsUpdate:$remove 6>&1 | Out-String
        Assert-Wu ($output.Contains("would sc delete wuauserv") -eq $remove) "TEST/RUN profiles differ"
        foreach ($service in @("UsoSvc", "WaaSMedicSvc")) {
            Assert-Wu ($output.Contains("would sc delete $service")) "TEST dropped worker removal: $service"
        }
    }
    Assert-Wu ($global:WuFixtureEvents.Count -eq 0) "WhatIf mutated"
    Write-Output "PASS: absent policy backup and read-only TEST profiles"

    . (Join-Path $ps1 "elevate.ps1")
    $env:SystemRoot = $oldRoot
    $env:SystemDrive = $oldDrive
    $global:WuFixturePayloadCapture = @()
    function Get-Reclaim11Pwsh { return $testPwsh }
    function Test-Reclaim11WinPeSession { return $false }
    function Test-Reclaim11TrustedInstaller { return $false }
    function Test-Reclaim11Admin { return $true }
    function Test-Reclaim11IsSystem { return $false }
    function Wait-Reclaim11DoneFile { param([string]$Path, [int]$TimeoutSec) }
    function Unregister-Reclaim11Task { param([string]$Name) }
    function Invoke-Reclaim11SpawnTi {
        param($PayloadFile, $LogFile, $DoneFile, $TimeoutSec, [string[]]$PayloadArguments)
        $global:WuFixturePayloadCapture = @($PayloadArguments)
        Set-Content -LiteralPath $DoneFile -Value "0"
    }
    function Register-Reclaim11SystemTask {
        param($Name, $Exe, $Arguments)
        $path = [regex]::Match($Arguments, '-File "(.+)"$').Groups[1].Value
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        Assert-Wu ($errors.Count -eq 0) "Generated SYSTEM runner parse failure"
        & ([scriptblock]::Create($ast.EndBlock.Statements[-1].Extent.Text))
    }
    $env:RECLAIM11_AS_TI = ""
    foreach ($arguments in @(@(), @("-RemoveWindowsUpdate", "space and 'quote", '$(throw "injected")'))) {
        $result = Invoke-Reclaim11AsTrustedInstaller -File $reaper -PayloadArguments $arguments
        Assert-Wu ($result.exit_code -eq 0) "Relay failed"
        Assert-Wu (($global:WuFixturePayloadCapture | ConvertTo-Json -Compress) -ceq ($arguments | ConvertTo-Json -Compress)) "SYSTEM relay lost or evaluated arguments"
    }
    Write-Output "PASS: Admin/SYSTEM argument relay"

    $payload = Join-Path $temp "quoted ' payload.ps1"
    [IO.File]::WriteAllText($payload, 'param([switch]$RemoveWindowsUpdate,[Parameter(ValueFromRemainingArguments=$true)][string[]]$Values) @{remove=[bool]$RemoveWindowsUpdate;values=@($Values)}|ConvertTo-Json -Compress')
    $log = Join-Path $temp "payload.out"; $done = Join-Path $temp "payload.done"
    $arguments = @("-RemoveWindowsUpdate", "space and 'quote", 'literal "quote"', "ends\", '$(throw "injected")')
    $runner = New-Reclaim11TiRunnerScript -PayloadFile $payload -LogFile $log -DoneFile $done -PayloadArguments $arguments
    & $testPwsh -NoLogo -NoProfile -File $runner
    Assert-Wu ($LASTEXITCODE -eq 0 -and (Get-Content -LiteralPath $done).Trim() -eq "0") "Harmless native payload failed"
    $result = Get-Content -LiteralPath $log -Raw | ConvertFrom-Json
    Assert-Wu ($result.remove -eq $true) "TI payload lost removal switch"
    Assert-Wu (($result.values | ConvertTo-Json -Compress) -ceq ($arguments[1..4] | ConvertTo-Json -Compress)) "TI process quoting corrupted arguments"
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $runner
    Write-Output "PASS: real harmless TI-runner subprocess, spaces/quotes/backslashes/injection literals"

    Add-Type -AssemblyName PresentationFramework
    [xml]$xaml = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "godbrain_core\reclaim11\ui\MainWindow.xaml")
    $window = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xaml))
    $togKeepWindowsUpdate = $window.FindName("TogKeepWindowsUpdate")
    Import-WuFunction (Join-Path $ps1 "Reclaim11.ps1") "Get-Reclaim11RemoveWindowsUpdate"
    Import-WuFunction (Join-Path $ps1 "Reclaim11.ps1") "Invoke-Reclaim11GrimReaperCli"
    $ps1Dir = $ps1
    Assert-Wu (-not (Get-Reclaim11RemoveWindowsUpdate)) "GUI default is destructive"
    $output = Invoke-Reclaim11GrimReaperCli -WhatIf -RemoveWindowsUpdate:(Get-Reclaim11RemoveWindowsUpdate)
    Assert-Wu ($output.Contains("would KEEP core WU services") -and -not $output.Contains("would sc delete wuauserv") -and
        $output.Contains("would sc delete UsoSvc") -and $output.Contains("would sc delete WaaSMedicSvc")) "GUI TEST lost core-preserved/worker-removal mode"
    $togKeepWindowsUpdate.IsChecked = $false
    Assert-Wu (Get-Reclaim11RemoveWindowsUpdate) "GUI opt-in lost"
    $output = Invoke-Reclaim11GrimReaperCli -WhatIf -RemoveWindowsUpdate:(Get-Reclaim11RemoveWindowsUpdate)
    Assert-Wu ($output.Contains("would sc delete wuauserv") -and $output.Contains("would sc delete UsoSvc") -and
        $output.Contains("would sc delete WaaSMedicSvc")) "GUI TEST lost explicit removal"
    $togKeepWindowsUpdate = $null
    $failed = $false
    try { Get-Reclaim11RemoveWindowsUpdate | Out-Null } catch { $failed = $true }
    Assert-Wu $failed "Missing GUI option selected destructive default"
    $window.Close()
    Write-Output "PASS: actual WPF option, native TEST dispatch and missing-option refusal"
} finally {
    $env:SystemRoot = $oldRoot; $env:SystemDrive = $oldDrive; $env:RECLAIM11_AS_TI = $oldTi; $env:TEMP = $oldTemp
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $temp -Recurse -Force
    Remove-Variable -Scope Global -Name WuFixtureEvents,WuFixturePolicy,WuFixtureIgnoreWrite,WuFixtureFailBackup,WuFixtureBlocked,WuFixtureWorkersGone,WuFixturePayloadCapture -ErrorAction SilentlyContinue
}
