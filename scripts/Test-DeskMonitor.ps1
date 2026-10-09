[CmdletBinding()]
param([switch]$LiveMonitor)

$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot "GodBrain-DeskMonitor.ps1")
$exe = Join-Path $repo "godbrain_core\cpp_tools\desk-monitor.exe"
if (-not (Test-Path -LiteralPath $exe)) { throw "Run scripts\Build-DeskMonitor.ps1 first." }
$self = (& $exe --self-test) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $self.self_test -ne "passed") { throw "Native monitor checks failed." }
foreach ($args in @(
    @("--set", "brightness", "101"), @("--set", "contrast", "-1"),
    @("--set", "dark_stabilizer", "4"), @("--set", "dark_stabilizer", "65535"),
    @("--set", "preset", "hdr"), @("--set", "input", "1"),
    @("--set", "brightness", "10.5"), @("--set", "brightness", "10;exit"),
    @("--cycle-dark", "0"), @("--cycle-dark", "3"), @("--cycle-dark", "--read"),
    @("--set", "dark_stabilizer_cycle", "0")
)) {
    $reply = (& $exe @args) | ConvertFrom-Json
    if ($LASTEXITCODE -eq 0 -or $reply.ok -ne $false -or $reply.may_have_changed -ne $false -or -not $reply.error) {
        throw "Invalid native request was not rejected before monitor access: $($args -join ' ')"
    }
}
try {
    Invoke-DeskMonitor -Control brightness -Value "101" | Out-Null
    throw "Wrapper accepted an invalid brightness."
} catch {
    if ($_.Exception.Message -notlike "*outside the allowed range*") { throw }
}
foreach ($value in @("0", "3", "--read")) {
    try {
        Invoke-DeskMonitor -Control dark_stabilizer_cycle -Value $value | Out-Null
        throw "Wrapper accepted a cycle level."
    } catch {
        if ($_.Exception.Message -notlike "*takes no level or value*") { throw }
    }
}
$fixture = @'
{"schema_version":1,"ok":true,"model":"Dell S2522HG","display":"fixture",
"brightness":{"supported":true,"current":75,"maximum":100},
"contrast":{"supported":true,"current":75,"maximum":100},
"preset":{"supported":true,"current":30,"maximum":255,"id":"game2"},
"dark_stabilizer":{"supported":false,"error":"No absolute level readback"},
"dark_stabilizer_cycle":{"supported":true,"readback_available":false,"current":null},
"presets":[{"id":"game2","name":"Game 2"}],
"action":{"control":"dark_stabilizer_cycle","command_accepted":true,"state_verified":false,
"current":null,"vcp_code":227,"value":16,"write_count":1}}
'@
Assert-DeskMonitorResult ($fixture | ConvertFrom-Json) "dark_stabilizer_cycle" | Out-Null
foreach ($mutate in @(
    { param($r) $r.action.state_verified = $true },
    { param($r) $r.action.state_verified = "false" },
    { param($r) $r.action.command_accepted = $false },
    { param($r) $r.action.current = 0 },
    { param($r) $r.action.PSObject.Properties.Remove("current") },
    { param($r) $r.action.vcp_code = 244 },
    { param($r) $r.action.value = 48 },
    { param($r) $r.action.value = "16" },
    { param($r) $r.action.write_count = 2 },
    { param($r) $r.dark_stabilizer_cycle.supported = $false; $r.dark_stabilizer_cycle | Add-Member error "Unavailable" },
    { param($r) $r.dark_stabilizer_cycle.current = 0 },
    { param($r) $r.dark_stabilizer_cycle.readback_available = $true },
    { param($r) $r | Add-Member changed ([pscustomobject]@{ verified = $true }) }
)) {
    $receipt = $fixture | ConvertFrom-Json
    & $mutate $receipt
    $rejected = $false
    try { Assert-DeskMonitorResult $receipt "dark_stabilizer_cycle" | Out-Null }
    catch { $rejected = $true }
    if (-not $rejected) { throw "Invalid or state-verified cycle receipt was accepted." }
}
$receipt = $fixture | ConvertFrom-Json
$receipt.PSObject.Properties.Remove("action")
Assert-DeskMonitorResult $receipt "read" | Out-Null
$receipt | Add-Member changed ([pscustomobject]@{ control = "brightness"; requested = "75"; verified = $true })
Assert-DeskMonitorResult $receipt "brightness" "75" | Out-Null
$receipt.changed.verified = $false
$rejected = $false
try { Assert-DeskMonitorResult $receipt "brightness" "75" | Out-Null } catch { $rejected = $true }
if (-not $rejected) { throw "Cycle support weakened scalar readback verification." }
class DeskMonitorFixtureStream {
    [string]$Text
    DeskMonitorFixtureStream([string]$text) { $this.Text = $text }
    [Threading.Tasks.Task[string]] ReadToEndAsync() {
        return [Threading.Tasks.Task]::FromResult($this.Text)
    }
}
class DeskMonitorFixtureProcess {
    [Diagnostics.ProcessStartInfo]$StartInfo
    [DeskMonitorFixtureStream]$StandardOutput
    [DeskMonitorFixtureStream]$StandardError
    [bool]$Completes = $true
    [bool]$HasExited
    [int]$ExitCode
    [int]$Id = 12345
    [int]$Starts
    [int]$Kills
    [int]$Disposals
    DeskMonitorFixtureProcess([string]$reply) {
        $this.StandardOutput = [DeskMonitorFixtureStream]::new($reply)
        $this.StandardError = [DeskMonitorFixtureStream]::new("")
    }
    [bool] Start() { $this.Starts++; return $true }
    [bool] WaitForExit([int]$milliseconds) {
        if ($this.Completes -or $this.HasExited) { $this.HasExited = $true; return $true }
        Start-Sleep -Milliseconds $milliseconds
        return $false
    }
    [void] Kill() { $this.Kills++; $this.HasExited = $true }
    [void] Dispose() { $this.Disposals++ }
}
$wrapperAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot "GodBrain-DeskMonitor.ps1"), [ref]$null, [ref]$null)
$invokeDefinition = $wrapperAst.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Invoke-DeskMonitor"
}, $true)
try {
    . ([scriptblock]::Create($invokeDefinition.Extent.Text.Replace('[Diagnostics.Process]::new()', '$script:monitorTestProcess')))
    foreach ($case in @(
        @{ Reply = $fixture; Exit = 0; Complete = $true; Error = $null; Kills = 0 },
        @{ Reply = '{"schema_version":1,"ok":false,"error":"fixture cycle write failed","may_have_changed":true}'; Exit = 1; Complete = $true; Error = "*may have reached*current level is unavailable*No automatic retry*"; Kills = 0 },
        @{ Reply = '{"schema_version":1,"ok":false,"error":"fixture target absent","may_have_changed":false}'; Exit = 1; Complete = $true; Error = "fixture target absent"; Kills = 0 },
        @{ Reply = "invalid-json"; Exit = 0; Complete = $true; Error = "*may have reached*No automatic retry*"; Kills = 0 },
        @{ Reply = $fixture; Exit = 0; Complete = $false; Error = "*timed out*may have reached*No automatic retry*"; Kills = 1 }
    )) {
        $script:monitorTestProcess = [DeskMonitorFixtureProcess]::new($case.Reply)
        $script:monitorTestProcess.ExitCode = $case.Exit
        $script:monitorTestProcess.Completes = $case.Complete
        $failure = $null
        try { Invoke-DeskMonitor -Control dark_stabilizer_cycle -RepoRoot $repo -TimeoutSeconds 1 | Out-Null }
        catch { $failure = $_.Exception.Message }
        if (($case.Error -and $failure -notlike $case.Error) -or (-not $case.Error -and $failure)) {
            throw "Unexpected cycle wrapper result: $failure"
        }
        if ($script:monitorTestProcess.Starts -ne 1 -or $script:monitorTestProcess.Kills -ne $case.Kills -or
                $script:monitorTestProcess.Disposals -ne 1 -or
                $script:monitorTestProcess.StartInfo.ArgumentList.Count -ne 1 -or
                $script:monitorTestProcess.StartInfo.ArgumentList[0] -cne "--cycle-dark") {
            throw "Cycle wrapper repeated a request, used wrong arguments or failed owned-process cleanup."
        }
    }
} finally { . (Join-Path $PSScriptRoot "GodBrain-DeskMonitor.ps1") }
Write-Output "PASS: native capability gates, single E3=0x10 write including failure/no-retry, bounds, invalid arguments, honest cycle receipts and preserved scalar verification; no monitor access."
Write-Output "PASS: cycle wrapper timeout/failed-write/malformed-reply uncertainty, one request and exact-owned cleanup using process fixtures."

if (-not $LiveMonitor) { return }
$baseline = Invoke-DeskMonitor
foreach ($id in @("brightness", "contrast", "preset")) {
    if (-not $baseline.$id.supported) { throw "Live check requires readable $id." }
}
if (-not $baseline.preset.id) { throw "Cannot restore an unknown starting preset; no writes performed." }
if (-not $baseline.dark_stabilizer.supported) {
    Write-Warning "Dark Stabilizer is unavailable: $($baseline.dark_stabilizer.error) No Dark Stabilizer changes will be made."
}
$failure = $null
$restoreErrors = @()
try {
    foreach ($id in @("brightness", "contrast")) {
        $initial = [int]$baseline.$id.current
        $value = if ($initial -gt 0) { $initial - 1 } else { 1 }
        $changed = Invoke-DeskMonitor -Control $id -Value ([string]$value)
        if ($changed.$id.current -ne $value) { throw "$id readback mismatch." }
        Invoke-DeskMonitor -Control $id -Value ([string]$initial) | Out-Null
        Write-Output "PASS: $id change/readback/restore."
    }
    foreach ($preset in @("standard", "fps", "warm")) {
        $changed = Invoke-DeskMonitor -Control preset -Value $preset
        if ($changed.preset.id -cne $preset) { throw "Preset readback mismatch: $preset" }
        Write-Output "PASS: preset $preset (DC/F0/14 write families)."
    }
    Invoke-DeskMonitor -Control preset -Value ([string]$baseline.preset.id) | Out-Null
    if ($baseline.dark_stabilizer.supported) {
        foreach ($level in 0..3) {
            $changed = Invoke-DeskMonitor -Control dark_stabilizer -Value ([string]$level)
            if ($changed.dark_stabilizer.current -ne $level) { throw "Dark Stabilizer readback mismatch: $level" }
            Write-Output "PASS: Dark Stabilizer $level."
        }
    }
} catch {
    $failure = $_
} finally {
    # Preset first: switching it can reset the other controls.
    $restore = @(
        @{ Control = "preset"; Value = [string]$baseline.preset.id },
        @{ Control = "brightness"; Value = [string]$baseline.brightness.current },
        @{ Control = "contrast"; Value = [string]$baseline.contrast.current }
    )
    if ($baseline.dark_stabilizer.supported) {
        $restore += @{ Control = "dark_stabilizer"; Value = [string]$baseline.dark_stabilizer.current }
    }
    foreach ($item in $restore) {
        try { Invoke-DeskMonitor -Control $item.Control -Value $item.Value | Out-Null }
        catch { $restoreErrors += "$($item.Control): $($_.Exception.Message)" }
    }
}
if ($restoreErrors.Count) { throw "Monitor restoration failed: $($restoreErrors -join '; '). Original test failure: $failure" }
if ($failure) { throw $failure }
$restored = Invoke-DeskMonitor
foreach ($id in @("brightness", "contrast")) {
    if ($restored.$id.current -ne $baseline.$id.current) { throw "Final restoration mismatch: $id" }
}
if ($restored.preset.id -cne $baseline.preset.id) { throw "Final preset restoration mismatch." }
if ($baseline.dark_stabilizer.supported -and $restored.dark_stabilizer.current -ne $baseline.dark_stabilizer.current) {
    throw "Final Dark Stabilizer restoration mismatch."
}
Write-Output "PASS: supported live controls verified and the original readable settings restored."
if (-not $baseline.dark_stabilizer.supported) {
    Write-Warning "Dark Stabilizer remains disabled and unverified, not a passing live control."
}
