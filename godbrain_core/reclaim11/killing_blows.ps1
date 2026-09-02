# Pack-A killing blows after a valid WinPE receipt. Never BFE / mpssvc / FltMgr.
# Desk (IoTEnterpriseS) is refused. Not Heal. Not a live wipe of the host.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:Reclaim11Here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$invBoot = Join-Path $script:Reclaim11Here "inventory.ps1"
if (Test-Path -LiteralPath $invBoot) { . $invBoot }

function Test-Reclaim11Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal $id
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-Reclaim11DeskHost {
    $n = Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
    [string]$n.EditionID -eq "IoTEnterpriseS"
}

function Test-Reclaim11PackATaskPath {
    param($Catalog, [string]$Path)
    $p = ([string]$Path).Replace("/", "\").TrimEnd("\")
    if ([string]::IsNullOrWhiteSpace($p)) { return $false }
    foreach ($a in @($Catalog.scheduled_task_paths_pack_a)) {
        $want = ([string]$a).Replace("/", "\").TrimEnd("\")
        if ($p -ieq $want) { return $true }
    }
    $false
}

function Get-Reclaim11PackAScheduledTasks {
    param($Catalog)
    $out = @()
    $tasks = @()
    try { $tasks = @(Get-ScheduledTask -ErrorAction Stop) } catch { return $out }
    foreach ($t in $tasks) {
        if (-not (Test-Reclaim11PackATaskPath -Catalog $Catalog -Path ([string]$t.TaskPath))) { continue }
        $full = ([string]$t.TaskPath).TrimEnd("\") + "\" + [string]$t.TaskName
        $out += [pscustomobject]@{
            path = [string]$t.TaskPath
            name = [string]$t.TaskName
            full = $full
        }
    }
    $out
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
        [Alias("T", "Test")]
        [switch]$WhatIf
    )
    if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSCommandPath }
    $invPath = Join-Path $Root "inventory.ps1"
    if (-not (Test-Path -LiteralPath $invPath)) { throw "Invoke-Reclaim11KillingBlows: missing inventory.ps1" }
    . $invPath
    $cat = Get-Reclaim11Catalog -Root $Root
    if (-not $cat.PSObject.Properties["scheduled_task_paths_pack_a"]) {
        throw "Invoke-Reclaim11KillingBlows: catalog missing scheduled_task_paths_pack_a"
    }
    if (-not $cat.PSObject.Properties["registry_lock_pack_a"]) {
        throw "Invoke-Reclaim11KillingBlows: catalog missing registry_lock_pack_a"
    }

    foreach ($s in @($cat.services_pack_a)) {
        if (@($cat.never_touch_services) -contains $s) {
            throw "Invoke-Reclaim11KillingBlows: pack A lists never-touch $s"
        }
    }
    $desk = Test-Reclaim11DeskHost
    $admin = Test-Reclaim11Admin
    $receipt = Get-Reclaim11WinPeReceipt
    $wd = Join-Path $env:SystemRoot "System32\drivers\WdFilter.sys"
    $wdPresent = Test-Path -LiteralPath $wd
    $inv = Get-Reclaim11Inventory -Root $Root
    $stub = Get-Reclaim11KillingStub -Catalog $cat
    $el = Join-Path $Root "elevate.ps1"
    if ((-not $WhatIf) -and $desk) {
        throw "Refuse: desk (IoTEnterpriseS). Killing blows are VM-only. Not M1ABRAMS."
    }
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
    if ((-not $WhatIf) -and -not $admin) {
        throw "Invoke-Reclaim11KillingBlows: needs elevation"
    }
    if ((-not $WhatIf) -and -not $receipt) {
        throw "Refuse: no WinPE receipt. Boot the Reclaim11 WinPE v7 ISO first."
    }
    if ((-not $WhatIf) -and $wdPresent) {
        throw "Refuse: WdFilter.sys still present. PE park did not land."
    }
    if ((-not $WhatIf) -and -not $inv.never_touch_ok) {
        throw "Refuse: BFE/mpssvc not RUNNING. Never-touch failed."
    }
    if ((-not $WhatIf) -and -not $stub) {
        throw "Refuse: no reclaim11-stub.exe on this volume (PE should have copied it)."
    }

    $taskSnap = @(Get-Reclaim11PackAScheduledTasks -Catalog $cat)
    $regLock = @($cat.registry_lock_pack_a)
    foreach ($rk in $regLock) {
        if ([string]$rk -like "*\Policies\Microsoft\Windows Defender*") {
            throw "Refuse: GPO DisableAntiSpyware key is not a delete target"
        }
    }
    $stamp = [datetime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
    $backupRoot = Join-Path $env:SystemDrive.TrimEnd("\") ("reclaim11\backup\" + $stamp)
    $plan = [pscustomobject]@{
        receipt      = $receipt
        stub         = $stub
        ifeo         = @($cat.usermode_ifeo)
        services     = @($cat.services_pack_a)
        never_touch  = @($cat.never_touch_services)
        tasks        = @($taskSnap)
        registry     = @($regLock)
        backup_root  = $backupRoot
        what_if      = [bool]$WhatIf
        mutate       = $false
        applied      = @()
        failed       = @()
    }
    if ($WhatIf) {
        $checks = @(
            (New-Reclaim11Check -Name "admin" -Ok $admin -Detail "killing blows need TI via admin"),
            (New-Reclaim11Check -Name "desk" -Ok (-not $desk) -Detail $(if ($desk) { "IoTEnterpriseS would refuse" } else { "not desk SKU" })),
            (New-Reclaim11Check -Name "winpe" -Ok ([bool]$receipt) -Detail $(if ($receipt) { [string]$receipt } else { "no reclaim11-winpe.log" })),
            (New-Reclaim11Check -Name "WdFilter" -Ok (-not $wdPresent) -Detail $(if ($wdPresent) { $wd } else { "parked" })),
            (New-Reclaim11Check -Name "never_touch" -Ok ([bool]$inv.never_touch_ok) -Detail "BFE/mpssvc RUNNING"),
            (New-Reclaim11Check -Name "stub" -Ok ([bool]$stub) -Detail $(if ($stub) { [string]$stub } else { "no reclaim11-stub.exe" }))
        )
        $would = @("DisableAntiSpyware=1 (keep GPO key)")
        foreach ($svc in @($cat.services_pack_a)) { $would += ("sc delete {0}" -f $svc) }
        foreach ($row in $taskSnap) { $would += ("schtasks /Delete {0}" -f $row.full) }
        foreach ($rk in $regLock) { $would += ("reg delete {0}" -f $rk) }
        foreach ($img in @($cat.usermode_ifeo)) { $would += ("IFEO {0}" -f $img) }
        $fail = @($checks | Where-Object { -not $_.ok } | ForEach-Object { $_.name })
        $refuse = if ($fail.Count -gt 0) { ($fail -join ",") } else { "" }
        $plan | Add-Member -NotePropertyName checks -NotePropertyValue $checks
        $plan | Add-Member -NotePropertyName would -NotePropertyValue $would
        $plan | Add-Member -NotePropertyName would_refuse -NotePropertyValue $refuse
        return $plan
    }

    $applied = New-Object System.Collections.Generic.List[string]
    $failed = New-Object System.Collections.Generic.List[string]

    if (-not (Test-Path -LiteralPath $backupRoot)) {
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    }
    $taskDir = Join-Path $backupRoot "tasks"
    New-Item -ItemType Directory -Path $taskDir -Force | Out-Null
    foreach ($row in $taskSnap) {
        $safe = ([string]$row.name) -replace '[^\w\.-]', '_'
        $xmlPath = Join-Path $taskDir ($safe + ".xml")
        try {
            $xml = Export-ScheduledTask -TaskName $row.name -TaskPath $row.path
            if ($xml) { Set-Content -LiteralPath $xmlPath -Value $xml -Encoding Unicode }
        } catch { }
    }
    $manPath = Join-Path $backupRoot "restore.json"
    $manifest = [pscustomobject]@{
        id          = "reclaim11-killing-blows-v1"
        at          = [datetime]::UtcNow.ToString("o")
        tasks       = @($taskSnap)
        registry    = @($regLock)
        backup_root = $backupRoot
        note        = "Task XML under tasks\. GPO DisableAntiSpyware stays. Restore is manual."
    }
    ($manifest | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $manPath -Encoding UTF8
    [void]$applied.Add("manifest:$manPath")

    $pol = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender"
    if (-not (Test-Path -LiteralPath $pol)) {
        New-Item -Path $pol -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $pol -Name DisableAntiSpyware -Value 1 -Type DWord
    [void]$applied.Add("policy:DisableAntiSpyware=1")

    foreach ($row in $taskSnap) {
        & schtasks.exe /Delete /TN $row.full /F 2>&1 | Out-Null
        [void]$applied.Add("task:" + $row.full)
    }

    foreach ($rk in $regLock) {
        if (Test-Path -LiteralPath $rk) {
            Remove-Item -LiteralPath $rk -Recurse -Force -ErrorAction SilentlyContinue
            [void]$applied.Add("reglock:$rk")
        }
    }
    $runKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
    if (Test-Path -LiteralPath $runKey) {
        $rp = Get-ItemProperty -LiteralPath $runKey -ErrorAction SilentlyContinue
        if ($rp -and $rp.PSObject.Properties["SecurityHealth"]) {
            Remove-ItemProperty -LiteralPath $runKey -Name SecurityHealth -ErrorAction SilentlyContinue
            [void]$applied.Add("regval:SecurityHealth")
        }
    }

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
    $plan | Add-Member -NotePropertyName manifest_path -NotePropertyValue $manPath -Force

    $plan.applied = @($applied)
    $plan
}
