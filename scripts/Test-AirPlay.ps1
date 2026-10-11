[CmdletBinding()]
param([switch]$Live)

$ErrorActionPreference = 'Stop'
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
foreach ($file in 'GodBrain-AirPlay.ps1', 'Show-DeskMenu.ps1') {
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
    }
    $script:airFixture = @($fixture)
    Assert-Equal (Get-GodBrainAirPlayProcess).ProcessId 7
    Assert-Equal (Get-GodBrainAirPlayLine) 'running (no receiver listener)'
    $script:airPorts = @(@{ OwningProcess = 7; LocalPort = 5000 }, @{ OwningProcess = 99; LocalPort = 8000 })
    Assert-Equal (Get-GodBrainAirPlayLine) 'listening :5000 (audio unverified)'
    $script:airFixture = @($fixture, $fixture)
    Assert-Throws { Get-GodBrainAirPlayProcess } '*Multiple*'
    $script:airFixture = @($fixture)
    $fixture.ExecutablePath = 'C:\unrelated\ShairportQt.exe'
    Assert-Throws { Get-GodBrainAirPlayProcess } '*unverified*'
    $fixture.ExecutablePath = $null
    Assert-Throws { Get-GodBrainAirPlayProcess } '*unverified*'
    $fixture.ExecutablePath = Get-GodBrainAirPlayExe
    $script:airOwner = 'S-1-5-18'
    Assert-Throws { Get-GodBrainAirPlayProcess } '*ownership*'
    $script:airOwner = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $script:airOwnerResult = 2
    Assert-Throws { Get-GodBrainAirPlayProcess } '*ownership*'
    $fixture.SessionId++
    Assert-Equal (Get-GodBrainAirPlayProcess) $null
    $script:airQueriesFail = $true
    Assert-Equal (Get-GodBrainAirPlayLine) 'unread: Fixture process query denied'
}
Write-Host 'PASS: AirPlay exact path/session/owner, ambiguity, passive status and fail-loud fixtures'

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
            if ($line -like 'listening*') { break }
            Start-Sleep -Milliseconds 200
        } while ([datetime]::UtcNow -lt $deadline)
        if ($line -notlike 'listening*') { throw "AirPlay never opened its receiver listener: $line" }
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
