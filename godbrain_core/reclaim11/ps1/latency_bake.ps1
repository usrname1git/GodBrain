# Expert BCD + timer/MMCSS + USB/ASPM bake. restore.json first. Desk refused.
# Not pack A. Not startnet. Not AGGRO/Ultimate (those kill C-states, +idle heat).
# Not min-processor 100. High Performance switch stays Start-CS2.
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
# Balanced vs HP delta that is not a C-state kill. AC only.
$script:PowerHighPerfGuid = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
$script:PowerForbiddenGuid = @(
    "61329e62-4cc1-47eb-92fd-5ac16564efdd",
    "e9a42b02-d5df-448d-aa00-03f14749eb61"
)
$script:PowerAcBake = @(
    @{
        Name    = "usb_selective_suspend"
        Sub     = "2a737441-1930-4402-8d77-b2bebba308a3"
        Setting = "48e6b7a6-50f5-4782-a5d4-53bb8f07e226"
        Wanted  = 0
    },
    @{
        Name    = "usb3_link_power"
        Sub     = "2a737441-1930-4402-8d77-b2bebba308a3"
        Setting = "d4e98f31-5ffe-4ce1-be31-1b38b384c009"
        Wanted  = 0
    },
    @{
        Name    = "pcie_aspm"
        Sub     = "501a4d13-42af-4429-9fd1-a8218c268e20"
        Setting = "ee12f906-d277-404b-b6da-e5fa1a576df5"
        Wanted  = 0
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

function Invoke-Reclaim11PowerCfg {
    param(
        [Parameter(Mandatory)][string[]]$PowerArgs,
        [switch]$AllowFail
    )
    $exe = Join-Path $env:SystemRoot "System32\powercfg.exe"
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & $exe @PowerArgs 2>&1 | Out-String
        if ((-not $AllowFail) -and ($LASTEXITCODE -ne 0)) {
            throw ("powercfg {0} exit {1}`n{2}" -f ($PowerArgs -join " "), $LASTEXITCODE, $out)
        }
        $out
    } finally {
        $ErrorActionPreference = $old
    }
}

function Get-Reclaim11ActivePowerGuid {
    $out = Invoke-Reclaim11PowerCfg -PowerArgs @("/getactivescheme") -AllowFail
    if ($out -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
        return $Matches[1].ToLowerInvariant()
    }
    $null
}

function Get-Reclaim11ListedPowerGuids {
    $out = Invoke-Reclaim11PowerCfg -PowerArgs @("/list") -AllowFail
    $ids = @()
    foreach ($m in [regex]::Matches([string]$out, '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})')) {
        $ids += $m.Groups[1].Value.ToLowerInvariant()
    }
    @($ids | Select-Object -Unique)
}

function Test-Reclaim11PowerForbiddenGuid {
    param([string]$Guid)
    $g = ([string]$Guid).ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($g)) { return $false }
    @($script:PowerForbiddenGuid | ForEach-Object { $_.ToLowerInvariant() }) -contains $g
}

function Get-Reclaim11PowerBakeSchemes {
    param([string]$Active)
    $listed = @(Get-Reclaim11ListedPowerGuids)
    $out = @()
    if ($Active -and -not (Test-Reclaim11PowerForbiddenGuid $Active)) {
        $out += $Active.ToLowerInvariant()
    }
    $hp = $script:PowerHighPerfGuid.ToLowerInvariant()
    if (($listed -contains $hp) -and ($out -notcontains $hp)) {
        $out += $hp
    }
    $out
}

function Get-Reclaim11PowerAcIndex {
    param([string]$Scheme, [string]$Sub, [string]$Setting)
    $out = Invoke-Reclaim11PowerCfg -PowerArgs @("/qh", $Scheme, $Sub, $Setting) -AllowFail
    if ([string]$out -match 'Current AC Power Setting Index:\s+0x([0-9a-fA-F]+)') {
        return [Convert]::ToInt32($Matches[1], 16)
    }
    $null
}

function Set-Reclaim11PowerAcIndex {
    param([string]$Scheme, [string]$Sub, [string]$Setting, [int]$Value)
    $null = Invoke-Reclaim11PowerCfg -PowerArgs @("/setacvalueindex", $Scheme, $Sub, $Setting, ([string]$Value))
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

    $activePower = Get-Reclaim11ActivePowerGuid
    $powerForbidden = Test-Reclaim11PowerForbiddenGuid $activePower
    $power = @()
    foreach ($scheme in @(Get-Reclaim11PowerBakeSchemes -Active $activePower)) {
        foreach ($row in $script:PowerAcBake) {
            $power += [pscustomobject]@{
                scheme = $scheme
                name   = [string]$row.Name
                sub    = [string]$row.Sub
                setting = [string]$row.Setting
                before = Get-Reclaim11PowerAcIndex -Scheme $scheme -Sub $row.Sub -Setting $row.Setting
                wanted = [int]$row.Wanted
            }
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
    foreach ($x in $power) {
        if ($null -eq $x.before) {
            $would += ("skip missing {0} {1}" -f $x.scheme, $x.name)
        } else {
            $would += ("power {0} {1} {2}->{3}" -f $x.scheme, $x.name, $x.before, $x.wanted)
        }
    }

    $checks = @(
        (New-Reclaim11Check -Name "admin" -Ok $admin -Detail "bcdedit / HKLM needs admin"),
        (New-Reclaim11Check -Name "winpe" -Ok (-not $pe) -Detail $(if ($pe) { "MiniNT would refuse (PE BCD)" } else { "not WinPE" })),
        (New-Reclaim11Check -Name "desk" -Ok (-not $desk) -Detail $(if ($desk) { "IoTEnterpriseS would refuse" } else { "not desk SKU" })),
        (New-Reclaim11Check -Name "power" -Ok (-not $powerForbidden) -Detail $(if ($powerForbidden) { "AGGRO/Ultimate idle-disable" } else { "not AGGRO/Ultimate" }))
    )
    $refuse = ""
    if ($pe) { $refuse = "WinPE (MiniNT)" }
    elseif ($desk) { $refuse = "desk (IoTEnterpriseS)" }
    elseif (-not $admin) { $refuse = "needs elevation" }
    elseif ($powerForbidden) { $refuse = "AGGRO/Ultimate (processor idle disable)" }

    $manifest = [pscustomobject]@{
        id           = "reclaim11-latency-v1"
        at           = [datetime]::UtcNow.ToString("o")
        bcd          = @($bcd)
        registry     = @($regs)
        power        = @($power)
        power_active = $activePower
        backup_root  = $backupRoot
        note         = "Restore with pwsh -File latency_bake.ps1 -Restore restore.json. Expert. nx AlwaysOff is DEP off. USB/ASPM on AC, not min-processor 100, not C-state kill."
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
    foreach ($x in $power) {
        if ($null -eq $x.before) { continue }
        try {
            Set-Reclaim11PowerAcIndex -Scheme $x.scheme -Sub $x.sub -Setting $x.setting -Value ([int]$x.wanted)
            $applied += ("power:{0}:{1}" -f $x.scheme, $x.name)
        } catch {
            $failed += ("power:{0}:{1}:{2}" -f $x.scheme, $x.name, $_.Exception.Message)
        }
    }
    if ($activePower -and -not (Test-Reclaim11PowerForbiddenGuid $activePower)) {
        try {
            $null = Invoke-Reclaim11PowerCfg -PowerArgs @("/setactive", $activePower)
            $applied += ("power-active:{0}" -f $activePower)
        } catch {
            $failed += ("power-active:{0}:{1}" -f $activePower, $_.Exception.Message)
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
    foreach ($x in @($m.power)) {
        if ($null -eq $x) { continue }
        if ($null -eq $x.before) { continue }
        try {
            Set-Reclaim11PowerAcIndex -Scheme ([string]$x.scheme) -Sub ([string]$x.sub) -Setting ([string]$x.setting) -Value ([int]$x.before)
            $restored += ("power:{0}:{1}" -f $x.scheme, $x.name)
        } catch { }
    }
    $active = [string]$m.power_active
    if (-not [string]::IsNullOrWhiteSpace($active) -and -not (Test-Reclaim11PowerForbiddenGuid $active)) {
        try {
            $null = Invoke-Reclaim11PowerCfg -PowerArgs @("/setactive", $active)
            $restored += ("power-active:{0}" -f $active)
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
