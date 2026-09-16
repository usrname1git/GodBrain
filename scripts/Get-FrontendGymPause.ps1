[CmdletBinding()]
param([string]$RepoRoot = $PSScriptRoot)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Resolve-GodBrainRoot.ps1")
. (Join-Path $RepoRoot "GodBrain-Cs2.ps1")

$manualPause = $false
$stopQwen = $false
$pauseFile = Join-Path $RepoRoot "godbrain_core\skill_lab\work\gym\training-pause.json"
if (Test-Path -LiteralPath $pauseFile) {
    try {
        $control = Get-Content -LiteralPath $pauseFile -Raw | ConvertFrom-Json
        $manualPause = [bool]$control.paused
        $stopQwen = $manualPause -and [bool]$control.stopQwen
    } catch {
        throw "Frontend gym pause state is invalid: $($_.Exception.Message)"
    }
}
$cs2Sleep = [bool](Test-GodBrainColiShouldSleep -RepoRoot $RepoRoot)

@{
    cs2_sleep = $cs2Sleep
    manual_pause = $manualPause
    stop_qwen = $stopQwen
    paused = $manualPause -or $cs2Sleep
} |
    ConvertTo-Json -Compress
