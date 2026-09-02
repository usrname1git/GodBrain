# Disable connected-experience telemetry. restore.json first.
# DiagTrack + dmwappushservice (from the old autom8ed nuke lists). AllowTelemetry=0.
# Never BFE / mpssvc / FltMgr / EventLog. Desk (IoTEnterpriseS) refused.
# No TI hop (HKCU/admin is enough). No scheduled-task glob.

[CmdletBinding()]
param(
    [string]$Restore = "",
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:TelemetryServices = @(
    "DiagTrack",
    "dmwappushservice"
)

function Test-Reclaim11TelemetryDeskHost {
    $n = Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
    [string]$n.EditionID -eq "IoTEnterpriseS"
}

function Write-Reclaim11TelemetryManifest {
    param($Manifest, [string]$Path)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    ($Manifest | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-Reclaim11TelemetryAllowSnapshot {
    $path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection"
    $present = $false
    $value = $null
    if (Test-Path -LiteralPath $path) {
        $p = Get-ItemProperty -LiteralPath $path -ErrorAction SilentlyContinue
        if ($p -and $p.PSObject.Properties["AllowTelemetry"]) {
            $present = $true
            $value = [int]$p.AllowTelemetry
        }
    }
    [pscustomobject]@{ path = $path; present = $present; value = $value }
}

function Invoke-Reclaim11TelemetryCleanse {
    param(
        [string]$Root,
        [switch]$WhatIf
    )
    if ([string]::IsNullOrWhiteSpace($Root)) {
        if ($PSScriptRoot) { $Root = $PSScriptRoot }
        else { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
    }
    $invPath = Join-Path $Root "inventory.ps1"
    $catPath = Join-Path $Root "catalog.json"
    if (Test-Path -LiteralPath $invPath) { . $invPath }
    if (Get-Command Get-Reclaim11Catalog -ErrorAction SilentlyContinue) {
        $cat = Get-Reclaim11Catalog -Root $Root
    } elseif (Test-Path -LiteralPath $catPath) {
        $cat = Get-Content -LiteralPath $catPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } else {
        throw "telemetry_cleanse: missing $invPath and $catPath (copy the whole reclaim11 folder)"
    }

    $never = @($cat.never_touch_services)
    foreach ($s in $script:TelemetryServices) {
        if ($never -contains $s) { throw "Refuse: telemetry list collides never-touch $s" }
        if ($s -ieq "BFE" -or $s -ieq "mpssvc" -or $s -ieq "FltMgr" -or $s -ieq "EventLog") {
            throw "Refuse: telemetry list hits $s"
        }
    }

    if (Test-Reclaim11TelemetryDeskHost) {
        throw "Refuse: desk (IoTEnterpriseS). Telemetry cleanse is VM-only. Not M1ABRAMS."
    }

    $allow = Get-Reclaim11TelemetryAllowSnapshot
    $svcSnap = @()
    foreach ($name in $script:TelemetryServices) {
        $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$name"
        $start = $null
        $present = Test-Path -LiteralPath $key
        if ($present) {
            $p = Get-ItemProperty -LiteralPath $key
            if ($p.PSObject.Properties["Start"]) { $start = [int]$p.Start }
        }
        $svcSnap += [pscustomobject]@{
            name    = $name
            present = $present
            start   = $start
        }
    }

    $stamp = [datetime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
    $backupRoot = Join-Path $env:SystemDrive.TrimEnd("\") ("reclaim11\backup\" + $stamp)
    $manPath = Join-Path $backupRoot "restore.json"
    $manifest = [pscustomobject]@{
        id          = "reclaim11-telemetry-v1"
        at          = [datetime]::UtcNow.ToString("o")
        allow       = $allow
        services    = @($svcSnap)
        backup_root = $backupRoot
        note        = "Restore with pwsh -File telemetry_cleanse.ps1 -Restore restore.json. Services disabled, not deleted."
    }

    if ($WhatIf) {
        $manifest | Add-Member -NotePropertyName what_if -NotePropertyValue $true
        $manifest | Add-Member -NotePropertyName manifest_path -NotePropertyValue $manPath
        return $manifest
    }

    Write-Reclaim11TelemetryManifest -Manifest $manifest -Path $manPath

    $pol = [string]$allow.path
    if (-not (Test-Path -LiteralPath $pol)) { New-Item -Path $pol -Force | Out-Null }
    New-ItemProperty -Path $pol -Name AllowTelemetry -Value 0 -PropertyType DWord -Force | Out-Null

    $disabled = @()
    foreach ($s in @($svcSnap)) {
        if (-not [bool]$s.present) { continue }
        $name = [string]$s.name
        sc.exe stop $name 2>&1 | Out-Null
        sc.exe config $name start= disabled 2>&1 | Out-Null
        $disabled += $name
    }

    $manifest | Add-Member -NotePropertyName sc_disabled -NotePropertyValue $disabled
    $manifest | Add-Member -NotePropertyName applied -NotePropertyValue $true
    $manifest | Add-Member -NotePropertyName manifest_path -NotePropertyValue $manPath
    Write-Reclaim11TelemetryManifest -Manifest $manifest -Path $manPath
    $manifest
}

function Restore-Reclaim11TelemetryBackup {
    param(
        [string]$Manifest,
        [string]$Root
    )
    if ([string]::IsNullOrWhiteSpace($Root)) {
        $Root = Split-Path -Parent $PSCommandPath
        if (-not $Root) { $Root = $PSScriptRoot }
    }
    if (-not (Test-Path -LiteralPath $Manifest)) {
        throw "Restore-Reclaim11TelemetryBackup: missing $Manifest"
    }
    $m = Get-Content -LiteralPath $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$m.id -notlike "reclaim11-telemetry*") {
        throw "Restore-Reclaim11TelemetryBackup: not a telemetry manifest"
    }
    if (Test-Reclaim11TelemetryDeskHost) {
        throw "Refuse: desk (IoTEnterpriseS). Telemetry restore is VM-only. Not M1ABRAMS."
    }
    $restored = @()
    $path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection"
    if ($m.allow -and [bool]$m.allow.present) {
        if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
        New-ItemProperty -Path $path -Name AllowTelemetry -Value ([int]$m.allow.value) -PropertyType DWord -Force | Out-Null
        $restored += "AllowTelemetry"
    } elseif (Test-Path -LiteralPath $path) {
        Remove-ItemProperty -LiteralPath $path -Name AllowTelemetry -ErrorAction SilentlyContinue
        $restored += "AllowTelemetry-removed"
    }
    foreach ($s in @($m.services)) {
        $name = [string]$s.name
        if (-not [bool]$s.present) { continue }
        if ($null -eq $s.start) { continue }
        $map = @{ 2 = "auto"; 3 = "demand"; 4 = "disabled" }
        $want = $map[[int]$s.start]
        if (-not $want) { $want = "demand" }
        sc.exe config $name start= $want 2>&1 | Out-Null
        $restored += ("service:" + $name)
    }
    [pscustomobject]@{ manifest = $Manifest; restored = @($restored) }
}

if ($MyInvocation.InvocationName -ne ".") {
    if (-not [string]::IsNullOrWhiteSpace($Restore)) {
        Restore-Reclaim11TelemetryBackup -Manifest $Restore | ConvertTo-Json -Depth 6
    } else {
        $plan = Invoke-Reclaim11TelemetryCleanse -WhatIf:$WhatIf
        $plan | ConvertTo-Json -Depth 8
        if ($plan.PSObject.Properties["manifest_path"] -and $plan.manifest_path) {
            Write-Host ("restore.json {0}" -f $plan.manifest_path)
        }
    }
}
