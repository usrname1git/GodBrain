# Headless pack-A killing blows. VM-only. Never BFE / mpssvc / FltMgr.
[CmdletBinding()]
param(
    [Alias("T", "Test")]
    [switch]$WhatIf
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "killing_blows.ps1")
$plan = Invoke-Reclaim11KillingBlows -Root $here -WhatIf:$WhatIf
if ($WhatIf) {
    Write-Host (Format-Reclaim11TestReport -Plan $plan -Title "killing_blows")
}
$plan | ConvertTo-Json -Depth 6
if (-not $WhatIf) {
    Write-Host ("applied {0}" -f @($plan.applied).Count)
}
