[CmdletBinding()]
param(
    [ValidateSet("run", "status", "stop", "tasks", "lessons", "objectives", "university", "dashboard")]
    [string]$Command = "run",
    [string]$RepoRoot = $PSScriptRoot,
    [string]$Endpoint = "",
    [string]$Model = "",
    [string]$TeacherEndpoint = "",
    [string]$TeacherModel = "",
    [string]$Task = "",
    [string]$WorkDir = "",
    [string]$Browser = "",
    [ValidateRange(1, 1000000)][int]$Rounds = 1,
    [ValidateRange(1, 20)][int]$MaxAttempts = 4,
    [ValidateRange(1, 1000)][int]$KeepRuns = 24,
    [ValidateRange(0, 20)][int]$TutorEvery = 2,
    [ValidateRange(0, 65535)][int]$DashboardPort = 4177,
    [switch]$Continuous,
    [switch]$OfflineDocs,
    [switch]$Json,
    [switch]$NoDashboard,
    [switch]$WithMouth
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Resolve-GodBrainRoot.ps1")
. (Join-Path $PSScriptRoot "GodBrain-Mouth.ps1")
if ($WithMouth -and $Command -eq "run" -and [string]::IsNullOrWhiteSpace($Endpoint)) {
    $Endpoint = "http://127.0.0.1:8000/v1"
}
$entry = Join-Path $RepoRoot "godbrain_core\skill_lab\gym.mjs"
$node = Get-Command node -ErrorAction Stop
$arguments = @(
    $entry, $Command, "--rounds", "$Rounds", "--max-attempts", "$MaxAttempts",
    "--keep-runs", "$KeepRuns", "--tutor-every", "$TutorEvery",
    "--dashboard-port", "$DashboardPort"
)
foreach ($option in @(
    @("--endpoint", $Endpoint), @("--model", $Model),
    @("--teacher-endpoint", $TeacherEndpoint), @("--teacher-model", $TeacherModel),
    @("--task", $Task), @("--work-dir", $WorkDir), @("--browser", $Browser)
)) {
    if (-not [string]::IsNullOrWhiteSpace($option[1])) { $arguments += $option }
}
if ($Continuous) { $arguments += "--continuous" }
if ($OfflineDocs) { $arguments += "--offline-docs" }
if ($Json) { $arguments += "--json" }
if ($NoDashboard) { $arguments += "--no-dashboard" }

$pauseMouthAfter = $false
$endpointPort = ""
if (-not [string]::IsNullOrWhiteSpace($Endpoint)) {
    try { $endpointPort = ([Uri]$Endpoint).Port.ToString() } catch { }
}
if ($WithMouth -and $Command -eq "run") {
    if ($endpointPort -eq "8888") {
        throw "Invoke-FrontendGym -WithMouth is the desk llama on :8000. For Qwen use :8888 without -WithMouth (Start-PaperQwen yourself)."
    }
    if ([string]::IsNullOrWhiteSpace($Endpoint) -or $endpointPort -eq "8000") {
        $mouthWasListening = $null -ne (Get-NetTCPConnection -LocalPort 8000 -State Listen -ErrorAction SilentlyContinue)
        $mouthWasLoading = $null -ne (Get-Process -Name "llama-server" -ErrorAction SilentlyContinue)
        $mouthWasPaused = Test-GodBrainMouthPaused -RepoRoot $RepoRoot
        if ($mouthWasPaused -or (-not $mouthWasListening -and -not $mouthWasLoading)) {
            Write-Host "Frontend gym: desk mouth on for this run, restore pause after"
            & (Join-Path $PSScriptRoot "Start-LlamaServer.ps1") -RepoRoot $RepoRoot -Resume
            $pauseMouthAfter = $true
        } else {
            Write-Host "Frontend gym: reusing the already-running desk mouth"
        }
    }
}

try {
    & $node.Source @arguments
    if ($LASTEXITCODE -ne 0) { throw "Frontend gym exited with code $LASTEXITCODE" }
} finally {
    if ($pauseMouthAfter) {
        Write-Host "Frontend gym: pausing desk mouth (slot free)"
        & (Join-Path $PSScriptRoot "Stop-LlamaServer.ps1") -RepoRoot $RepoRoot
    }
}
