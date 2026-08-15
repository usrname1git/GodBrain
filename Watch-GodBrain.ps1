# Idempotent keep-alive. Starts missing pieces. Never stops or deletes anything.
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

# Closed loop: detect → start missing allowlist → verify → remember.
# Never kills Colibri or anything else.
& $heal -RepoRoot $RepoRoot
