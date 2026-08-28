# Safety net if CS2 is started from Steam instead of Start-CS2.ps1.
# Prefer Start-CS2.ps1: it pauses GodBrain and Tailscale before launch.

[CmdletBinding()]
param(
    [string]$RepoRoot = ""
)

$ErrorActionPreference = "Stop"
# $PSScriptRoot in a param() default is empty when Task Scheduler launches -File.
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $RepoRoot = $PSScriptRoot
    } elseif ($MyInvocation.MyCommand.Path) {
        $RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
}
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    throw "Watch-Cs2Pause: RepoRoot is empty."
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)

$helper = Join-Path $RepoRoot "GodBrain-Cs2.ps1"
if (-not (Test-Path -LiteralPath $helper)) {
    throw "Watch-Cs2Pause: missing $helper"
}
. $helper

$cs2 = Test-Cs2Running
$state = Read-Cs2PauseState $RepoRoot

if ($cs2) {
    if (-not $state.paused) {
        Suspend-GodBrainForCs2 $RepoRoot
    } else {
        $state.last_seen = (Get-Date).ToUniversalTime().ToString("o")
        Write-Cs2PauseState $RepoRoot $state
    }
    exit 0
}

$gone = Get-Cs2GoneMinutes $RepoRoot
if ($state.paused -and ($null -ne $gone) -and $gone -ge (Get-Cs2ResumeDelayMinutes)) {
    Resume-GodBrainAfterCs2 $RepoRoot
    exit 0
}

Write-Host ("cs2-pause: idle cs2={0} paused={1} gone_min={2}" -f $cs2, $state.paused, $gone)
exit 0
