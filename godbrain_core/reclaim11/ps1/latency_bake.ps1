# Expert BCD + timer/MMCSS bake. restore.json first. Desk refused.
# Not pack A. Not startnet. Not a power scheme (High Performance is Start-CS2).
# nx AlwaysOff is DEP off — Expert only. MiniNT refused (that is the PE BCD).

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

$script:BcdCurrent = @(
    @{ Name = "nx"; Wanted = "AlwaysOff" },
    @{ Name = "tscsyncpolicy"; Wanted = "Enhanced" },
    @{ Name = "hypervisorlaunchtype"; Wanted = "Auto" },
    @{ Name = "vsmlaunchtype"; Wanted = "Off" },
    @{ Name = "sos"; Wanted = "No" },
    @{ Name = "useplatformclock"; Wanted = "No" },
    @{ Name = "useplatformtick"; Wanted = "No" },
    @{ Name = "disabledynamictick"; Wanted = "Yes" }
)
$script:BcdBootmgr = @(
    @{ Name = "bootmenupolicy"; Wanted = "Legacy" }
)
$script:RegBake = @(
    @{
        Path = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel"
        Name = "GlobalTimerResolutionRequests"
        Wanted = 1
    },
    @{
        Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"
        Name = "SystemResponsiveness"
        Wanted = 0
    },
    @{
        Path = "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl"
        Name = "Win32PrioritySeparation"
        Wanted = 38
    }
)

function Test-Reclaim11LatencyDeskHost {
    $n = Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
    [string]$n.EditionID -eq "IoTEnterpriseS"
}

function Test-Reclaim11LatencyPeHost {
    Test-Path -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT"
}

function Invoke-Reclaim11BcdEdit {
    param([Parameter(Mandatory)][string[]]$BcdArgs)
    $exe = Join-Path $env:SystemRoot "System32\bcdedit.exe"
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & $exe @BcdArgs 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            throw ("bcdedit {0} exit {1}`n{2}" -f ($BcdArgs -join " "), $LASTEXITCODE, $out)
        }
        $out
    } finally {
        $ErrorActionPreference = $old
    }
}

function Get-Reclaim11BcdValue {
    param([string]$Store, [string]$Name)
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & (Join-Path $env:SystemRoot "System32\bcdedit.exe") /enum $Store 2>&1 | Out-String
    } catch {
        return $null
    } finally {
        $ErrorActionPreference = $old
    }
    foreach ($line in ($out -split "`r?`n")) {
        if ($line -match ('^\s*' + [regex]::Escape($Name) + '\s+(.+)$')) {
            return $Matches[1].Trim()
        }
    }
    $null
}

function Get-Reclaim11RegDword {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $ip = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $ip) { return $null }
    if (-not $ip.PSObject.Properties[$Name]) { return $null }
    [int]$ip.$Name
}

function Set-Reclaim11RegDword {
    param([string]$Path, [string]$Name, [int]$Value)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
}

function Remove-Reclaim11RegDword {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
}

function Invoke-Reclaim11LatencyBake {
    param(
        [string]$Root,
        [switch]$WhatIf
    )
    if ([string]::IsNullOrWhiteSpace($Root)) { $Root = $script:Reclaim11Here }
    $pe = Test-Reclaim11LatencyPeHost
    $desk = Test-Reclaim11LatencyDeskHost
    if ($pe -and -not $WhatIf) {
        throw "Refuse: WinPE (MiniNT). Latency bake is in-Windows on a VM, not the PE BCD."
    }
    if ($desk -and -not $WhatIf) {
        throw "Refuse: desk (IoTEnterpriseS). Latency bake is VM-only. Not M1ABRAMS."
    }
    $admin = $false
    if (Get-Command Test-Reclaim11Admin -ErrorAction SilentlyContinue) {
        $admin = Test-Reclaim11Admin
    }

    $bcd = @()
    foreach ($row in $script:BcdCurrent) {
        $bcd += [pscustomobject]@{
            store  = "{current}"
            name   = [string]$row.Name
            before = Get-Reclaim11BcdValue -Store "{current}" -Name $row.Name
            wanted = [string]$row.Wanted
        }
    }
    foreach ($row in $script:BcdBootmgr) {
        $bcd += [pscustomobject]@{
            store  = "{bootmgr}"
            name   = [string]$row.Name
            before = Get-Reclaim11BcdValue -Store "{bootmgr}" -Name $row.Name
            wanted = [string]$row.Wanted
        }
    }
    $regs = @()
    foreach ($row in $script:RegBake) {
        $regs += [pscustomobject]@{
            path   = [string]$row.Path
            name   = [string]$row.Name
            before = Get-Reclaim11RegDword -Path $row.Path -Name $row.Name
            wanted = [int]$row.Wanted
        }
    }

    $stamp = [datetime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
    $backupRoot = Join-Path $env:SystemDrive.TrimEnd("\") ("reclaim11\backup\" + $stamp)
    $manPath = Join-Path $backupRoot "restore.json"
    $would = @()
    foreach ($x in $bcd) {
        $would += ("bcd {0} {1} {2}->{3}" -f $x.store, $x.name, $x.before, $x.wanted)
    }
    foreach ($x in $regs) {
        $would += ("reg {0} {1} {2}->{3}" -f $x.path, $x.name, $x.before, $x.wanted)
    }

    $checks = @(
        (New-Reclaim11Check -Name "admin" -Ok $admin -Detail "bcdedit / HKLM needs admin"),
        (New-Reclaim11Check -Name "winpe" -Ok (-not $pe) -Detail $(if ($pe) { "MiniNT would refuse (PE BCD)" } else { "not WinPE" })),
        (New-Reclaim11Check -Name "desk" -Ok (-not $desk) -Detail $(if ($desk) { "IoTEnterpriseS would refuse" } else { "not desk SKU" }))
    )
    $refuse = ""
    if ($pe) { $refuse = "WinPE (MiniNT)" }
    elseif ($desk) { $refuse = "desk (IoTEnterpriseS)" }
    elseif (-not $admin) { $refuse = "needs elevation" }

    $manifest = [pscustomobject]@{
        id          = "reclaim11-latency-v1"
        at          = [datetime]::UtcNow.ToString("o")
        bcd         = @($bcd)
        registry    = @($regs)
        backup_root = $backupRoot
        note        = "Restore with pwsh -File latency_bake.ps1 -Restore restore.json. Expert. nx AlwaysOff is DEP off. Not a power scheme."
    }

    if ($WhatIf) {
        $manifest | Add-Member -NotePropertyName what_if -NotePropertyValue $true
        $manifest | Add-Member -NotePropertyName mutate -NotePropertyValue $false
        $manifest | Add-Member -NotePropertyName checks -NotePropertyValue $checks
        $manifest | Add-Member -NotePropertyName would -NotePropertyValue $would
        $manifest | Add-Member -NotePropertyName would_refuse -NotePropertyValue $refuse
        $manifest | Add-Member -NotePropertyName manifest_path -NotePropertyValue $manPath
        return $manifest
    }
    if ($refuse) { throw ("Refuse: {0}" -f $refuse) }

    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    $applied = @()
    $failed = @()
    foreach ($x in $bcd) {
        try {
            $null = Invoke-Reclaim11BcdEdit -BcdArgs @("/set", $x.store, $x.name, $x.wanted)
            $applied += ("bcd:{0}:{1}" -f $x.store, $x.name)
        } catch {
            $failed += ("bcd:{0}:{1}:{2}" -f $x.store, $x.name, $_.Exception.Message)
        }
    }
    foreach ($x in $regs) {
        try {
            Set-Reclaim11RegDword -Path $x.path -Name $x.name -Value ([int]$x.wanted)
            $applied += ("reg:{0}:{1}" -f $x.path, $x.name)
        } catch {
            $failed += ("reg:{0}:{1}:{2}" -f $x.path, $x.name, $_.Exception.Message)
        }
    }
    $manifest | Add-Member -NotePropertyName what_if -NotePropertyValue $false
    $manifest | Add-Member -NotePropertyName mutate -NotePropertyValue $true
    $manifest | Add-Member -NotePropertyName applied -NotePropertyValue $applied
    $manifest | Add-Member -NotePropertyName failed -NotePropertyValue $failed
    $manifest | Add-Member -NotePropertyName manifest_path -NotePropertyValue $manPath
    $json = $manifest | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $manPath -Value $json -Encoding UTF8
    $manifest
}

function Restore-Reclaim11LatencyBackup {
    param([string]$Manifest)
    if (-not (Test-Path -LiteralPath $Manifest)) {
        throw "Restore-Reclaim11LatencyBackup: missing $Manifest"
    }
    $m = Get-Content -LiteralPath $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$m.id -notlike "reclaim11-latency*") {
        throw "Restore-Reclaim11LatencyBackup: not a latency manifest"
    }
    if (Test-Reclaim11LatencyPeHost) {
        throw "Refuse: WinPE (MiniNT). Latency restore is in-Windows on a VM, not the PE BCD."
    }
    if (Test-Reclaim11LatencyDeskHost) {
        throw "Refuse: desk (IoTEnterpriseS). Latency restore is VM-only. Not M1ABRAMS."
    }
    $restored = @()
    foreach ($x in @($m.bcd)) {
        $before = [string]$x.before
        if ([string]::IsNullOrWhiteSpace($before)) {
            try {
                $null = Invoke-Reclaim11BcdEdit -BcdArgs @("/deletevalue", [string]$x.store, [string]$x.name)
                $restored += ("bcd-del:{0}:{1}" -f $x.store, $x.name)
            } catch { }
            continue
        }
        try {
            $null = Invoke-Reclaim11BcdEdit -BcdArgs @("/set", [string]$x.store, [string]$x.name, $before)
            $restored += ("bcd:{0}:{1}" -f $x.store, $x.name)
        } catch { }
    }
    foreach ($x in @($m.registry)) {
        if ($null -eq $x.before) {
            try {
                Remove-Reclaim11RegDword -Path ([string]$x.path) -Name ([string]$x.name)
                $restored += ("reg-del:{0}:{1}" -f $x.path, $x.name)
            } catch { }
            continue
        }
        try {
            Set-Reclaim11RegDword -Path ([string]$x.path) -Name ([string]$x.name) -Value ([int]$x.before)
            $restored += ("reg:{0}:{1}" -f $x.path, $x.name)
        } catch { }
    }
    [pscustomobject]@{ manifest = $Manifest; restored = @($restored) }
}

if ($MyInvocation.InvocationName -ne ".") {
    if (-not [string]::IsNullOrWhiteSpace($Restore)) {
        Restore-Reclaim11LatencyBackup -Manifest $Restore | ConvertTo-Json -Depth 6
    } else {
        $plan = Invoke-Reclaim11LatencyBake -WhatIf:$WhatIf
        if ($WhatIf) {
            Write-Host (Format-Reclaim11TestReport -Plan $plan -Title "latency_bake")
        }
        $plan | ConvertTo-Json -Depth 8
        if ((-not $WhatIf) -and $plan.PSObject.Properties["manifest_path"] -and $plan.manifest_path) {
            Write-Host ("restore.json {0}" -f $plan.manifest_path)
        }
    }
}
