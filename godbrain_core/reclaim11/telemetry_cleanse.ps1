# CTT WPFTweaksTelemetry, applied from pinned JSON. Not irm|iex.
# restore.json first. Desk (IoTEnterpriseS) refused. Never BFE / mpssvc / FltMgr.
# Never Set-MpPreference (pack A kills Defender). Never TI hop (HKCU must stay the user).
# Later: drop a tested CTT export into ctt/; allow.json is the gate.

[CmdletBinding()]
param(
    [string]$Restore = "",
    [string]$Config = "",
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-Reclaim11TelemetryDeskHost {
    $n = Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
    [string]$n.EditionID -eq "IoTEnterpriseS"
}

function Get-Reclaim11CttDir {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        if ($PSScriptRoot) { $Root = $PSScriptRoot }
        else { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
    }
    Join-Path $Root "ctt"
}

function Get-Reclaim11CttAllow {
    param([string]$Root)
    $path = Join-Path (Get-Reclaim11CttDir -Root $Root) "allow.json"
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Get-Reclaim11CttAllow: missing $path"
    }
    Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-Reclaim11CttTweak {
    param(
        [string]$Root,
        [string]$Id = "WPFTweaksTelemetry"
    )
    $allow = Get-Reclaim11CttAllow -Root $Root
    $canon = Resolve-Reclaim11CttId -Allow $allow -Id $Id
    $path = Join-Path (Get-Reclaim11CttDir -Root $Root) ($canon + ".json")
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Get-Reclaim11CttTweak: no pinned $canon ($path)"
    }
    Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Resolve-Reclaim11CttId {
    param($Allow, [string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) {
        throw "Resolve-Reclaim11CttId: blank id"
    }
    $name = $Id.Trim()
    if ($Allow.PSObject.Properties["alias"] -and $Allow.alias.PSObject.Properties[$name]) {
        $name = [string]$Allow.alias.$name
    }
    $name
}

function Get-Reclaim11CttSelectedIds {
    param($Config)
    $ids = @()
    if ($null -eq $Config) { return $ids }
    if ($Config -is [string]) {
        $p = [string]$Config
        if (Test-Path -LiteralPath $p) {
            $Config = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
        } else {
            throw "Get-Reclaim11CttSelectedIds: missing $p"
        }
    }
    if ($Config -is [System.Collections.IEnumerable] -and $Config -isnot [string] -and $Config -isnot [pscustomobject] -and $Config -isnot [hashtable]) {
        foreach ($x in @($Config)) { $ids += [string]$x }
        return @($ids | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    $obj = $Config
    if ($obj.PSObject.Properties["WPFTweaks"]) {
        foreach ($x in @($obj.WPFTweaks)) { $ids += [string]$x }
    }
    foreach ($p in $obj.PSObject.Properties) {
        if ($p.Name -like "WPFTweaks*" -and $p.Name -ne "WPFTweaks") {
            $v = $p.Value
            if ($v -is [bool] -and $v) { $ids += $p.Name }
            elseif ([string]$v -eq "1") { $ids += $p.Name }
        }
    }
    @($ids | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Test-Reclaim11CttImport {
    param(
        [string]$Root,
        $Config
    )
    $allow = Get-Reclaim11CttAllow -Root $Root
    $ids = @(Get-Reclaim11CttSelectedIds -Config $Config)
    if ($ids.Count -lt 1) {
        throw "Test-Reclaim11CttImport: no WPFTweaks ids in config"
    }
    $ok = @()
    $bad = @()
    $never = @()
    if ($allow.PSObject.Properties["never"]) { $never = @($allow.never) }
    $allowed = @($allow.allow)
    foreach ($raw in $ids) {
        $id = Resolve-Reclaim11CttId -Allow $allow -Id $raw
        if ($never -contains $id) {
            $bad += $id
            continue
        }
        if ($allowed -notcontains $id) {
            $bad += $id
            continue
        }
        $ok += $id
    }
    if ($bad.Count -gt 0) {
        throw ("Refuse: CTT ids not allowlisted: {0}" -f ($bad -join ", "))
    }
    [pscustomobject]@{
        allow_id = [string]$allow.id
        ids      = @($ok)
    }
}

function Get-Reclaim11RegSnapshot {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ path = $Path; name = $Name; present = $false; value = $null; kind = $null }
    }
    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $item) {
        return [pscustomobject]@{ path = $Path; name = $Name; present = $false; value = $null; kind = $null }
    }
    $names = @($item.GetValueNames())
    if ($names -notcontains $Name) {
        return [pscustomobject]@{ path = $Path; name = $Name; present = $false; value = $null; kind = $null }
    }
    [pscustomobject]@{
        path    = $Path
        name    = $Name
        present = $true
        value   = $item.GetValue($Name)
        kind    = [string]$item.GetValueKind($Name)
    }
}

function Set-Reclaim11RegEntry {
    param($Entry)
    $path = [string]$Entry.Path
    $name = [string]$Entry.Name
    $type = [string]$Entry.Type
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -Path $path -Force | Out-Null
    }
    $val = $Entry.Value
    if ($type -eq "DWord" -or $type -eq "QWord") { $val = [int64]$val }
    New-ItemProperty -Path $path -Name $name -Value $val -PropertyType $type -Force | Out-Null
}

function Restore-Reclaim11RegSnapshot {
    param($Snap)
    $path = [string]$Snap.path
    $name = [string]$Snap.name
    if (-not [bool]$Snap.present) {
        if (Test-Path -LiteralPath $path) {
            Remove-ItemProperty -LiteralPath $path -Name $name -ErrorAction SilentlyContinue
        }
        return
    }
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -Path $path -Force | Out-Null
    }
    $kind = [string]$Snap.kind
    if ([string]::IsNullOrWhiteSpace($kind)) { $kind = "DWord" }
    New-ItemProperty -Path $path -Name $name -Value $Snap.value -PropertyType $kind -Force | Out-Null
}

function Convert-Reclaim11ServiceStart {
    param([string]$StartupType)
    switch -Regex ($StartupType) {
        "^(?i)disabled$" { return 4 }
        "^(?i)manual|demand$" { return 3 }
        "^(?i)automatic|auto$" { return 2 }
        default { throw "Convert-Reclaim11ServiceStart: $StartupType" }
    }
}

function Invoke-Reclaim11TelemetryRegRoundtrip {
    param(
        $Entries,
        $Remove,
        [hashtable]$Bag
    )
    $before = @()
    foreach ($e in @($Entries)) {
        $k = ([string]$e.Path) + "|" + ([string]$e.Name)
        $present = $Bag.ContainsKey($k)
        $before += [pscustomobject]@{
            path    = [string]$e.Path
            name    = [string]$e.Name
            present = $present
            value   = if ($present) { $Bag[$k] } else { $null }
        }
        $Bag[$k] = [string]$e.Value
    }
    foreach ($e in @($Remove)) {
        $k = ([string]$e.Path) + "|" + ([string]$e.Name)
        $present = $Bag.ContainsKey($k)
        $before += [pscustomobject]@{
            path    = [string]$e.Path
            name    = [string]$e.Name
            present = $present
            value   = if ($present) { $Bag[$k] } else { $null }
            remove  = $true
        }
        if ($present) { [void]$Bag.Remove($k) }
    }
    [pscustomobject]@{ before = @($before); bag = $Bag }
}

function Restore-Reclaim11TelemetryRegRoundtrip {
    param($Before, [hashtable]$Bag)
    foreach ($s in @($Before)) {
        $k = ([string]$s.path) + "|" + ([string]$s.name)
        if ([bool]$s.present) { $Bag[$k] = $s.value }
        elseif ($Bag.ContainsKey($k)) { [void]$Bag.Remove($k) }
    }
    $Bag
}

function Write-Reclaim11TelemetryManifest {
    param($Manifest, [string]$Path)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    ($Manifest | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-Reclaim11TelemetryCleanse {
    param(
        [string]$Root,
        [switch]$WhatIf,
        [string]$Config = ""
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

    $picked = "WPFTweaksTelemetry"
    if (-not [string]::IsNullOrWhiteSpace($Config)) {
        $imp = Test-Reclaim11CttImport -Root $Root -Config $Config
        if (@($imp.ids) -notcontains "WPFTweaksTelemetry") {
            throw "Refuse: imported config has no WPFTweaksTelemetry"
        }
        $picked = "WPFTweaksTelemetry"
    }
    $tweak = Get-Reclaim11CttTweak -Root $Root -Id $picked
    $skip = @()
    if ($tweak.PSObject.Properties["skip"]) { $skip = @($tweak.skip) }
    if ($skip -notcontains "Set-MpPreference") {
        throw "Refuse: telemetry spec must skip Set-MpPreference"
    }

    $svcNames = @()
    foreach ($s in @($tweak.service)) { $svcNames += [string]$s.Name }
    $never = @($cat.never_touch_services)
    foreach ($s in $svcNames) {
        if ($never -contains $s) { throw "Refuse: telemetry list collides never-touch $s" }
        if ($s -ieq "BFE" -or $s -ieq "mpssvc" -or $s -ieq "FltMgr" -or $s -ieq "EventLog") {
            throw "Refuse: telemetry list hits $s"
        }
    }

    if (Test-Reclaim11TelemetryDeskHost) {
        throw "Refuse: desk (IoTEnterpriseS). Telemetry cleanse is VM-only. Not M1ABRAMS."
    }

    $regSnap = @()
    foreach ($e in @($tweak.registry)) {
        $regSnap += Get-Reclaim11RegSnapshot -Path ([string]$e.Path) -Name ([string]$e.Name)
    }
    $removeSnap = @()
    foreach ($e in @($tweak.remove_value)) {
        $removeSnap += Get-Reclaim11RegSnapshot -Path ([string]$e.Path) -Name ([string]$e.Name)
    }
    $svcSnap = @()
    foreach ($s in @($tweak.service)) {
        $name = [string]$s.Name
        $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$name"
        $start = $null
        $present = Test-Path -LiteralPath $key
        if ($present) {
            $p = Get-ItemProperty -LiteralPath $key
            if ($p.PSObject.Properties["Start"]) { $start = [int]$p.Start }
        }
        $svcSnap += [pscustomobject]@{
            name             = $name
            present          = $present
            start            = $start
            wanted_start     = Convert-Reclaim11ServiceStart -StartupType ([string]$s.StartupType)
            original_type    = [string]$s.OriginalType
        }
    }
    $envSnap = @()
    foreach ($e in @($tweak.env_machine)) {
        $n = [string]$e.Name
        $cur = [Environment]::GetEnvironmentVariable($n, "Machine")
        $envSnap += [pscustomobject]@{
            name    = $n
            present = ($null -ne $cur)
            value   = $cur
            wanted  = [string]$e.Value
        }
    }

    $stamp = [datetime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
    $backupRoot = Join-Path $env:SystemDrive.TrimEnd("\") ("reclaim11\backup\" + $stamp)
    $manPath = Join-Path $backupRoot "restore.json"
    $manifest = [pscustomobject]@{
        id           = "reclaim11-telemetry-v1"
        ctt_id       = "WPFTweaksTelemetry"
        at           = [datetime]::UtcNow.ToString("o")
        skip         = @($skip)
        registry     = @($regSnap)
        remove_value = @($removeSnap)
        services     = @($svcSnap)
        env_machine  = @($envSnap)
        backup_root  = $backupRoot
        note         = "Restore with pwsh -File telemetry_cleanse.ps1 -Restore restore.json. Never Set-MpPreference."
    }

    if ($WhatIf) {
        $manifest | Add-Member -NotePropertyName what_if -NotePropertyValue $true
        $manifest | Add-Member -NotePropertyName manifest_path -NotePropertyValue $manPath
        return $manifest
    }

    Write-Reclaim11TelemetryManifest -Manifest $manifest -Path $manPath

    foreach ($e in @($tweak.registry)) {
        Set-Reclaim11RegEntry -Entry $e
    }
    foreach ($e in @($tweak.remove_value)) {
        $path = [string]$e.Path
        $name = [string]$e.Name
        if (Test-Path -LiteralPath $path) {
            Remove-ItemProperty -LiteralPath $path -Name $name -ErrorAction SilentlyContinue
        }
    }
    foreach ($s in @($svcSnap)) {
        if (-not [bool]$s.present) { continue }
        $name = [string]$s.name
        sc.exe stop $name 2>&1 | Out-Null
        sc.exe config $name start= disabled 2>&1 | Out-Null
    }
    foreach ($e in @($envSnap)) {
        [Environment]::SetEnvironmentVariable([string]$e.name, [string]$e.wanted, "Machine")
    }

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
    foreach ($s in @($m.registry)) { Restore-Reclaim11RegSnapshot -Snap $s; $restored += ("reg:" + $s.name) }
    foreach ($s in @($m.remove_value)) { Restore-Reclaim11RegSnapshot -Snap $s; $restored += ("reg:" + $s.name) }
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
    foreach ($e in @($m.env_machine)) {
        $n = [string]$e.name
        if ([bool]$e.present) {
            [Environment]::SetEnvironmentVariable($n, [string]$e.value, "Machine")
        } else {
            [Environment]::SetEnvironmentVariable($n, $null, "Machine")
        }
        $restored += ("env:" + $n)
    }
    [pscustomobject]@{ manifest = $Manifest; restored = @($restored) }
}

if ($MyInvocation.InvocationName -ne ".") {
    if (-not [string]::IsNullOrWhiteSpace($Restore)) {
        Restore-Reclaim11TelemetryBackup -Manifest $Restore | ConvertTo-Json -Depth 6
    } else {
        $plan = Invoke-Reclaim11TelemetryCleanse -WhatIf:$WhatIf -Config $Config
        $plan | ConvertTo-Json -Depth 8
        if ($plan.manifest_path) {
            Write-Host ("restore.json {0}" -f $plan.manifest_path)
        }
    }
}
