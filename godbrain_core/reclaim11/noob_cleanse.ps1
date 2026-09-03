# Safe cleanse: move pack-A files to a backup catalog + restore.json. Never delete.
# Never BFE / mpssvc / FltMgr. Desk (IoTEnterpriseS) refused when targeting this OS.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-Reclaim11FileSha256 {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Invoke-Reclaim11NoobCleanse {
    param(
        [string]$Root,
        [string]$VolumeRoot = "",
        [string]$BackupRoot = "",
        [Alias("T", "Test")]
        [switch]$WhatIf
    )
    if ([string]::IsNullOrWhiteSpace($Root)) {
        $Root = Split-Path -Parent $PSCommandPath
    }
    $invPath = Join-Path $Root "inventory.ps1"
    . $invPath
    $off = Join-Path $Root "winpe\offline.ps1"
    if (-not (Test-Path -LiteralPath $off)) { $off = Join-Path $Root "offline.ps1" }
    if (Test-Path -LiteralPath $off) { . $off }
    $cat = Get-Reclaim11Catalog -Root $Root
    $live = [string]::IsNullOrWhiteSpace($VolumeRoot)
    if ($live) { $VolumeRoot = $env:SystemDrive }
    $VolumeRoot = $VolumeRoot.TrimEnd("\")
    $sysDrive = $env:SystemDrive.TrimEnd("\")
    $deskLive = (Test-Reclaim11DeskHost) -and ($VolumeRoot -eq $sysDrive)
    if ($deskLive -and -not $WhatIf) {
        throw "Refuse: desk (IoTEnterpriseS). Safe cleanse is VM-only. Not M1ABRAMS."
    }
    foreach ($s in @($cat.never_touch_services)) {
        if (@($cat.services_pack_a) -contains $s) {
            throw "Refuse: pack A lists never-touch $s"
        }
    }
    $wd = Join-Path $env:SystemRoot "System32\drivers\WdFilter.sys"
    $wdPresent = $live -and (Test-Path -LiteralPath $wd)
    if ($wdPresent -and -not $WhatIf) {
        throw "Refuse: WdFilter.sys still present. Boot WinPE first (PPL)."
    }

    $stamp = [datetime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
    if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
        $BackupRoot = Join-Path $VolumeRoot ("reclaim11\backup\" + $stamp)
    }
    if ((-not $WhatIf) -and -not (Test-Path -LiteralPath $BackupRoot)) {
        New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    }

    $cands = @()
    foreach ($rel in @(Get-Reclaim11PplOfflineRelPaths)) {
        $full = Join-Path $VolumeRoot $rel
        $cands += $full
        $cands += ($full + ".reclaim11.bak")
    }
    foreach ($rel in @(Get-Reclaim11UsermodeRelPaths)) {
        $full = Join-Path $VolumeRoot $rel
        $cands += $full
        $cands += ($full + ".reclaim11.bak")
    }
    $items = @()
    $seen = @{}
    foreach ($src in $cands) {
        if ($seen.ContainsKey($src.ToLowerInvariant())) { continue }
        $seen[$src.ToLowerInvariant()] = $true
        if (-not (Test-Path -LiteralPath $src)) { continue }
        if (Test-Reclaim11NeverTouchPath -VolumeRoot $VolumeRoot -Path $src) { continue }
        $leaf = [IO.Path]::GetFileName($src)
        if ($leaf -eq "wdf01000.sys" -or $leaf -eq "WdfLdr.sys" -or $leaf -eq "WdiWiFi.sys") { continue }
        $rel = $src.Substring($VolumeRoot.Length).TrimStart("\")
        $dest = Join-Path $BackupRoot $rel
        $len = (Get-Item -LiteralPath $src).Length
        if ($WhatIf) {
            $items += [pscustomobject]@{
                original = $src
                backup   = $dest
                relative = $rel
                sha256   = $null
                length   = $len
            }
            continue
        }
        $destDir = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        $hash = Get-Reclaim11FileSha256 -Path $src
        Move-Item -LiteralPath $src -Destination $dest -Force
        $items += [pscustomobject]@{
            original = $src
            backup   = $dest
            relative = $rel
            sha256   = $hash
            length   = $len
        }
    }

    $manifest = [pscustomobject]@{
        id          = "reclaim11-noob-v1"
        at          = [datetime]::UtcNow.ToString("o")
        catalog     = [string]$cat.id
        volume_root = $VolumeRoot
        backup_root = $BackupRoot
        items       = $items
        note        = "Move-only. Restore with Restore-Reclaim11Noob.ps1 -Manifest restore.json"
    }
    $manPath = Join-Path $BackupRoot "restore.json"
    if ($WhatIf) {
        $checks = @(
            (New-Reclaim11Check -Name "desk" -Ok (-not $deskLive) -Detail $(if ($deskLive) { "IoTEnterpriseS would refuse" } else { "not desk SKU" })),
            (New-Reclaim11Check -Name "WdFilter" -Ok (-not $wdPresent) -Detail $(if ($wdPresent) { $wd } else { "parked or offline volume" }))
        )
        $would = @($items | ForEach-Object { "move {0} -> {1}" -f $_.original, $_.backup })
        $fail = @($checks | Where-Object { -not $_.ok } | ForEach-Object { $_.name })
        $manifest | Add-Member -NotePropertyName what_if -NotePropertyValue $true
        $manifest | Add-Member -NotePropertyName mutate -NotePropertyValue $false
        $manifest | Add-Member -NotePropertyName checks -NotePropertyValue $checks
        $manifest | Add-Member -NotePropertyName would -NotePropertyValue $would
        $manifest | Add-Member -NotePropertyName would_refuse -NotePropertyValue $(if ($fail.Count -gt 0) { ($fail -join ",") } else { "" })
        $manifest | Add-Member -NotePropertyName manifest_path -NotePropertyValue $manPath
        return $manifest
    }
    ($manifest | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $manPath -Encoding UTF8
    $manifest | Add-Member -NotePropertyName manifest_path -NotePropertyValue $manPath
    $manifest
}

function Restore-Reclaim11NoobBackup {
    param([string]$Manifest)
    if (-not (Test-Path -LiteralPath $Manifest)) {
        throw "Restore-Reclaim11NoobBackup: missing $Manifest"
    }
    $m = Get-Content -LiteralPath $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$m.id -notlike "reclaim11-noob*") {
        throw "Restore-Reclaim11NoobBackup: not a Safe cleanse manifest"
    }
    $restored = @()
    foreach ($it in @($m.items)) {
        if (-not (Test-Path -LiteralPath $it.backup)) {
            throw "Restore-Reclaim11NoobBackup: missing backup $($it.backup)"
        }
        $dir = Split-Path -Parent $it.original
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Copy-Item -LiteralPath $it.backup -Destination $it.original -Force
        $restored += [string]$it.original
    }
    [pscustomobject]@{ manifest = $Manifest; restored = $restored }
}
