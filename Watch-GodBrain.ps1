# Same loop as Heal, on a timer. Discover → start missing → verify.
# Never stops or deletes anything. Not a graph, not a second agent.
# Safe to run every few minutes as the logged-in user (not LocalSystem).

[CmdletBinding()]
param(
    [string]$RepoRoot = $PSScriptRoot
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($RepoRoot) -and $MyInvocation.MyCommand.Path) {
    $RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    throw "Watch-GodBrain: RepoRoot is empty."
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$heal = Join-Path $RepoRoot "Heal-GodBrain.ps1"
if (-not (Test-Path -LiteralPath $heal)) {
    throw "Watch-GodBrain: missing $heal"
}

# Closed loop: detect → start missing allowlist → diagnose → maybe
# flushdns → verify → remember. Never kills Colibri or anything else.
# Watch-Cs2Pause disables this task while CS2.exe is running.
& $heal -RepoRoot $RepoRoot
