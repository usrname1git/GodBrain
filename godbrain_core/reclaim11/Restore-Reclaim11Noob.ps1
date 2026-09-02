# Restore a noob-cleanse catalog. Usage: -Manifest C:\reclaim11\backup\<stamp>\restore.json
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Manifest
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "noob_cleanse.ps1")
Restore-Reclaim11NoobBackup -Manifest $Manifest | ConvertTo-Json -Depth 6
