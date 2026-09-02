# Noob cleanse: move pack-A files to a backup catalog + restore.json. Never delete.
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
        [string]$BackupRoot = ""
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
    if ((Test-Reclaim11DeskHost) -and ($VolumeRoot -eq $sysDrive)) {
        throw "Refuse: desk (IoTEnterpriseS). Noob cleanse is VM-only. Not M1ABRAMS."
    }
    foreach ($s in @($cat.never_touch_services)) {
        if (@($cat.services_pack_a) -contains $s) {
            throw "Refuse: pack A lists never-touch $s"
        }
    }
    if ($live) {
        $wd = Join-Path $env:SystemRoot "System32\drivers\WdFilter.sys"
        if (Test-Path -LiteralPath $wd) {
            throw "Refuse: WdFilter.sys still present. Boot WinPE first (PPL)."
        }
    }

    $stamp = [datetime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
    if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
        $BackupRoot = Join-Path $VolumeRoot ("reclaim11\backup\" + $stamp)
    }
    if (-not (Test-Path -LiteralPath $BackupRoot)) {
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
        $destDir = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        $len = (Get-Item -LiteralPath $src).Length
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
        throw "Restore-Reclaim11NoobBackup: not a noob manifest"
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
