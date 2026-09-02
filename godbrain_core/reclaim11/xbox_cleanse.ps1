# Hide Xbox Game Bar in Settings and sc-delete Xbox usermode services.
# Matches this desk: Captures + Game Mode stay. Never xboxgip (controller).
# Never BFE / mpssvc / FltMgr. Desk (IoTEnterpriseS) refused. Not DISM.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:XboxHidePages = @(
    "gaming-gamebar",
    "gaming-gamedvr",
    "gaming-trueplay",
    "gaming-broadcasting"
)

$script:XboxKeepPages = @(
    "gaming-gamemode",
    "gaming-captures"
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

$script:XboxAppx = @(
    "Microsoft.XboxGamingOverlay",
    "Microsoft.XboxGameOverlay",
    "Microsoft.XboxIdentityProvider",
    "Microsoft.XboxSpeechToTextOverlay",
    "Microsoft.XboxApp",
    "Microsoft.GamingApp",
    "Microsoft.Xbox.TCUI"
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
                throw "Merge-Reclaim11HidePages: refuse hide $leaf (Captures/Game Mode stay)"
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

function Invoke-Reclaim11XboxCleanse {
    param(
        [string]$Root,
        [switch]$WhatIf
    )
    if ([string]::IsNullOrWhiteSpace($Root)) {
        $Root = Split-Path -Parent $PSCommandPath
    }
    $invPath = Join-Path $Root "inventory.ps1"
    . $invPath
    $cat = Get-Reclaim11Catalog -Root $Root
    foreach ($s in @(Get-Reclaim11XboxServiceCandidates)) {
        if (@($cat.never_touch_services) -contains $s) {
            throw "Refuse: Xbox list collides never-touch $s"
        }
        foreach ($n in $script:XboxNeverDelete) {
            if ($s -ieq $n) { throw "Refuse: Xbox list includes controller driver $s" }
        }
    }
    if (Test-Reclaim11DeskHost) {
        throw "Refuse: desk (IoTEnterpriseS). Xbox hide is VM-only. Not M1ABRAMS."
    }

    $pol = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"
    $cur = ""
    if (Test-Path -LiteralPath $pol) {
        $cur = [string](Get-ItemProperty -LiteralPath $pol -ErrorAction SilentlyContinue).SettingsPageVisibility
    }
    $merged = Merge-Reclaim11HidePages -Current $cur -Hide $script:XboxHidePages

    $deleted = @()
    $removedAppx = @()
    if ($WhatIf) {
        return [pscustomobject]@{
            id           = "reclaim11-xbox-hide-v1"
            what_if      = $true
            hide_pages   = $merged
            services     = @(Get-Reclaim11XboxServiceCandidates)
            appx         = @($script:XboxAppx)
            keep_pages   = @($script:XboxKeepPages)
            skip_driver  = @($script:XboxNeverDelete)
        }
    }

    if (-not (Test-Path -LiteralPath $pol)) {
        New-Item -Path $pol -Force | Out-Null
    }
    New-ItemProperty -Path $pol -Name SettingsPageVisibility -Value $merged -PropertyType String -Force | Out-Null

    $gpo = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR"
    if (-not (Test-Path -LiteralPath $gpo)) { New-Item -Path $gpo -Force | Out-Null }
    New-ItemProperty -Path $gpo -Name AllowGameDVR -Value 0 -PropertyType DWord -Force | Out-Null

    $gb = "HKCU:\Software\Microsoft\GameBar"
    if (-not (Test-Path -LiteralPath $gb)) { New-Item -Path $gb -Force | Out-Null }
    New-ItemProperty -Path $gb -Name UseNexusForGameBarEnabled -Value 0 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $gb -Name GamepadNexusChordEnabled -Value 0 -PropertyType DWord -Force | Out-Null

    foreach ($svc in @(Get-Reclaim11XboxServiceCandidates)) {
        if (@($cat.never_touch_services) -contains $svc) { continue }
        if (@($script:XboxNeverDelete) -contains $svc) { continue }
        $q = sc.exe query $svc 2>&1 | Out-String
        if ($q -match "FAILED 1060") { continue }
        sc.exe stop $svc 2>&1 | Out-Null
        sc.exe delete $svc 2>&1 | Out-Null
        $deleted += $svc
    }

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
                } catch {
                    # in use / store lock
                }
            }
        }
    }

    [pscustomobject]@{
        id          = "reclaim11-xbox-hide-v1"
        hide_pages  = $merged
        sc_delete   = @($deleted)
        appx        = @($removedAppx)
        keep_pages  = @($script:XboxKeepPages)
        skip_driver = @($script:XboxNeverDelete)
        note        = "Settings hide only. Captures + Game Mode stay. xboxgip (controller) stays. XboxGameCallableUI stays."
    }
}

# -File runs. Dot-source (GUI / Test-Reclaim11) only loads functions.
if ($MyInvocation.InvocationName -ne ".") {
    $plan = Invoke-Reclaim11XboxCleanse
    $plan | ConvertTo-Json -Depth 6
    Write-Host ("xbox hide pages={0} sc_delete={1}" -f $plan.hide_pages, @($plan.sc_delete).Count)
}
