# Hide Xbox Game Bar in Settings, sc-delete Xbox usermode services,
# remove the Appx bloat list. Writes restore.json first (Safe-cleanse style).
# Game Mode stays. Captures hidden (OBS / ShadowPlay / AMD). Never xboxgip. Never XboxGameCallableUI.
# Never BFE / mpssvc / FltMgr. Desk (IoTEnterpriseS) refused.
# Provisioned Appx remove is the old script's Store-seed wipe (VM-only).

[CmdletBinding()]
param(
    [string]$Restore = "",
    [Alias("T", "Test")]
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:Reclaim11Here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$invBoot = Join-Path $script:Reclaim11Here "inventory.ps1"
if (Test-Path -LiteralPath $invBoot) { . $invBoot }

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

# GameBar.reg juice. Never AllowAutoGameMode / AutoGameModeEnabled (Game Mode stays).
$script:XboxGameBarOff = @(
    @{ Name = "UseNexusForGameBarEnabled"; Value = 0 },
    @{ Name = "GamepadNexusChordEnabled"; Value = 0 },
    @{ Name = "ShowStartupPanel"; Value = 0 },
    @{ Name = "EnableGameBar"; Value = 0 },
    @{ Name = "ShowBroadcastPanel"; Value = 0 },
    @{ Name = "GamePanelStartupTipIndex"; Value = 3 }
)

$script:XboxGameBarNever = @(
    "AllowAutoGameMode",
    "AutoGameModeEnabled"
)

function Get-Reclaim11OptionalDword {
    param($Object, [string]$Name)
    if ($Object -and $Object.PSObject.Properties[$Name]) { return [int]$Object.$Name }
    $null
}

function Get-Reclaim11OptionalText {
    param($Object, [string]$Name)
    if ($Object -and $Object.PSObject.Properties[$Name]) { return [string]$Object.$Name }
    $null
}

function Get-Reclaim11SettingsPageVisibility {
    param([string]$HivePath)
    if (-not (Test-Path -LiteralPath $HivePath)) { return "" }
    $ip = Get-ItemProperty -LiteralPath $HivePath -ErrorAction SilentlyContinue
    Get-Reclaim11OptionalText -Object $ip -Name "SettingsPageVisibility"
}

function Set-Reclaim11SettingsPageVisibility {
    param([string]$HivePath, [string]$Value)
    if (-not (Test-Path -LiteralPath $HivePath)) {
        New-Item -Path $HivePath -Force | Out-Null
    }
    New-ItemProperty -Path $HivePath -Name SettingsPageVisibility -Value $Value -PropertyType String -Force | Out-Null
}

function Restart-Reclaim11SettingsApp {
    foreach ($n in @("SystemSettings", "ApplicationFrameHost")) {
        Get-Process -Name $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

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
    "Microsoft.GamingApp",
    "Microsoft.GamingServices"
)

function Get-Reclaim11HidePageIds {
    param([string]$Current = "")
    $ids = @()
    if ([string]::IsNullOrWhiteSpace($Current)) { return $ids }
    $s = $Current.Trim()
    if ($s.StartsWith("hide:", [StringComparison]::OrdinalIgnoreCase)) {
        $s = $s.Substring(5)
    } elseif ($s.StartsWith("showonly:", [StringComparison]::OrdinalIgnoreCase)) {
        $s = $s.Substring(9)
    }
    foreach ($t in ($s -split ";")) {
        $t = $t.Trim()
        if ($t.StartsWith("hide:", [StringComparison]::OrdinalIgnoreCase)) {
            $t = $t.Substring(5).Trim()
        }
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        $ids += $t
    }
    $ids
}

function Merge-Reclaim11HidePages {
    param(
        [string]$Current = "",
        [string[]]$Hide
    )
    # GPO format is hide:id1;id2;id3 — NOT hide:id1;hide:id2 (only the first page hid).
    $parts = @()
    $seen = @{}
    foreach ($t in @(Get-Reclaim11HidePageIds -Current $Current)) {
        $key = $t.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $parts += $t
    }
    foreach ($h in $Hide) {
        if ([string]::IsNullOrWhiteSpace($h)) { continue }
        $leaf = $h.Trim()
        if ($leaf.StartsWith("hide:", [StringComparison]::OrdinalIgnoreCase)) {
            $leaf = $leaf.Substring(5).Trim()
        }
        foreach ($keep in $script:XboxKeepPages) {
            if ($leaf -ieq $keep) {
                throw "Merge-Reclaim11HidePages: refuse hide $leaf (Game Mode stays)"
            }
        }
        $key = $leaf.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $parts += $leaf
    }
    if ($parts.Count -lt 1) { return "" }
    "hide:" + ($parts -join ";")
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
    [pscustomobject]@{
        name         = $Name
        start        = Get-Reclaim11OptionalDword -Object $p -Name "Start"
        image_path   = Get-Reclaim11OptionalText -Object $p -Name "ImagePath"
        display_name = Get-Reclaim11OptionalText -Object $p -Name "DisplayName"
        object_name  = Get-Reclaim11OptionalText -Object $p -Name "ObjectName"
        type         = Get-Reclaim11OptionalDword -Object $p -Name "Type"
    }
}

function Get-Reclaim11AppxSnapshot {
    param([string]$Name)
    $rows = @()
    $pkgs = @(Get-AppxPackage -AllUsers -Name $Name -ErrorAction SilentlyContinue)
    foreach ($p in $pkgs) {
        $rows += [pscustomobject]@{
            name               = Get-Reclaim11OptionalText -Object $p -Name "Name"
            package_full_name  = Get-Reclaim11OptionalText -Object $p -Name "PackageFullName"
            install_location   = Get-Reclaim11OptionalText -Object $p -Name "InstallLocation"
            provisioned        = $false
        }
    }
    try {
        $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $Name })
        foreach ($p in $prov) {
            $rows += [pscustomobject]@{
                name               = Get-Reclaim11OptionalText -Object $p -Name "DisplayName"
                package_full_name  = Get-Reclaim11OptionalText -Object $p -Name "PackageName"
                install_location   = Get-Reclaim11OptionalText -Object $p -Name "InstallLocation"
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
    $desk = Test-Reclaim11XboxDeskHost
    if ($desk -and -not $WhatIf) {
        throw "Refuse: desk (IoTEnterpriseS). Xbox hide is VM-only. Not M1ABRAMS."
    }
    $admin = $false
    if (Get-Command Test-Reclaim11Admin -ErrorAction SilentlyContinue) {
        $admin = Test-Reclaim11Admin
    } else {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $admin = (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    }

    $polLm = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"
    $polCu = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"
    $curLm = Get-Reclaim11SettingsPageVisibility -HivePath $polLm
    $curCu = Get-Reclaim11SettingsPageVisibility -HivePath $polCu
    $cur = $curLm
    if ([string]::IsNullOrWhiteSpace($cur)) { $cur = $curCu }
    $hide = @($script:XboxHidePages)
    if ($KeepCaptures) {
        # Captures in Settings is PolicyId gaming-gamedvr (SettingsPageGameDVR).
        # gaming-captures is an extra token; skip both or the page still hides.
        $hide = @($hide | Where-Object {
            $_ -ne "gaming-captures" -and $_ -ne "gaming-gamedvr"
        })
    }
    $merged = Merge-Reclaim11HidePages -Current $cur -Hide $hide

    $gpo = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR"
    $gpoBefore = $null
    if (Test-Path -LiteralPath $gpo) {
        $gp = Get-ItemProperty -LiteralPath $gpo -ErrorAction SilentlyContinue
        if ($gp -and $gp.PSObject.Properties["AllowGameDVR"]) { $gpoBefore = [int]$gp.AllowGameDVR }
    }
    $gb = "HKCU:\Software\Microsoft\GameBar"
    $gbBefore = @()
    $gbi = $null
    if (Test-Path -LiteralPath $gb) {
        $gbi = Get-ItemProperty -LiteralPath $gb -ErrorAction SilentlyContinue
    }
    foreach ($row in $script:XboxGameBarOff) {
        $gbBefore += [pscustomobject]@{
            name    = [string]$row.Name
            present = [bool]($gbi -and $gbi.PSObject.Properties[$row.Name])
            value   = Get-Reclaim11OptionalDword -Object $gbi -Name $row.Name
            wanted  = [int]$row.Value
        }
    }
    $dvr = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"
    $dvrCaptureBefore = $null
    if (Test-Path -LiteralPath $dvr) {
        $dvri = Get-ItemProperty -LiteralPath $dvr -ErrorAction SilentlyContinue
        $dvrCaptureBefore = Get-Reclaim11OptionalDword -Object $dvri -Name "AppCaptureEnabled"
    }
    $overlayKey = "Registry::HKEY_CLASSES_ROOT\ms-gamingoverlay"
    $overlayPresent = Test-Path -LiteralPath $overlayKey

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
        settings_page_visibility   = [pscustomobject]@{
            before    = $cur
            after     = $merged
            before_hkcu = $curCu
        }
        gamedvr_allow              = $gpoBefore
        gamebar                     = @($gbBefore)
        gamedvr_capture            = $dvrCaptureBefore
        ms_gamingoverlay           = $overlayPresent
        services                   = $svcSnap
        appx                       = $appxSnap
        keep_pages                 = @($script:XboxKeepPages)
        skip_driver                = @($script:XboxNeverDelete)
        backup_root                = $backupRoot
        note                       = "Restore with pwsh -File xbox_cleanse.ps1 -Restore restore.json. Game Mode stays. xboxgip stays."
    }

    if ($WhatIf) {
        $checks = @(
            (New-Reclaim11Check -Name "catalog" -Ok $true -Detail $catPath),
            (New-Reclaim11Check -Name "admin" -Ok $admin -Detail "Hide Xbox is admin, not TI"),
            (New-Reclaim11Check -Name "desk" -Ok (-not $desk) -Detail $(if ($desk) { "IoTEnterpriseS would refuse" } else { "not desk SKU" }))
        )
        $would = @()
        $would += ("HKLM+HKCU SettingsPageVisibility -> {0}" -f $merged)
        $would += "kill SystemSettings.exe (explorer restart is not enough)"
        $would += "AllowGameDVR=0"
        foreach ($row in $gbBefore) {
            $would += ("GameBar {0}={1}" -f $row.name, $row.wanted)
        }
        $would += "AppCaptureEnabled=0"
        if ($overlayPresent) { $would += "delete HKCR\\ms-gamingoverlay (export first)" }
        foreach ($s in $svcSnap) { $would += ("sc delete {0}" -f $s.name) }
        $would += "skip xboxgip"
        foreach ($a in $appxSnap) { $would += ("Appx remove {0}" -f $a.name) }
        $refuse = ""
        if ($desk) { $refuse = "desk (IoTEnterpriseS)" }
        elseif (-not $admin) { $refuse = "needs elevation" }
        $manifest | Add-Member -NotePropertyName what_if -NotePropertyValue $true
        $manifest | Add-Member -NotePropertyName mutate -NotePropertyValue $false
        $manifest | Add-Member -NotePropertyName checks -NotePropertyValue $checks
        $manifest | Add-Member -NotePropertyName would -NotePropertyValue $would
        $manifest | Add-Member -NotePropertyName would_refuse -NotePropertyValue $refuse
        $manifest | Add-Member -NotePropertyName manifest_path -NotePropertyValue $manPath
        return $manifest
    }

    Write-Reclaim11XboxManifest -Manifest $manifest -Path $manPath

    Set-Reclaim11SettingsPageVisibility -HivePath $polLm -Value $merged
    Set-Reclaim11SettingsPageVisibility -HivePath $polCu -Value $merged
    Restart-Reclaim11SettingsApp

    if (-not (Test-Path -LiteralPath $gpo)) { New-Item -Path $gpo -Force | Out-Null }
    New-ItemProperty -Path $gpo -Name AllowGameDVR -Value 0 -PropertyType DWord -Force | Out-Null

    if (-not (Test-Path -LiteralPath $gb)) { New-Item -Path $gb -Force | Out-Null }
    foreach ($row in $script:XboxGameBarOff) {
        if ($script:XboxGameBarNever -contains $row.Name) {
            throw "Refuse: Game Mode key $($row.Name) stays"
        }
        New-ItemProperty -Path $gb -Name $row.Name -Value ([int]$row.Value) -PropertyType DWord -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $dvr)) { New-Item -Path $dvr -Force | Out-Null }
    New-ItemProperty -Path $dvr -Name AppCaptureEnabled -Value 0 -PropertyType DWord -Force | Out-Null
    $apiRoot = "HKCU:\Software\Microsoft\GameBarApi"
    if (Test-Path -LiteralPath $apiRoot) {
        $apiItems = @(Get-ChildItem -LiteralPath $apiRoot -Recurse -ErrorAction SilentlyContinue)
        foreach ($it in $apiItems) {
            $ip = Get-ItemProperty -LiteralPath $it.PSPath -ErrorAction SilentlyContinue
            if ($ip -and $ip.PSObject.Properties["Visible"]) {
                New-ItemProperty -Path $it.PSPath -Name Visible -Value 0 -PropertyType DWord -Force | Out-Null
            }
        }
        $apiIn = Join-Path $apiRoot "Input"
        if (-not (Test-Path -LiteralPath $apiIn)) { New-Item -Path $apiIn -Force | Out-Null }
        New-ItemProperty -Path $apiIn -Name InputRedirected -Value 0 -PropertyType DWord -Force | Out-Null
    }
    if ($overlayPresent) {
        $ovBak = Join-Path $backupRoot "ms-gamingoverlay.reg"
        & reg.exe export "HKCR\ms-gamingoverlay" $ovBak /y 2>&1 | Out-Null
        Remove-Item -LiteralPath $overlayKey -Recurse -Force -ErrorAction SilentlyContinue
    }

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

    $polLm = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"
    $polCu = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"
    $beforeLm = [string]$m.settings_page_visibility.before
    Set-Reclaim11SettingsPageVisibility -HivePath $polLm -Value $beforeLm
    $beforeCu = $beforeLm
    if ($m.settings_page_visibility.PSObject.Properties["before_hkcu"]) {
        $beforeCu = [string]$m.settings_page_visibility.before_hkcu
    }
    Set-Reclaim11SettingsPageVisibility -HivePath $polCu -Value $beforeCu
    Restart-Reclaim11SettingsApp
    $restored += "SettingsPageVisibility"

    $gpo = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR"
    if ($null -ne $m.gamedvr_allow -and $m.gamedvr_allow -ne "") {
        if (-not (Test-Path -LiteralPath $gpo)) { New-Item -Path $gpo -Force | Out-Null }
        New-ItemProperty -Path $gpo -Name AllowGameDVR -Value ([int]$m.gamedvr_allow) -PropertyType DWord -Force | Out-Null
        $restored += "AllowGameDVR"
    }
    $gb = "HKCU:\Software\Microsoft\GameBar"
    if (-not (Test-Path -LiteralPath $gb)) { New-Item -Path $gb -Force | Out-Null }
    if ($m.PSObject.Properties["gamebar"]) {
        foreach ($row in @($m.gamebar)) {
            $n = [string]$row.name
            if ($script:XboxGameBarNever -contains $n) { continue }
            if ([bool]$row.present) {
                New-ItemProperty -Path $gb -Name $n -Value ([int]$row.value) -PropertyType DWord -Force | Out-Null
            } else {
                Remove-ItemProperty -LiteralPath $gb -Name $n -ErrorAction SilentlyContinue
            }
        }
    } else {
        if ($null -ne $m.gamebar_nexus -and $m.gamebar_nexus -ne "") {
            New-ItemProperty -Path $gb -Name UseNexusForGameBarEnabled -Value ([int]$m.gamebar_nexus) -PropertyType DWord -Force | Out-Null
        }
        if ($null -ne $m.gamebar_chord -and $m.gamebar_chord -ne "") {
            New-ItemProperty -Path $gb -Name GamepadNexusChordEnabled -Value ([int]$m.gamebar_chord) -PropertyType DWord -Force | Out-Null
        }
        if ($null -ne $m.gamebar_startup -and $m.gamebar_startup -ne "") {
            New-ItemProperty -Path $gb -Name ShowStartupPanel -Value ([int]$m.gamebar_startup) -PropertyType DWord -Force | Out-Null
        }
    }
    if ([bool]$m.ms_gamingoverlay) {
        $ovBak = Join-Path (Split-Path -Parent $Manifest) "ms-gamingoverlay.reg"
        if (Test-Path -LiteralPath $ovBak) {
            & reg.exe import $ovBak 2>&1 | Out-Null
        }
    }
    $dvr = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"
    if ($null -ne $m.gamedvr_capture -and $m.gamedvr_capture -ne "") {
        if (-not (Test-Path -LiteralPath $dvr)) { New-Item -Path $dvr -Force | Out-Null }
        New-ItemProperty -Path $dvr -Name AppCaptureEnabled -Value ([int]$m.gamedvr_capture) -PropertyType DWord -Force | Out-Null
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
        # sc.exe splits unquoted binPath= on -k (svchost ImagePath).
        $escName = $name.Replace('"', '""')
        $escBin = $bin.Replace('"', '""')
        cmd.exe /c "sc.exe create `"$escName`" binPath= `"$escBin`" start= $start" | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $restored += ("service:" + $name)
        }
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
        if ($WhatIf) {
            Write-Host (Format-Reclaim11TestReport -Plan $plan -Title "xbox_cleanse")
        }
        $plan | ConvertTo-Json -Depth 8
        if ((-not $WhatIf) -and $plan.manifest_path) {
            Write-Host ("restore.json {0}" -f $plan.manifest_path)
        }
    }
}
