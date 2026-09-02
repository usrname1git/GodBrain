# Headless pack-A killing blows. VM-only. Never BFE / mpssvc / FltMgr.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "killing_blows.ps1")
$plan = Invoke-Reclaim11KillingBlows -Root $here
$plan | ConvertTo-Json -Depth 6
Write-Host ("applied {0}" -f @($plan.applied).Count)
