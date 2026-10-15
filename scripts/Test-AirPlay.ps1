[CmdletBinding()]
param([switch]$Live, [switch]$ReadOnlyLive)

$ErrorActionPreference = 'Stop'
if ($Live -and $ReadOnlyLive) { throw 'Choose either -Live lifecycle controls or -ReadOnlyLive passive inspection.' }
. (Join-Path $PSScriptRoot 'GodBrain-AirPlay.ps1')
function Assert-Equal($Actual, $Expected) {
    if ($Actual -cne $Expected) { throw "Expected '$Expected', got '$Actual'." }
}
function Assert-Throws([scriptblock]$Action, [string]$Expected) {
    try { & $Action } catch {
        if ($_.Exception.Message -notlike $Expected) { throw }
        return
    }
    throw "Expected failure: $Expected"
}
foreach ($file in 'GodBrain-AirPlay.ps1', 'Show-DeskMenu.ps1', 'Build-DeskAirPlay.ps1') {
    $tokens = $null; $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot $file), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors -join "`n") }
}
& {
    $script:airFixture = @()
    $script:airPorts = @()
    $script:airOwner = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $script:airOwnerResult = 0
    $script:airInstalled = $true
    $script:airQueriesFail = $false
    $script:airNativeFails = $false
    $script:airNativePath = Get-GodBrainAirPlayExe
    $script:airCreated = [datetime]::UtcNow
    $script:airNativeCreated = $script:airCreated
    $script:airReceiverState = 'ready'
    $script:airProbeFails = $false
    $script:airReceiptPatch = @{}
    function Open-GodBrainAirPlayHandle {
        param($ProcessId)
        if ($script:airNativeFails) { throw 'Fixture query-limited handle denied.' }
        $handle = [pscustomobject]@{
            ExecutablePath = $script:airNativePath
            CreationTimeUtc = $script:airNativeCreated
        }
        $handle | Add-Member ScriptMethod Dispose {}
        $handle | Add-Member ScriptMethod WaitForExit { param($Milliseconds); return $false }
        return $handle
    }
    function Invoke-GodBrainAirPlayProbe {
        param($StartInfo)
        if ($script:airProbeFails) { throw 'Fixture receiver provider is unavailable.' }
        Assert-Equal $StartInfo.ArgumentList[0] '--pid'
        Assert-Equal $StartInfo.ArgumentList[1] '7'
        Assert-Equal $StartInfo.ArgumentList[2] '--created'
        Assert-Equal $StartInfo.ArgumentList[3] ([string]$script:airNativeCreated.ToFileTimeUtc())
        $result = [ordered]@{
            schema_version = 1; ok = $true; pid = 7
            created = [string]$script:airNativeCreated.ToFileTimeUtc()
            source = 'shairportqt-uia'; state = $script:airReceiverState
            audio_output_verified = $false
        }
        foreach ($key in $script:airReceiptPatch.Keys) { $result[$key] = $script:airReceiptPatch[$key] }
        return [pscustomobject]$result
    }
    function Get-CimInstance {
        param($ClassName, $Filter, $OperationTimeoutSec, $ErrorAction)
        if ($script:airQueriesFail) { throw 'Fixture process query denied' }
        Assert-Equal $Filter "Name='ShairportQt.exe'"
        return $script:airFixture
    }
    function Invoke-CimMethod {
        param($InputObject, $MethodName, $OperationTimeoutSec, $ErrorAction)
        Assert-Equal $MethodName 'GetOwnerSid'
        return @{ ReturnValue = $script:airOwnerResult; Sid = $script:airOwner }
    }
    function Test-Path { param($LiteralPath, $PathType); return $script:airInstalled }
    function Get-NetTCPConnection { param($State, $ErrorAction); return $script:airPorts }
    Assert-Equal (Get-GodBrainAirPlayLine) 'stopped (user app)'
    Assert-Equal (Invoke-GodBrainAirPlay 'Stop') 'stopped (user app)'
    $script:airInstalled = $false
    Assert-Equal (Get-GodBrainAirPlayLine) 'not installed'
    Assert-Throws { Invoke-GodBrainAirPlay 'Start' } '*not installed*'
    $script:airInstalled = $true
    $fixture = [pscustomobject]@{
        ProcessId = 7; SessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
        ExecutablePath = Get-GodBrainAirPlayExe
        CreationDate = $script:airCreated
    }
    $script:airFixture = @($fixture)
    Assert-Equal (Get-GodBrainAirPlayProcess).ProcessId 7
    Assert-Equal (Get-GodBrainAirPlayLine) 'running (no receiver listener)'
    $script:airPorts = @(@{ OwningProcess = 7; LocalPort = 5000 }, @{ OwningProcess = 99; LocalPort = 8000 })
    foreach ($state in @('ready', 'playing', 'paused')) {
        $script:airReceiverState = $state
        Assert-Equal (Get-GodBrainAirPlayLine) "$state :5000 (ShairportQt)"
    }
    $script:airReceiverState = 'connected'
    Assert-Equal (Get-GodBrainAirPlayLine) 'connected :5000 (ShairportQt; playback state unavailable)'
    $script:airProbeFails = $true
    Assert-Equal (Get-GodBrainAirPlayLine) 'listening :5000 (receiver state unavailable: Fixture receiver provider is unavailable.)'
    $script:airProbeFails = $false
    foreach ($invalid in @(
        @{ pid = 99 }, @{ pid = '7' }, @{ created = '0' }, @{ created = 0 },
        @{ source = 'untrusted' }, @{ state = 'unknown' }, @{ state = 'PLAYING' },
        @{ audio_output_verified = $true }, @{ audio_output_verified = $null }
    )) {
        $script:airReceiptPatch = $invalid
        Assert-Throws { Get-GodBrainAirPlayReceiverState $fixture } '*Invalid AirPlay receiver state or process identity*'
    }
    $script:airReceiptPatch = @{}
    $script:airFixture = @($fixture, $fixture)
    Assert-Throws { Get-GodBrainAirPlayProcess } '*Multiple*'
    $script:airFixture = @($fixture)
    $fixture.ExecutablePath = 'C:\unrelated\ShairportQt.exe'
    Assert-Throws { Get-GodBrainAirPlayProcess } '*unverified*'
    $fixture.ExecutablePath = $null
    Assert-Equal (Get-GodBrainAirPlayProcess).ProcessId 7
    $script:airNativePath = 'C:\unrelated\ShairportQt.exe'
    Assert-Throws { Get-GodBrainAirPlayProcess } '*unverified*'
    $fixture.ExecutablePath = Get-GodBrainAirPlayExe
    Assert-Throws { Get-GodBrainAirPlayProcess } '*unverified*'
    $script:airNativePath = Get-GodBrainAirPlayExe
    $script:airNativeCreated = $script:airCreated.AddTicks(10)
    Assert-Throws { Get-GodBrainAirPlayProcess } '*identity changed*'
    $script:airNativeCreated = $script:airCreated
    $fixture.CreationDate = $null
    Assert-Throws { Get-GodBrainAirPlayProcess } '*creation time*'
    $fixture.CreationDate = $script:airCreated
    $script:airOwner = 'S-1-5-18'
    Assert-Throws { Get-GodBrainAirPlayProcess } '*ownership*'
    $script:airOwner = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $script:airOwnerResult = 2
    Assert-Throws { Get-GodBrainAirPlayProcess } '*ownership*'
    $fixture.SessionId++
    Assert-Equal (Get-GodBrainAirPlayProcess) $null
    $fixture.SessionId--
    $script:airNativeFails = $true
    Assert-Equal (Get-GodBrainAirPlayLine) 'unread: Fixture query-limited handle denied.'
    $script:airNativeFails = $false
    $script:airQueriesFail = $true
    Assert-Equal (Get-GodBrainAirPlayLine) 'unread: Fixture process query denied'
}
$native = Open-GodBrainAirPlayHandle ([uint32]$PID)
try {
    Assert-Equal $native.ExecutablePath ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    $created = [Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks
    Assert-Equal $native.CreationTimeUtc.Ticks $created
    Assert-Equal ($native.WaitForExit(0)) $false
    Assert-Throws { $native.WaitForExit(-1) } '*milliseconds*'
} finally { $native.Dispose() }
Write-Host 'PASS: AirPlay native limited-rights path/time handle, hidden CIM paths, exact identity/owner, ambiguity and fail-loud fixtures'

function New-AirPlayProbeFixture([string]$Command) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = Join-Path $PSHOME 'pwsh.exe'
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $Command)) {
        $info.ArgumentList.Add($argument)
    }
    return $info
}
Assert-Equal (Invoke-GodBrainAirPlayProbe (New-AirPlayProbeFixture @'
[Console]::Out.WriteLine('{"schema_version":1,"ok":true}')
'@)).ok $true
foreach ($output in @(
    '{"schema_version":1,"ok":"true"}', '{"schema_version":2,"ok":true}',
    '[{"schema_version":1,"ok":true}]', '{"schema_version":1}', 'not-json',
    '{"schema_version":1,"ok":true} {"ok":true}',
    '{"schema_version":1,"ok":false,"error":""}',
    '{"schema_version":1,"ok":false,"error":"line\ninjection"}'
)) {
    $quoted = $output.Replace("'", "''")
    Assert-Throws { Invoke-GodBrainAirPlayProbe (New-AirPlayProbeFixture "[Console]::Out.WriteLine('$quoted')") } '*'
}
Assert-Throws { Invoke-GodBrainAirPlayProbe (New-AirPlayProbeFixture @'
[Console]::Out.WriteLine('{"schema_version":1,"ok":false,"error":"Fixture UIA refused access"}')
exit 1
'@) } '*Fixture UIA refused access*'
Assert-Throws { Invoke-GodBrainAirPlayProbe (New-AirPlayProbeFixture @'
[Console]::Out.WriteLine('{"schema_version":1,"ok":true}')
exit 7
'@) } '*exited unsuccessfully*'
Assert-Throws { Invoke-GodBrainAirPlayProbe (New-AirPlayProbeFixture @'
[Console]::Error.WriteLine('Fixture unexpected stderr')
[Console]::Out.WriteLine('{"schema_version":1,"ok":true}')
'@) } '*Invalid AirPlay state probe output*'
$pidFile = Join-Path ([IO.Path]::GetTempPath()) ("GodBrain-AirPlayProbe-" + [guid]::NewGuid().ToString('N') + '.txt')
try {
    $quoted = $pidFile.Replace("'", "''")
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Assert-Throws {
        Invoke-GodBrainAirPlayProbe (New-AirPlayProbeFixture "[IO.File]::WriteAllText('$quoted', [string]`$PID); Start-Sleep -Seconds 30") -TimeoutMilliseconds 2500
    } '*probe timed out*'
    if ($watch.ElapsedMilliseconds -gt 5500) { throw 'AirPlay state probe timeout was not bounded.' }
    if (-not (Test-Path -LiteralPath $pidFile)) { throw 'Timeout fixture never started.' }
    $childPid = [int][IO.File]::ReadAllText($pidFile)
    try { $remaining = [Diagnostics.Process]::GetProcessById($childPid) }
    catch [ArgumentException] { $remaining = $null }
    if ($remaining) {
        try { if (-not $remaining.HasExited) { throw 'Timed-out probe is still running.' } }
        finally { $remaining.Dispose() }
    }
} finally {
    if (Test-Path -LiteralPath $pidFile) { Remove-Item -LiteralPath $pidFile }
}
$probeExe = Join-Path (Split-Path $PSScriptRoot -Parent) 'godbrain_core\cpp_tools\desk-airplay.exe'
if (-not (Test-Path -LiteralPath $probeExe -PathType Leaf)) {
    throw 'Build the native fixture first with scripts\Build-DeskAirPlay.ps1.'
}
$selfTest = & $probeExe --self-test | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $selfTest.ok -or $selfTest.self_test -ne 'pass') {
    throw 'Native AirPlay state fixtures failed.'
}
$ownCreated = [string][Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToFileTimeUtc()
$wrongProcess = & $probeExe --pid $PID --created $ownCreated | ConvertFrom-Json
if ($LASTEXITCODE -eq 0 -or $wrongProcess.ok -or $wrongProcess.error -ne 'Unexpected receiver executable') {
    throw 'Native AirPlay probe accepted a different executable.'
}
Write-Host 'PASS: receiver ready/connected/playing/paused, receipt identity, malformed/error/exit envelopes, bounded timeout and exact probe cleanup'

if ($ReadOnlyLive) {
    $before = Get-GodBrainAirPlayProcess
    if (-not $before) { throw 'Passive inspection needs an already-running receiver; none was started.' }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $state = Get-GodBrainAirPlayReceiverState $before
    $line = Get-GodBrainAirPlayLine
    $after = Get-GodBrainAirPlayProcess
    if (-not $after -or $after.ProcessId -ne $before.ProcessId -or $after.CreationDate -ne $before.CreationDate) {
        throw 'Receiver identity changed during passive inspection.'
    }
    if ($line -notlike "$state :*") { throw "Passive status disagrees with receiver: $line" }
    Write-Host "PASS: passive receiver state=$state, unchanged process, $($watch.ElapsedMilliseconds) ms; no window/playback controls invoked"
}

if ($Live) {
    if (Get-GodBrainAirPlayProcess) { throw 'Live lifecycle check requires AirPlay initially stopped; existing playback is left alone.' }
    $process = $null
    try {
        $line = Invoke-GodBrainAirPlay 'Start'
        $process = Get-GodBrainAirPlayProcess
        if (-not $process) { throw 'AirPlay Start did not persist.' }
        $startedPid = $process.ProcessId
        $null = Invoke-GodBrainAirPlay 'Start'
        Assert-Equal (Get-GodBrainAirPlayProcess).ProcessId $startedPid
        $null = Invoke-GodBrainAirPlay 'Open'
        Assert-Equal (Get-GodBrainAirPlayProcess).ProcessId $startedPid
        $deadline = [datetime]::UtcNow.AddSeconds(10)
        do {
            $line = Get-GodBrainAirPlayLine
            if ($line -match '^(ready|connected|playing|paused|listening) :') { break }
            Start-Sleep -Milliseconds 200
        } while ([datetime]::UtcNow -lt $deadline)
        if ($line -notmatch '^(ready|connected|playing|paused|listening) :') { throw "AirPlay never opened its receiver listener: $line" }
        Write-Host "PASS: Installed receiver reused PID $startedPid; $line"
        Assert-Equal (Invoke-GodBrainAirPlay 'Stop') 'stopped (user app)'
        Assert-Equal (Get-GodBrainAirPlayProcess) $null
        $process = $null
        Write-Host 'PASS: AirPlay Start/Open/Stop, singleton, receiver listener and clean exit (audio not exercised)'
    } finally {
        if ($process) {
            $current = Get-GodBrainAirPlayProcess
            if ($current -and $current.ProcessId -eq $process.ProcessId) {
                $null = Invoke-GodBrainAirPlay 'Stop'
            }
        }
    }
}
