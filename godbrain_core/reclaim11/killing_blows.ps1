# Pack-A killing blows after a valid WinPE receipt. Never BFE / mpssvc / FltMgr.
# Desk (IoTEnterpriseS) is refused. Not Heal. Not a live wipe of the host.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-Reclaim11Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal $id
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-Reclaim11DeskHost {
    $n = Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
    [string]$n.EditionID -eq "IoTEnterpriseS"
}

function Get-Reclaim11KillingStub {
    param($Catalog)
    $cands = @(
        (Join-Path $env:SystemRoot "reclaim11-stub.exe"),
        [string]$Catalog.stub_exe,
        (Join-Path ${env:ProgramFiles} "Windows Defender\MsMpEng.exe")
    )
    foreach ($c in $cands) {
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        if (Test-Path -LiteralPath $c) { return (Get-Item -LiteralPath $c).FullName }
    }
    $null
}

function Invoke-Reclaim11KillingBlows {
    param(
        [string]$Root,
        [switch]$WhatIf
    )
    if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSCommandPath }
    $invPath = Join-Path $Root "inventory.ps1"
    if (-not (Test-Path -LiteralPath $invPath)) { throw "Invoke-Reclaim11KillingBlows: missing inventory.ps1" }
    . $invPath
    $cat = Get-Reclaim11Catalog -Root $Root

    foreach ($s in @($cat.services_pack_a)) {
        if (@($cat.never_touch_services) -contains $s) {
            throw "Invoke-Reclaim11KillingBlows: pack A lists never-touch $s"
        }
    }
    if (Test-Reclaim11DeskHost) {
        throw "Refuse: desk (IoTEnterpriseS). Killing blows are VM-only. Not M1ABRAMS."
    }
    $el = Join-Path $Root "elevate.ps1"
    if ((-not $WhatIf) -and (Test-Path -LiteralPath $el)) {
        . $el
        $door = Join-Path $Root "Apply-KillingBlows.ps1"
        $hop = Invoke-Reclaim11AsTrustedInstaller -File $door -TimeoutSec 120
        if (-not $hop.continue) {
            if ([int]$hop.exit_code -ne 0) {
                throw ("TI killing blows exit {0}`n{1}" -f $hop.exit_code, $hop.output)
            }
            try { return ($hop.output | ConvertFrom-Json) } catch { return $hop.output }
        }
    }
    if (-not (Test-Reclaim11Admin)) {
        throw "Invoke-Reclaim11KillingBlows: needs elevation"
    }
    $receipt = Get-Reclaim11WinPeReceipt
    if (-not $receipt) {
        throw "Refuse: no WinPE receipt. Boot the Reclaim11 WinPE v7 ISO first."
    }
    $wd = Join-Path $env:SystemRoot "System32\drivers\WdFilter.sys"
    if (Test-Path -LiteralPath $wd) {
        throw "Refuse: WdFilter.sys still present. PE park did not land."
    }
    $inv = Get-Reclaim11Inventory -Root $Root
    if (-not $inv.never_touch_ok) {
        throw "Refuse: BFE/mpssvc not RUNNING. Never-touch failed."
    }
    $stub = Get-Reclaim11KillingStub -Catalog $cat
    if (-not $stub) {
        throw "Refuse: no reclaim11-stub.exe on this volume (PE should have copied it)."
    }

    $plan = [pscustomobject]@{
        receipt     = $receipt
        stub        = $stub
        ifeo        = @($cat.usermode_ifeo)
        services    = @($cat.services_pack_a)
        never_touch = @($cat.never_touch_services)
        what_if     = [bool]$WhatIf
        applied     = @()
        failed      = @()
    }
    if ($WhatIf) { return $plan }

    $applied = New-Object System.Collections.Generic.List[string]
    $failed = New-Object System.Collections.Generic.List[string]

    $pol = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender"
    if (-not (Test-Path -LiteralPath $pol)) {
        New-Item -Path $pol -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $pol -Name DisableAntiSpyware -Value 1 -Type DWord
    [void]$applied.Add("policy:DisableAntiSpyware=1")

    foreach ($svc in @($cat.services_pack_a)) {
        if (@($cat.never_touch_services) -contains $svc) {
            throw "Refuse: attempted never-touch $svc"
        }
        & sc.exe stop $svc | Out-Null
        & sc.exe config $svc start= disabled | Out-Null
        & sc.exe delete $svc | Out-Null
        [void]$applied.Add("sc:$svc")
    }

    foreach ($img in @($cat.usermode_ifeo)) {
        if ($img -eq "mscoree.dll") { throw "Refuse: never IFEO mscoree.dll" }
        $key = "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$img"
        & reg.exe add $key /v Debugger /t REG_SZ /d $stub /f | Out-Null
        if ($LASTEXITCODE -eq 0) {
            [void]$applied.Add("ifeo:$img")
        } else {
            [void]$failed.Add("ifeo:$img")
        }
    }
    $plan | Add-Member -NotePropertyName failed -NotePropertyValue @($failed) -Force

    $plan.applied = @($applied)
    $plan
}
