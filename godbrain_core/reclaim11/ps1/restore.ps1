# Find and apply reclaim11 restore.json. In-Windows only. Not Heal. Not WinPE.
# Newest stamp first so repeated applies walk back to the original before.

[CmdletBinding()]
param(
    [Alias("T", "Test")]
    [switch]$WhatIf,
    [switch]$Everything
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:Reclaim11Here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$invBoot = Join-Path $script:Reclaim11Here "inventory.ps1"
if (Test-Path -LiteralPath $invBoot) { . $invBoot }

function Get-Reclaim11BackupRoot {
    Join-Path $env:SystemDrive.TrimEnd("\") "reclaim11\backup"
}

function Get-Reclaim11RestoreKind {
    param([string]$Id)
    switch -Regex ([string]$Id) {
        '^reclaim11-xbox' { return "xbox" }
        '^reclaim11-telemetry' { return "telemetry" }
        '^reclaim11-nic' { return "nic" }
        '^reclaim11-latency' { return "latency" }
        '^reclaim11-noob' { return "safe" }
        '^reclaim11-killing' { return "kill" }
        default { return "unknown" }
    }
}

function Get-Reclaim11RestoreManifests {
    $root = Get-Reclaim11BackupRoot
    $out = @()
    if (-not (Test-Path -LiteralPath $root)) { return $out }
    foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        $p = Join-Path $dir.FullName "restore.json"
        if (-not (Test-Path -LiteralPath $p)) { continue }
        try {
            $m = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch { continue }
        $id = [string]$m.id
        $out += [pscustomobject]@{
            path  = $p
            id    = $id
            kind  = Get-Reclaim11RestoreKind $id
            at    = [string]$m.at
            stamp = [string]$dir.Name
        }
    }
    @($out | Sort-Object stamp -Descending)
}

function Restore-Reclaim11ByKind {
    param(
        $Item,
        [string]$Root = "",
        [switch]$WhatIf
    )
    if ($WhatIf) {
        return [pscustomobject]@{
            what_if = $true
            mutate  = $false
            kind    = [string]$Item.kind
            path    = [string]$Item.path
            id      = [string]$Item.id
        }
    }
    $kind = [string]$Item.kind
    $path = [string]$Item.path
    switch ($kind) {
        "xbox" { return Restore-Reclaim11XboxBackup -Manifest $path -Root $Root }
        "telemetry" { return Restore-Reclaim11TelemetryBackup -Manifest $path -Root $Root }
        "nic" { return Restore-Reclaim11NicBackup -Manifest $path -Root $Root }
        "latency" { return Restore-Reclaim11LatencyBackup -Manifest $path }
        "safe" { return Restore-Reclaim11NoobBackup -Manifest $path }
        "kill" { throw "Restore-Reclaim11ByKind: killing blows have no restore" }
        default { throw ("Restore-Reclaim11ByKind: unknown id {0}" -f $Item.id) }
    }
}

function Restore-Reclaim11Selected {
    param(
        [string[]]$Kinds,
        [string]$Root = "",
        [switch]$WhatIf
    )
    $want = @{}
    foreach ($k in @($Kinds)) { $want[$k] = $true }
    $items = @()
    foreach ($row in @(Get-Reclaim11RestoreManifests)) {
        if ($want.ContainsKey([string]$row.kind)) { $items += $row }
    }
    $results = @()
    $failed = @()
    foreach ($item in $items) {
        try {
            $results += Restore-Reclaim11ByKind -Item $item -Root $Root -WhatIf:$WhatIf
        } catch {
            $failed += ("{0} {1} {2}" -f $item.kind, $item.path, $_.Exception.Message)
        }
    }
    [pscustomobject]@{
        what_if = [bool]$WhatIf
        mutate  = -not [bool]$WhatIf
        kinds   = @($Kinds)
        items   = $items
        results = $results
        failed  = $failed
    }
}

if ($MyInvocation.InvocationName -ne ".") {
    $kinds = @("xbox", "telemetry", "nic", "latency", "safe")
    $plan = Restore-Reclaim11Selected -Kinds $kinds -WhatIf:$WhatIf
    $plan | ConvertTo-Json -Depth 6
}
