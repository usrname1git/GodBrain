[CmdletBinding()]
param([switch]$Live)

$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot "GodBrain-DisplayProfiles.ps1")
$exe = Join-Path $repo "godbrain_core\cpp_tools\display-profiles.exe"
if (-not (Test-Path -LiteralPath $exe)) { throw "Run scripts\Build-DisplayProfiles.ps1 first." }
$self = (& $exe --self-test) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $self.self_test -cne "passed") { throw "Native display-profile fixtures failed." }
foreach ($arguments in @(
    @("--unknown"), @("--save", "../escape"), @("--save", "bad`nname"), @("--apply"),
    @("--list", "extra"), @("--current", "extra"), @("--apply", "Fixture", "--auto-keep"),
    @("--recover", "extra"), @("--preview", "Fixture", "extra"), @("--hotkey", "Fixture"),
    @("--apply", "Fixture", "--no-confirm", "extra"),
    @("--apply", "Fixture", "--owner", "1", "--unexpected"),
    @("--apply", "Fixture", "--no-confirm", "--owner", "1")
)) {
    $reply = (& $exe @arguments) | ConvertFrom-Json
    if ($LASTEXITCODE -eq 0 -or $reply.ok -ne $false -or $reply.may_have_changed -ne $false -or -not $reply.error) {
        throw "Native invalid arguments were not rejected before a display change."
    }
}
foreach ($name in @("", " ", "../escape", "bad`nname", "too/long", ("x" * 65), " outer")) {
    $rejected = $false
    try { Invoke-DisplayProfiles -Operation save -Name $name -RepoRoot "fixture-missing" | Out-Null }
    catch {
        if ($_.Exception.Message -notlike "Profile names must*") { throw }
        $rejected = $true
    }
    if (-not $rejected) { throw "Invalid profile name reached helper lookup." }
}
$profile = '{"name":"Fixture","hotkey":0,"displays":[{"label":"Synthetic display","width":1920,"height":1080,"x":0,"y":0,"primary":true,"rotation":1,"refresh_hz":60.0}]}' | ConvertFrom-Json
$fixture = [pscustomobject]@{ schema_version = 1; ok = $true; operation = "list"; recovery_pending = $false; profiles = @($profile) }
Assert-DisplayProfileResult $fixture "list" | Out-Null
foreach ($mutate in @(
    { param($r) $r.ok = "true" }, { param($r) $r.operation = "apply" },
    { param($r) $r.recovery_pending = "false" }, { param($r) $r.profiles[0].hotkey = 13 },
    { param($r) $r.profiles[0].displays[0].refresh_hz = 0 }, { param($r) $r.profiles[0].displays[0].width = -1 },
    { param($r) $r.profiles[0].displays[0].primary = $false }, { param($r) $r.profiles += $r.profiles[0] }
)) {
    $invalid = $fixture | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    & $mutate $invalid
    $rejected = $false
    try { Assert-DisplayProfileResult $invalid "list" | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw "Invalid display-profile summary was accepted." }
}
$applied = [pscustomobject]@{ schema_version = 1; ok = $true; operation = "apply"; outcome = "reverted"; confirmation = "timeout"; verified = $true; profile = $profile }
Assert-DisplayProfileResult $applied "apply" "Fixture" | Out-Null
foreach ($choice in @("keep", "saved_profile", "invented", $null)) {
    $invalid = $applied | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $invalid.confirmation = $choice
    $rejected = $false
    try { Assert-DisplayProfileResult $invalid "apply" "Fixture" | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw "Contradictory or missing confirmation reason was accepted." }
}
$applied.verified = $false
$rejected = $false
try { Assert-DisplayProfileResult $applied "apply" "Fixture" | Out-Null } catch { $rejected = $true }
if (-not $rejected) { throw "Unverified switch was accepted." }
$direct = [pscustomobject]@{ schema_version = 1; ok = $true; operation = "apply"; outcome = "kept"; confirmation = "saved_profile"; verified = $true; profile = $profile }
Assert-DisplayProfileResult $direct "apply" "Fixture" | Out-Null
$direct.outcome = "reverted"
$rejected = $false
try { Assert-DisplayProfileResult $direct "apply" "Fixture" | Out-Null } catch { $rejected = $true }
if (-not $rejected) { throw "Direct-switch receipt incorrectly allowed a reverted outcome." }
$direct.outcome = "kept"
class DisplayFixtureStream {
    [string]$Text
    DisplayFixtureStream([string]$text) { $this.Text = $text }
    [Threading.Tasks.Task[string]] ReadToEndAsync() { return [Threading.Tasks.Task]::FromResult($this.Text) }
}
class DisplayFixtureProcess {
    [Diagnostics.ProcessStartInfo]$StartInfo
    [DisplayFixtureStream]$StandardOutput
    [DisplayFixtureStream]$StandardError
    [int]$ExitCode
    [int]$Id = 12345
    [bool]$HasExited
    [int]$Starts
    [int]$Disposals
    DisplayFixtureProcess([string]$reply) {
        $this.StandardOutput = [DisplayFixtureStream]::new($reply)
        $this.StandardError = [DisplayFixtureStream]::new("")
    }
    [bool] Start() { $this.Starts++; return $true }
    [bool] WaitForExit([int]$milliseconds) { $this.HasExited = $true; return $true }
    [void] Kill() { throw "Fixture unexpectedly killed a process." }
    [void] Dispose() { $this.Disposals++ }
}
$wrapperAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot "GodBrain-DisplayProfiles.ps1"), [ref]$null, [ref]$null)
$definition = $wrapperAst.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Invoke-DisplayProfiles"
}, $true)
try {
    . ([scriptblock]::Create($definition.Extent.Text.Replace('[Diagnostics.Process]::new()', '$script:displayTestProcess')))
    $script:displayTestProcess = [DisplayFixtureProcess]::new(($fixture | ConvertTo-Json -Depth 8 -Compress))
    $null = Invoke-DisplayProfiles -Operation list -RepoRoot $repo
    if ($script:displayTestProcess.Starts -ne 1 -or $script:displayTestProcess.Disposals -ne 1 -or
            ($script:displayTestProcess.StartInfo.ArgumentList -join " ") -cne "--list") { throw "List process framing/ownership failed." }
    $saved = [pscustomobject]@{ schema_version = 1; ok = $true; operation = "save"; profile = $profile }
    $saved.profile.name = "Profile with spaces"
    $script:displayTestProcess = [DisplayFixtureProcess]::new(($saved | ConvertTo-Json -Depth 8 -Compress))
    $null = Invoke-DisplayProfiles -Operation save -Name "Profile with spaces" -Overwrite -RepoRoot $repo
    if ($script:displayTestProcess.StartInfo.ArgumentList.Count -ne 3 -or
            $script:displayTestProcess.StartInfo.ArgumentList[1] -cne "Profile with spaces" -or
            $script:displayTestProcess.StartInfo.ArgumentList[2] -cne "--overwrite") { throw "Typed save/overwrite arguments were not preserved." }
    $script:displayTestProcess = [DisplayFixtureProcess]::new(($direct | ConvertTo-Json -Depth 8 -Compress))
    $null = Invoke-DisplayProfiles -Operation apply -Name "Profile with spaces" -RepoRoot $repo
    $arguments = $script:displayTestProcess.StartInfo.ArgumentList
    if ($arguments.Count -ne 5 -or $arguments[0] -cne "--apply" -or $arguments[1] -cne "Profile with spaces" -or
            $arguments[2] -cne "--owner" -or $arguments[3] -cne [string][Environment]::ProcessId -or
            $arguments[4] -cne "--no-confirm" -or $script:displayTestProcess.Disposals -ne 1) {
        throw "Saved-profile Apply did not request the no-popup mode with exact process ownership."
    }
    $script:displayTestProcess = [DisplayFixtureProcess]::new('{"schema_version":1,"ok":false,"error":"Fixture explicit failure","may_have_changed":false}')
    $script:displayTestProcess.ExitCode = 1
    $rejected = $false
    try { Invoke-DisplayProfiles -RepoRoot $repo | Out-Null } catch { if ($_.Exception.Message -cne "Fixture explicit failure") { throw }; $rejected = $true }
    if (-not $rejected -or $script:displayTestProcess.Disposals -ne 1) { throw "Helper error was hidden or process leaked." }
} finally { . (Join-Path $PSScriptRoot "GodBrain-DisplayProfiles.ps1") }
Write-Output "PASS: native schema/source remapping/ambiguity/clone-topology/scaling verification; distinct live/database snapshots, durable pre-Keep markers, legacy recovery and failed persistence rollback; typed wrapper and fail-closed receipts. No display reads or changes."
if ($Live) {
    $result = (& $exe --live-test) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $result.ok -ne $true -or $result.fixtures -ne 2 -or
            $result.single_display_reverted -ne $true -or $result.alternate_primary_reverted -ne $true -or $result.restored -ne $true) {
        throw "Live display-switch/restoration gate failed: $($result.error)"
    }
    Write-Output "PASS: real temporary single-display and alternate-primary switches, requested readbacks and verified restoration; no persistent layout changes."
}
