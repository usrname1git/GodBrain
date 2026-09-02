# Noob cleanse: move pack-A files to backup + restore.json. Never delete.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "noob_cleanse.ps1")
$plan = Invoke-Reclaim11NoobCleanse -Root $here
$plan | ConvertTo-Json -Depth 8
Write-Host ("moved {0} -> {1}" -f @($plan.items).Count, $plan.backup_root)
