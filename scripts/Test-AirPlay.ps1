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
    $script:airReceiptPatch = @{ source = 'shairportqt-windows-media' }
    foreach ($state in @('playing', 'paused')) {
        $script:airReceiverState = $state
        Assert-Equal (Get-GodBrainAirPlayLine) "$state :5000 (ShairportQt; Windows media session)"
    }
    $script:airReceiverState = 'listening'
    Assert-Equal (Get-GodBrainAirPlayLine) 'listening :5000 (ShairportQt; tray)'
    $script:airReceiverState = 'connected'
    Assert-Equal (Get-GodBrainAirPlayLine) 'connected :5000 (ShairportQt; playback state unavailable; tray)'
    $script:airReceiverState = 'ready'
    Assert-Throws { Get-GodBrainAirPlayReceiverState $fixture } '*Invalid AirPlay receiver state or process identity*'
    $script:airReceiptPatch = @{ state = 'listening' }
    Assert-Throws { Get-GodBrainAirPlayReceiverState $fixture } '*Invalid AirPlay receiver state or process identity*'
    $script:airReceiptPatch = @{}
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
Assert-Equal (Request-GodBrainAirPlayClose ([uint32]$PID)) $false
Write-Host 'PASS: AirPlay native limited-rights path/time handle, hidden CIM paths, exact identity/owner, ambiguity and fail-loud fixtures'

& {
    $script:stopCreated = [datetime]::UtcNow
    $script:stopProcess = [pscustomobject]@{ ProcessId = 7 }
    $script:stopHandle = [pscustomobject]@{ CreationTimeUtc = $script:stopCreated }
    $script:stopHandle | Add-Member ScriptMethod Dispose {}
    $script:stopHandle | Add-Member ScriptMethod WaitForExit {
        param($Milliseconds)
        if ($Milliseconds -eq 3000 -and $script:stopGracefulExit) { $script:stopExited = $true }
        return $script:stopExited
    }
    function Get-GodBrainAirPlayProcess { return $script:stopProcess }
    function Open-GodBrainAirPlayHandle { param($ProcessId); return $script:stopHandle }
    function Assert-GodBrainAirPlayProcess {
        param($Process, $Handle)
        if ($script:stopIdentityFails) { throw 'Fixture identity changed.' }
    }
    function Request-GodBrainAirPlayClose { param($ProcessId); return $script:stopCloseAccepted }
    function Test-Path {
        param($LiteralPath, $PathType)
        return $script:stopWsudoPresent -or $LiteralPath -ne 'C:\Tools\TeamM2\wsudo.exe'
    }
    function Reset-AirPlayStopFixture {
        $script:stopExited = $false
        $script:stopGracefulExit = $false
        $script:stopCloseAccepted = $true
        $script:stopIdentityFails = $false
        $script:stopWsudoPresent = $true
        $script:stopCalls = @()
        $script:stopCodes = @{ user = 5; '-A' = 5; '-T' = 0 }
        $script:stopExitAt = '-T'
        $script:stopChildTimeout = $false
    }
    function Invoke-GodBrainAirPlayChild {
        param($StartInfo, $TimeoutMilliseconds, $Label)
        Assert-Equal $TimeoutMilliseconds 12000
        Assert-Equal $Label 'AirPlay termination helper'
        $arguments = @($StartInfo.ArgumentList)
        $level = 'user'
        if ($StartInfo.FileName -eq 'C:\Tools\TeamM2\wsudo.exe') {
            $level = $arguments[0]
            Assert-Equal $arguments[1] '-w'
            if ($level -cnotin @('-A', '-T')) { throw 'Unexpected elevation.' }
            if ($arguments[2] -notlike '*\godbrain_core\cpp_tools\desk-airplay.exe') { throw 'Wrong elevated helper.' }
            $arguments = @($arguments | Select-Object -Skip 3)
        } elseif ($StartInfo.FileName -notlike '*\godbrain_core\cpp_tools\desk-airplay.exe') {
            throw 'Wrong user termination helper.'
        }
        Assert-Equal $arguments.Count 9
        Assert-Equal ($arguments[0..2] -join ',') '--terminate,--pid,7'
        Assert-Equal $arguments[3] '--created'
        Assert-Equal $arguments[4] ([string]$script:stopCreated.ToFileTimeUtc())
        Assert-Equal $arguments[5] '--owner'
        Assert-Equal $arguments[6] ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
        Assert-Equal $arguments[7] '--deadline'
        $remaining = [datetime]::FromFileTimeUtc([long]$arguments[8]) - [datetime]::UtcNow
        if ($remaining.TotalSeconds -le 0 -or $remaining.TotalSeconds -gt 10) { throw 'Unbounded stop request.' }
        $script:stopCalls += $level
        if ($script:stopChildTimeout) { throw 'AirPlay termination helper timed out.' }
        if ($level -eq $script:stopExitAt) { $script:stopExited = $true }
        return [pscustomobject]@{ ExitCode = $script:stopCodes[$level]; Output = ''; ErrorText = '' }
    }
    Reset-AirPlayStopFixture
    $script:stopGracefulExit = $true
    Assert-Equal (Invoke-GodBrainAirPlay Stop) 'stopped (user app)'
    Assert-Equal $script:stopCalls.Count 0
    foreach ($gracefulClose in @($true, $false)) {
        Reset-AirPlayStopFixture
        $script:stopCloseAccepted = $gracefulClose
        $script:stopCodes.user = 0
        $script:stopExitAt = 'user'
        Assert-Equal (Invoke-GodBrainAirPlay Stop) 'stopped (user app; forced via user)'
        Assert-Equal ($script:stopCalls -join ',') 'user'
    }
    Reset-AirPlayStopFixture
    $script:stopCodes['-A'] = 0
    $script:stopExitAt = '-A'
    Assert-Equal (Invoke-GodBrainAirPlay Stop) 'stopped (user app; forced via wsudo/Admin)'
    Assert-Equal ($script:stopCalls -join ',') 'user,-A'
    Reset-AirPlayStopFixture
    Assert-Equal (Invoke-GodBrainAirPlay Stop) 'stopped (user app; forced via wsudo/TI)'
    Assert-Equal ($script:stopCalls -join ',') 'user,-A,-T'
    foreach ($code in @(0, 1, 1223)) {
        Reset-AirPlayStopFixture
        $script:stopCodes.user = $code
        Assert-Throws { Invoke-GodBrainAirPlay Stop } '*has not exited*'
        Assert-Equal ($script:stopCalls -join ',') 'user'
    }
    Reset-AirPlayStopFixture
    $script:stopCodes['-A'] = 1223
    Assert-Throws { Invoke-GodBrainAirPlay Stop } '*at -A*'
    Assert-Equal ($script:stopCalls -join ',') 'user,-A'
    Reset-AirPlayStopFixture
    $script:stopCodes['-T'] = 5
    $script:stopExitAt = ''
    Assert-Throws { Invoke-GodBrainAirPlay Stop } '*at -T*'
    Assert-Equal ($script:stopCalls -join ',') 'user,-A,-T'
    Reset-AirPlayStopFixture
    $script:stopWsudoPresent = $false
    Assert-Throws { Invoke-GodBrainAirPlay Stop } '*needs*wsudo.exe*'
    Assert-Equal ($script:stopCalls -join ',') 'user'
    Reset-AirPlayStopFixture
    $script:stopChildTimeout = $true
    Assert-Throws { Invoke-GodBrainAirPlay Stop } '*timed out*'
    Assert-Equal ($script:stopCalls -join ',') 'user'
    Reset-AirPlayStopFixture
    $script:stopIdentityFails = $true
    Assert-Throws { Invoke-GodBrainAirPlay Stop } '*identity changed*'
    Assert-Equal $script:stopCalls.Count 0
    Write-Host 'PASS: graceful/tray/hung Stop, exact typed identity, access-denial-only user/Admin/TI ladder, cancellation/timeout and false-success rejection'
}

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
$ownerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$deadline = [string][datetime]::UtcNow.AddSeconds(10).ToFileTimeUtc()
$wrongTermination = & $probeExe --terminate --pid $PID --created $ownCreated --owner $ownerSid --deadline $deadline | ConvertFrom-Json
if ($LASTEXITCODE -eq 0 -or $wrongTermination.ok -or $wrongTermination.error -ne 'Unexpected receiver executable') {
    throw 'Native AirPlay termination accepted a different executable.'
}
$expired = & $probeExe --terminate --pid $PID --created $ownCreated --owner $ownerSid --deadline 1 | ConvertFrom-Json
if ($LASTEXITCODE -eq 0 -or $expired.ok -or $expired.error -notlike '*request expired*') {
    throw 'Native AirPlay termination accepted an expired request.'
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
        $stop = Invoke-GodBrainAirPlay 'Stop'
        if ($stop -notlike 'stopped (user app*') { throw "Invalid Stop result: $stop" }
        Assert-Equal (Get-GodBrainAirPlayProcess) $null
        $process = $null
        Write-Host 'PASS: AirPlay Start/Open/Stop, singleton, receiver listener and clean exit (audio not exercised)'
        $null = Invoke-GodBrainAirPlay 'Start'
        $process = Get-GodBrainAirPlayProcess
        $handle = Open-GodBrainAirPlayHandle $process.ProcessId
        try {
            $created = [string]$handle.CreationTimeUtc.ToFileTimeUtc()
            $deadline = [string][datetime]::UtcNow.AddSeconds(10).ToFileTimeUtc()
            foreach ($mismatch in @(
                @{ Created = [string]([long]$created + 1); Owner = $ownerSid; Error = '*identity changed*' },
                @{ Created = $created; Owner = 'S-1-0-0'; Error = '*owner does not match*' }
            )) {
                $rejected = & $probeExe --terminate --pid $process.ProcessId --created $mismatch.Created --owner $mismatch.Owner --deadline $deadline | ConvertFrom-Json
                if ($LASTEXITCODE -eq 0 -or $rejected.ok -or $rejected.error -notlike $mismatch.Error -or $handle.WaitForExit(0)) {
                    throw 'Mismatched termination identity was not rejected with the receiver left alive.'
                }
            }
            Assert-Equal (Stop-GodBrainAirPlayProcess $process $handle) 'stopped (user app; forced via user)'
            if (-not $handle.WaitForExit(0)) { throw 'Forced receiver is still alive.' }
        } finally { $handle.Dispose() }
        Assert-Equal (Get-GodBrainAirPlayProcess) $null
        $process = $null
        Write-Host 'PASS: live exact-receiver forced termination, creation/SID mismatch refusal, pinned-handle exit; no privileged fallback needed'
    } finally {
        if ($process) {
            $current = Get-GodBrainAirPlayProcess
            if ($current -and $current.ProcessId -eq $process.ProcessId) {
                $null = Invoke-GodBrainAirPlay 'Stop'
            }
        }
    }
}
