# Sets $RepoRoot to the folder that contains Start-GodBrain.ps1.
# Dot-source from helper scripts in this directory. Loop doors stay at repo root.

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $RepoRoot = $PSScriptRoot
    } elseif ($MyInvocation.MyCommand.Path) {
        $RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
}
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    throw "Resolve-GodBrainRoot: RepoRoot is empty."
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$marker = Join-Path $RepoRoot "Start-GodBrain.ps1"
if (-not (Test-Path -LiteralPath $marker)) {
    $parent = Split-Path $RepoRoot -Parent
    $parentMarker = Join-Path $parent "Start-GodBrain.ps1"
    if (Test-Path -LiteralPath $parentMarker) {
        $RepoRoot = $parent
    } else {
        throw "Resolve-GodBrainRoot: Start-GodBrain.ps1 not in $RepoRoot or parent."
    }
}
