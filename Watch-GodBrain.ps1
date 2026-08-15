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
$starter = Join-Path $RepoRoot "Start-GodBrain.ps1"
if (-not (Test-Path -LiteralPath $starter)) {
    throw "Watch-GodBrain: missing $starter"
}

& $starter -RepoRoot $RepoRoot -MongoWaitSeconds 5
