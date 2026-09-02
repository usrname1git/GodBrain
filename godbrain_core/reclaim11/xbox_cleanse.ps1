# Hide Xbox Game Bar in Settings, sc-delete Xbox usermode services,
# remove the Appx bloat list. Writes restore.json first (Safe-cleanse style).
# Game Mode stays. Captures hidden (OBS / ShadowPlay / AMD). Never xboxgip. Never XboxGameCallableUI.
# Never BFE / mpssvc / FltMgr. Desk (IoTEnterpriseS) refused.
# Provisioned Appx remove is the old script's Store-seed wipe (VM-only).

[CmdletBinding()]
param(
    [string]$Restore = "",
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:XboxHidePages = @(
    "gaming-gamebar",
    "gaming-gamedvr",
    "gaming-trueplay",
    "gaming-broadcasting",
    "gaming-captures"
)

$script:XboxKeepPages = @(
    "gaming-gamemode"
)

$script:XboxServices = @(
    "XblAuthManager",
    "XblGameSave",
    "XboxNetApiSvc",
    "XboxGipSvc",
    "GamingServices"
)

$script:XboxNeverDelete = @(
    "xboxgip"
)

function Test-Reclaim11XboxDeskHost {
    $n = Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
    [string]$n.EditionID -eq "IoTEnterpriseS"
}

# Old Appx list + remaining Xbox overlays. Not XboxGameCallableUI (desk kept it).
$script:XboxAppx = @(
    "Microsoft.3DBuilder",
    "Microsoft.XboxGameOverlay",
    "Microsoft.Xbox.TCUI",
    "Microsoft.XboxApp",
    "Microsoft.XboxGamingOverlay",
    "Microsoft.XboxIdentityProvider",
    "Microsoft.XboxSpeechToTextOverlay",
    "Microsoft.BingNews",
    "Microsoft.GetHelp",
    "Microsoft.Getstarted",
    "Microsoft.Microsoft3DViewer",
    "Microsoft.MicrosoftOfficeHub",
    "Microsoft.MicrosoftSolitaireCollection",
    "Microsoft.MSPaint",
    "Microsoft.SkypeApp",
    "Microsoft.ZuneMusic",
    "Microsoft.ZuneVideo",
    "Microsoft.People",
    "Microsoft.MicrosoftStickyNotes",
    "Microsoft.MixedReality.Portal",
    "Microsoft.WindowsMaps",
    "Microsoft.YourPhone",
    "Microsoft.OneConnect",
    "Microsoft.WindowsFeedbackHub",
    "Microsoft.GamingApp"
)

function Merge-Reclaim11HidePages {
    param(
        [string]$Current = "",
        [string[]]$Hide
    )
    $parts = @()
    $seen = @{}
    if (-not [string]::IsNullOrWhiteSpace($Current)) {
        foreach ($t in ($Current -split ";")) {
            $t = $t.Trim()
            if ([string]::IsNullOrWhiteSpace($t)) { continue }
            $key = $t.ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $parts += $t
        }
    }
    foreach ($h in $Hide) {
        if ([string]::IsNullOrWhiteSpace($h)) { continue }
        $leaf = $h.Trim()
        foreach ($keep in $script:XboxKeepPages) {
            if ($leaf -ieq $keep) {
                throw "Merge-Reclaim11HidePages: refuse hide $leaf (Game Mode stays)"
            }
        }
        $tok = if ($leaf -like "hide:*") { $leaf } else { "hide:$leaf" }
        $key = $tok.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $parts += $tok
    }
    ($parts -join ";")
}

function Get-Reclaim11XboxServiceCandidates {
    $names = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    foreach ($s in $script:XboxServices) { [void]$names.Add($s) }
    $svcRoot = "HKLM:\SYSTEM\CurrentControlSet\Services"
    if (Test-Path -LiteralPath $svcRoot) {
        Get-ChildItem -LiteralPath $svcRoot -ErrorAction SilentlyContinue | Where-Object {
            $_.PSChildName -like "BcastDVRUserService*"
        } | ForEach-Object { [void]$names.Add($_.PSChildName) }
    }
    @($names)
}

function Get-Reclaim11ServiceSnapshot {
    param([string]$Name)
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    if (-not (Test-Path -LiteralPath $key)) { return $null }
    $p = Get-ItemProperty -LiteralPath $key
    $start = $null
    if ($p.PSObject.Properties["Start"]) { $start = [int]$p.Start }
    [pscustomobject]@{
        name         = $Name
        start        = $start
        image_path   = [string]$p.ImagePath
        display_name = [string]$p.DisplayName
        object_name  = [string]$p.ObjectName
        type         = $p.Type
    }
}

function Get-Reclaim11AppxSnapshot {
    param([string]$Name)
    $rows = @()
    $pkgs = @(Get-AppxPackage -AllUsers -Name $Name -ErrorAction SilentlyContinue)
    foreach ($p in $pkgs) {
        $rows += [pscustomobject]@{
            name               = [string]$p.Name
            package_full_name  = [string]$p.PackageFullName
            install_location   = [string]$p.InstallLocation
            provisioned        = $false
        }
    }
    try {
        $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $Name })
        foreach ($p in $prov) {
            $rows += [pscustomobject]@{
                name               = [string]$p.DisplayName
                package_full_name  = [string]$p.PackageName
                install_location   = [string]$p.InstallLocation
                provisioned        = $true
            }
        }
    } catch {
        # no DISM / not elevated
    }
    $rows
}

function Write-Reclaim11XboxManifest {
    param($Manifest, [string]$Path)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    ($Manifest | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-Reclaim11XboxCleanse {
    param(
        [string]$Root,
        [switch]$WhatIf,
        [switch]$KeepCaptures
    )
    if ([string]::IsNullOrWhiteSpace($Root)) {
        if ($PSScriptRoot) { $Root = $PSScriptRoot }
        else { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
    }
    $invPath = Join-Path $Root "inventory.ps1"
    if (Test-Path -LiteralPath $invPath) {
        . $invPath
    }
    $catPath = Join-Path $Root "catalog.json"
    if (Get-Command Get-Reclaim11Catalog -ErrorAction SilentlyContinue) {
        $cat = Get-Reclaim11Catalog -Root $Root
    } elseif (Test-Path -LiteralPath $catPath) {
        $cat = Get-Content -LiteralPath $catPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } else {
        throw "xbox_cleanse: missing $invPath and $catPath (copy the whole reclaim11 folder, not just this file)"
    }
    foreach ($s in @(Get-Reclaim11XboxServiceCandidates)) {
        if (@($cat.never_touch_services) -contains $s) {
            throw "Refuse: Xbox list collides never-touch $s"
        }
        foreach ($n in $script:XboxNeverDelete) {
            if ($s -ieq $n) { throw "Refuse: Xbox list includes controller driver $s" }
        }
    }
    if ($script:XboxAppx -contains "Microsoft.XboxGameCallableUI") {
        throw "Refuse: XboxGameCallableUI stays (desk kept it)"
    }
    if (Test-Reclaim11XboxDeskHost) {
        throw "Refuse: desk (IoTEnterpriseS). Xbox hide is VM-only. Not M1ABRAMS."
    }
    if (-not $WhatIf) {
        $el = Join-Path $Root "elevate.ps1"
        if (Test-Path -LiteralPath $el) {
            . $el
            $self = Join-Path $Root "xbox_cleanse.ps1"
            $hop = Invoke-Reclaim11AsTrustedInstaller -File $self -TimeoutSec 180
            if (-not $hop.continue) {
                if ([int]$hop.exit_code -ne 0) {
                    throw ("TI xbox_cleanse exit {0}`n{1}" -f $hop.exit_code, $hop.output)
                }
                try { return ($hop.output | ConvertFrom-Json) } catch { return $hop.output }
            }
        }
    }

    $pol = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"
    $cur = ""
    if (Test-Path -LiteralPath $pol) {
        $cur = [string](Get-ItemProperty -LiteralPath $pol -ErrorAction SilentlyContinue).SettingsPageVisibility
    }
    $hide = @($script:XboxHidePages)
    if ($KeepCaptures) {
        $hide = @($hide | Where-Object { $_ -ne "gaming-captures" })
    }
    $merged = Merge-Reclaim11HidePages -Current $cur -Hide $hide

    $gpo = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR"
    $gpoBefore = $null
    if (Test-Path -LiteralPath $gpo) {
        $gp = Get-ItemProperty -LiteralPath $gpo -ErrorAction SilentlyContinue
        if ($gp -and $gp.PSObject.Properties["AllowGameDVR"]) { $gpoBefore = [int]$gp.AllowGameDVR }
    }
    $gb = "HKCU:\Software\Microsoft\GameBar"
    $nexusBefore = $null
    $chordBefore = $null
    if (Test-Path -LiteralPath $gb) {
        $gbi = Get-ItemProperty -LiteralPath $gb -ErrorAction SilentlyContinue
        if ($gbi.PSObject.Properties["UseNexusForGameBarEnabled"]) { $nexusBefore = [int]$gbi.UseNexusForGameBarEnabled }
        if ($gbi.PSObject.Properties["GamepadNexusChordEnabled"]) { $chordBefore = [int]$gbi.GamepadNexusChordEnabled }
    }

    $svcSnap = @()
    foreach ($svc in @(Get-Reclaim11XboxServiceCandidates)) {
        if (@($script:XboxNeverDelete) -contains $svc) { continue }
        $shot = Get-Reclaim11ServiceSnapshot -Name $svc
        if ($shot) { $svcSnap += $shot }
    }
    $appxSnap = @()
    foreach ($n in $script:XboxAppx) {
        foreach ($row in @(Get-Reclaim11AppxSnapshot -Name $n)) {
            $appxSnap += $row
        }
    }

    $stamp = [datetime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
    $backupRoot = Join-Path $env:SystemDrive.TrimEnd("\") ("reclaim11\backup\" + $stamp)
    $manPath = Join-Path $backupRoot "restore.json"
    $manifest = [pscustomobject]@{
        id                         = "reclaim11-xbox-v1"
        at                         = [datetime]::UtcNow.ToString("o")
        settings_page_visibility   = [pscustomobject]@{ before = $cur; after = $merged }
        gamedvr_allow              = $gpoBefore
        gamebar_nexus              = $nexusBefore
        gamebar_chord              = $chordBefore
        services                   = $svcSnap
        appx                       = $appxSnap
        keep_pages                 = @($script:XboxKeepPages)
        skip_driver                = @($script:XboxNeverDelete)
        backup_root                = $backupRoot
        note                       = "Restore with pwsh -File xbox_cleanse.ps1 -Restore restore.json. Game Mode stays. xboxgip stays."
    }

    if ($WhatIf) {
        $manifest | Add-Member -NotePropertyName what_if -NotePropertyValue $true
        $manifest | Add-Member -NotePropertyName manifest_path -NotePropertyValue $manPath
        return $manifest
    }

    Write-Reclaim11XboxManifest -Manifest $manifest -Path $manPath

    if (-not (Test-Path -LiteralPath $pol)) {
        New-Item -Path $pol -Force | Out-Null
    }
    New-ItemProperty -Path $pol -Name SettingsPageVisibility -Value $merged -PropertyType String -Force | Out-Null

    if (-not (Test-Path -LiteralPath $gpo)) { New-Item -Path $gpo -Force | Out-Null }
    New-ItemProperty -Path $gpo -Name AllowGameDVR -Value 0 -PropertyType DWord -Force | Out-Null

    if (-not (Test-Path -LiteralPath $gb)) { New-Item -Path $gb -Force | Out-Null }
    New-ItemProperty -Path $gb -Name UseNexusForGameBarEnabled -Value 0 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $gb -Name GamepadNexusChordEnabled -Value 0 -PropertyType DWord -Force | Out-Null

    $deleted = @()
    foreach ($svc in @(Get-Reclaim11XboxServiceCandidates)) {
        if (@($cat.never_touch_services) -contains $svc) { continue }
        if (@($script:XboxNeverDelete) -contains $svc) { continue }
        $q = sc.exe query $svc 2>&1 | Out-String
        if ($q -match "FAILED 1060") { continue }
        sc.exe stop $svc 2>&1 | Out-Null
        sc.exe delete $svc 2>&1 | Out-Null
        $deleted += $svc
    }

    $removedAppx = @()
    foreach ($n in $script:XboxAppx) {
        $pkgs = @(Get-AppxPackage -AllUsers -Name $n -ErrorAction SilentlyContinue)
        foreach ($p in $pkgs) {
            try {
                Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop
                $removedAppx += $p.Name
            } catch {
                try {
                    Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop
                    $removedAppx += $p.Name
                } catch { }
            }
        }
        try {
            $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $n })
            foreach ($p in $prov) {
                Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction SilentlyContinue | Out-Null
            }
        } catch { }
    }

    $manifest | Add-Member -NotePropertyName sc_delete -NotePropertyValue $deleted
    $manifest | Add-Member -NotePropertyName appx_removed -NotePropertyValue $removedAppx
    $manifest | Add-Member -NotePropertyName manifest_path -NotePropertyValue $manPath
    Write-Reclaim11XboxManifest -Manifest $manifest -Path $manPath
    $manifest
}

function Restore-Reclaim11XboxBackup {
    param(
        [string]$Manifest,
        [string]$Root
    )
    if ([string]::IsNullOrWhiteSpace($Root)) {
        $Root = Split-Path -Parent $PSCommandPath
    }
    $invPath = Join-Path $Root "inventory.ps1"
    if (Test-Path -LiteralPath $invPath) { . $invPath }
    if (-not (Test-Path -LiteralPath $Manifest)) {
        throw "Restore-Reclaim11XboxBackup: missing $Manifest"
    }
    $m = Get-Content -LiteralPath $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$m.id -notlike "reclaim11-xbox*") {
        throw "Restore-Reclaim11XboxBackup: not an Xbox/debloat manifest"
    }
    if (Test-Reclaim11XboxDeskHost) {
        throw "Refuse: desk (IoTEnterpriseS). Xbox restore is VM-only. Not M1ABRAMS."
    }
    $restored = @()

    $pol = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"
    if (-not (Test-Path -LiteralPath $pol)) { New-Item -Path $pol -Force | Out-Null }
    $before = [string]$m.settings_page_visibility.before
    New-ItemProperty -Path $pol -Name SettingsPageVisibility -Value $before -PropertyType String -Force | Out-Null
    $restored += "SettingsPageVisibility"

    $gpo = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR"
    if ($null -ne $m.gamedvr_allow -and $m.gamedvr_allow -ne "") {
        if (-not (Test-Path -LiteralPath $gpo)) { New-Item -Path $gpo -Force | Out-Null }
        New-ItemProperty -Path $gpo -Name AllowGameDVR -Value ([int]$m.gamedvr_allow) -PropertyType DWord -Force | Out-Null
        $restored += "AllowGameDVR"
    }
    $gb = "HKCU:\Software\Microsoft\GameBar"
    if (-not (Test-Path -LiteralPath $gb)) { New-Item -Path $gb -Force | Out-Null }
    if ($null -ne $m.gamebar_nexus -and $m.gamebar_nexus -ne "") {
        New-ItemProperty -Path $gb -Name UseNexusForGameBarEnabled -Value ([int]$m.gamebar_nexus) -PropertyType DWord -Force | Out-Null
    }
    if ($null -ne $m.gamebar_chord -and $m.gamebar_chord -ne "") {
        New-ItemProperty -Path $gb -Name GamepadNexusChordEnabled -Value ([int]$m.gamebar_chord) -PropertyType DWord -Force | Out-Null
    }

    foreach ($s in @($m.services)) {
        $name = [string]$s.name
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if (@("xboxgip") -contains $name) { continue }
        $bin = [string]$s.image_path
        if ([string]::IsNullOrWhiteSpace($bin)) { continue }
        $q = sc.exe query $name 2>&1 | Out-String
        if ($q -notmatch "FAILED 1060") { continue }
        $start = "demand"
        if ([int]$s.start -eq 2) { $start = "auto" }
        if ([int]$s.start -eq 4) { $start = "disabled" }
        & sc.exe create $name binPath= $bin start= $start | Out-Null
        $restored += ("service:" + $name)
    }

    foreach ($a in @($m.appx)) {
        $loc = [string]$a.install_location
        if ([string]::IsNullOrWhiteSpace($loc)) { continue }
        $manifestXml = Join-Path $loc "AppxManifest.xml"
        if (-not (Test-Path -LiteralPath $manifestXml)) { continue }
        try {
            Add-AppxPackage -DisableDevelopmentMode -Register $manifestXml -ErrorAction Stop
            $restored += ("appx:" + [string]$a.name)
        } catch { }
    }

    [pscustomobject]@{ manifest = $Manifest; restored = $restored }
}

# -File runs. Dot-source (GUI / Test-Reclaim11) only loads functions.
if ($MyInvocation.InvocationName -ne ".") {
    if (-not [string]::IsNullOrWhiteSpace($Restore)) {
        Restore-Reclaim11XboxBackup -Manifest $Restore | ConvertTo-Json -Depth 6
    } else {
        $plan = Invoke-Reclaim11XboxCleanse -WhatIf:$WhatIf
        $plan | ConvertTo-Json -Depth 8
        if ($plan.manifest_path) {
            Write-Host ("restore.json {0}" -f $plan.manifest_path)
        }
    }
}
