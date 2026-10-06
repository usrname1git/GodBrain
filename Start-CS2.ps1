# Release the model GPU slot, leave automation paused, launch CS2 and return.
# Nothing is automatically resumed after the game. Use the desk controls.

[CmdletBinding()]
param(
    [string]$RepoRoot = $PSScriptRoot,
    [string]$SteamExe = "C:\Program Files (x86)\Steam\steam.exe",
    [int]$AppId = 730
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($RepoRoot) -and $MyInvocation.MyCommand.Path) {
    $RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    throw "Start-CS2: RepoRoot is empty."
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)

$helper = Join-Path $RepoRoot "GodBrain-Cs2.ps1"
if (-not (Test-Path -LiteralPath $helper)) {
    throw "Start-CS2: missing $helper"
}
. $helper

if (-not (Test-Path -LiteralPath $SteamExe)) {
    throw "Start-CS2: Steam not at $SteamExe"
}

Write-Host "Start-CS2: pausing GodBrain before launch"
Suspend-GodBrainForCs2 $RepoRoot
if (Test-Cs2Running) {
    Write-Host "Start-CS2: CS2 is already running."
} else {
    Write-Host ("Start-CS2: launching Steam app {0}" -f $AppId)
    Start-Process -FilePath $SteamExe -ArgumentList @("-applaunch", "$AppId")
}
Write-Host "Start-CS2: launch handed to Steam. Models, gym training and Watch stay paused; resume manually from the desk."
