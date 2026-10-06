# Compatibility door: host recovery and optional gym now share AFK Watch.
[CmdletBinding()]
param()
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
& (Join-Path $repo "Watch-GodBrain.ps1") -RepoRoot $repo -Continuous -WithGym -Resume
