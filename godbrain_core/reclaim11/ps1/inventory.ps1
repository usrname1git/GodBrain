# Read-only Reclaim11 inventory + gate math. Never mutates. Not Heal.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-Reclaim11DeskHost {
    $n = Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
    [string]$n.EditionID -eq "IoTEnterpriseS"
}

function Get-Reclaim11Root {
    $start = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($start) -and $MyInvocation.MyCommand.Path) {
        $start = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    if ([string]::IsNullOrWhiteSpace($start)) {
        throw "Get-Reclaim11Root: no script path"
    }
    $d = $start
    for ($i = 0; $i -lt 4; $i++) {
        if (Test-Path -LiteralPath (Join-Path $d "catalog.json")) { return $d }
        $parent = Split-Path $d
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $d) { break }
        $d = $parent
    }
    throw "Get-Reclaim11Root: catalog.json not found from $start"
}

function Resolve-Reclaim11Worker {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [string]$Root = ""
    )
    if ([string]::IsNullOrWhiteSpace($Root)) {
        try { $Root = Get-Reclaim11Root } catch { $Root = "" }
    }
    $cands = @()
    if (-not [string]::IsNullOrWhiteSpace($Root)) {
        $cands += (Join-Path $Root "ps1\$Name")
        $cands += (Join-Path $Root $Name)
    }
    if ($PSScriptRoot) {
        $cands += (Join-Path $PSScriptRoot $Name)
        $parent = Split-Path $PSScriptRoot
        if ($parent) {
            $cands += (Join-Path $parent "ps1\$Name")
            $cands += (Join-Path $parent $Name)
        }
    }
    foreach ($c in $cands) {
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        if (Test-Path -LiteralPath $c) { return (Get-Item -LiteralPath $c).FullName }
    }
    throw "Resolve-Reclaim11Worker: missing $Name"
}

function Get-Reclaim11Pwsh {
    # Never Get-Command pwsh / where.exe: Win11 Store stub is WindowsApps.
    $cands = @(
        (Join-Path $PSHOME "pwsh.exe"),
        "C:\pwsh\pwsh.exe",
        (Join-Path ${env:ProgramFiles} "PowerShell\7\pwsh.exe"),
        (Join-Path ${env:ProgramFiles} "PowerShell\pwsh.exe"),
        (Join-Path $PSHOME "powershell.exe"),
        (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe")
    )
    foreach ($c in $cands) {
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        if ($c -match 'WindowsApps') { continue }
        if (Test-Path -LiteralPath $c) { return (Get-Item -LiteralPath $c).FullName }
    }
    throw "Get-Reclaim11Pwsh: no PowerShell host"
}

function Get-Reclaim11Catalog {
    param([string]$Root = (Get-Reclaim11Root))
    $path = Join-Path $Root "catalog.json"
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Get-Reclaim11Catalog: missing $path"
    }
    Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-Reclaim11OsPin {
    $n = Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
    [pscustomobject]@{
        product_name    = [string]$n.ProductName
        edition_id      = [string]$n.EditionID
        display_version = [string]$n.DisplayVersion
        current_build   = [string]$n.CurrentBuild
        ubr             = [int]$n.UBR
        os_pin          = ("{0}/{1}.{2}" -f $n.EditionID, $n.CurrentBuild, $n.UBR)
        computer        = [string]$env:COMPUTERNAME
        firmware        = [string]$env:firmware_type
    }
}

function Get-Reclaim11SecureBoot {
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State"
    try {
        $v = Get-ItemProperty -LiteralPath $regPath -Name UEFISecureBootEnabled -ErrorAction Stop
        return [pscustomobject]@{
            available = $true
            enabled   = [bool]$v.UEFISecureBootEnabled
            error     = $null
        }
    } catch {
        # fall through to Confirm-SecureBootUEFI
    }
    try {
        $on = Confirm-SecureBootUEFI
        [pscustomobject]@{
            available = $true
            enabled   = [bool]$on
            error     = $null
        }
    } catch {
        [pscustomobject]@{
            available = $false
            enabled   = $false
            error     = [string]$_.Exception.Message
        }
    }
}

function Get-Reclaim11BitLockerC {
    try {
        $cmd = Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue
        if ($cmd) {
            $v = Get-BitLockerVolume -MountPoint "C:" -ErrorAction Stop
            return [pscustomobject]@{
                present          = $true
                protection       = [string]$v.ProtectionStatus
                volume_status    = [string]$v.VolumeStatus
                error            = $null
            }
        }
    } catch {
        return [pscustomobject]@{
            present       = $false
            protection    = "unknown"
            volume_status = "unknown"
            error         = [string]$_.Exception.Message
        }
    }
    [pscustomobject]@{
        present       = $false
        protection    = "unknown"
        volume_status = "unknown"
        error         = "Get-BitLockerVolume not present"
    }
}

function Get-Reclaim11ServiceSnap {
    param([string[]]$Names)
    $rows = @()
    foreach ($n in $Names) {
        $s = Get-Service -Name $n -ErrorAction SilentlyContinue
        if ($s) {
            $rows += [pscustomobject]@{
                name       = $n
                present    = $true
                status     = [string]$s.Status
                start_type = [string]$s.StartType
            }
        } else {
            $rows += [pscustomobject]@{
                name       = $n
                present    = $false
                status     = "1060"
                start_type = "none"
            }
        }
    }
    $rows
}

function Test-Reclaim11NeverTouchOk {
    param($Rows)
    $bfe = $Rows | Where-Object { $_.name -eq "BFE" } | Select-Object -First 1
    $fw  = $Rows | Where-Object { $_.name -eq "mpssvc" } | Select-Object -First 1
    [bool]($bfe -and $bfe.present -and $bfe.status -eq "Running" -and
           $fw -and $fw.present -and $fw.status -eq "Running")
}

function Get-Reclaim11WinPeReceipt {
    param(
        [string]$Path = "",
        [string]$WindowsRoot = ""
    )
    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($Path)) { [void]$candidates.Add($Path) }
    $root = $WindowsRoot
    if ([string]::IsNullOrWhiteSpace($root)) { $root = $env:SystemRoot }
    if (-not [string]::IsNullOrWhiteSpace($root)) {
        [void]$candidates.Add((Join-Path $root "reclaim11-winpe.log"))
        $parent = Split-Path -Parent $root
        if ($parent) { [void]$candidates.Add((Join-Path $parent "reclaim11-winpe.log")) }
    }
    foreach ($c in $candidates) {
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        if (-not (Test-Path -LiteralPath $c)) { continue }
        try {
            $j = Get-Content -LiteralPath $c -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.PSObject.Properties["id"] -and ([string]$j.id -like "reclaim11-winpe*")) {
                return (Get-Item -LiteralPath $c).FullName
            }
        } catch {
            continue
        }
    }
    $null
}

function Get-Reclaim11WinPeLog {
    param(
        [string]$Path = "",
        [string]$WindowsRoot = ""
    )
    Get-Reclaim11WinPeReceipt -Path $Path -WindowsRoot $WindowsRoot
}

function Get-Reclaim11Gates {
    <#
      Pure. Inventory + optional winpe log path -> button enables.
      Secure Boot on => refuse WdBoot/ELAM stub. Prep media still allowed
      (media skips ELAM). Killing blows need a WinPE log.
    #>
    param(
        $Inventory,
        [string]$WinPeLog = ""
    )
    $avail = $false
    $sb = $false
    $sbErr = ""
    if ($Inventory -and $Inventory.secure_boot) {
        $avail = [bool]$Inventory.secure_boot.available
        $sb = [bool]$Inventory.secure_boot.enabled
        if ($Inventory.secure_boot.PSObject.Properties['error']) {
            $sbErr = [string]$Inventory.secure_boot.error
        }
    }
    $log = Get-Reclaim11WinPeLog -Path $WinPeLog
    $allowStub = $avail -and -not $sb
    $wdbootReason = if (-not $avail) {
        $tail = if ($sbErr) { " $sbErr" } else { "" }
        "Secure Boot n/a: refuse WdBoot stub (ELAM).$tail"
    } elseif ($sb) {
        "Secure Boot on: refuse WdBoot stub (ELAM). Firmware off, or skip ELAM."
    } else {
        "Secure Boot off: WdBoot stub allowed on the offline volume."
    }
    [pscustomobject]@{
        prep_media              = $true
        stub_wdboot             = $allowStub
        killing_blows           = [bool]$log
        never_touch_ok          = [bool]$Inventory.never_touch_ok
        winpe_log               = $log
        reason_wdboot           = $wdbootReason
        reason_killing_blows    = if ($log) { "WinPE log present: killing blows unlocked." } else { "Killing blows locked until a WinPE log exists." }
    }
}

function Get-Reclaim11Inventory {
    param(
        [string]$Root = (Get-Reclaim11Root),
        [string]$WinPeLog = ""
    )
    $cat = Get-Reclaim11Catalog -Root $Root
    $os = Get-Reclaim11OsPin
    $sb = Get-Reclaim11SecureBoot
    $bl = Get-Reclaim11BitLockerC
    $watch = @($cat.services_pack_a) + @($cat.never_touch_services)
    $watch = $watch | Select-Object -Unique
    $svcs = @(Get-Reclaim11ServiceSnap -Names $watch)
    $neverOk = Test-Reclaim11NeverTouchOk -Rows $svcs
    $stub = [string]$cat.stub_exe
    $inv = [pscustomobject]@{
        at              = [datetime]::UtcNow.ToString("o")
        catalog         = [string]$cat.id
        pack            = [string]$cat.pack
        os              = $os
        secure_boot     = $sb
        bitlocker_c     = $bl
        services        = $svcs
        never_touch_ok  = $neverOk
        stub_exe_exists = (Test-Path -LiteralPath $stub)
        stub_exe        = $stub
        ppl_offline     = @($cat.ppl_offline)
        elam            = @($cat.elam)
        mutate          = $false
    }
    $resolvedLog = Get-Reclaim11WinPeReceipt -Path $WinPeLog
    $inv | Add-Member -NotePropertyName gates -NotePropertyValue (Get-Reclaim11Gates -Inventory $inv -WinPeLog $resolvedLog)
    $inv
}

function ConvertTo-Reclaim11Json {
    param($Inventory)
    $Inventory | ConvertTo-Json -Depth 8 -Compress:$false
}

function Test-Reclaim11Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal $id
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function New-Reclaim11Check {
    param(
        [string]$Name,
        [bool]$Ok,
        [string]$Detail = ""
    )
    [pscustomobject]@{
        name   = $Name
        ok     = [bool]$Ok
        detail = $Detail
    }
}

function Format-Reclaim11TestReport {
    param(
        $Plan,
        [string]$Title = "Reclaim11 test"
    )
    $lines = @()
    $lines += "TEST ONLY (DeviceCleanupCmd -t). mutate=false. No restore.json."
    $lines += $Title
    $who = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $lines += ("  identity  {0}" -f $who)
    $lines += ("  admin     {0}" -f (Test-Reclaim11Admin))
    $lines += ("  lang      {0}" -f $ExecutionContext.SessionState.LanguageMode)
    foreach ($c in @($Plan.checks)) {
        $mark = if ([bool]$c.ok) { "ok  " } else { "FAIL" }
        $lines += ("  [{0}] {1}  {2}" -f $mark, $c.name, $c.detail)
    }
    $refuse = [string]$Plan.would_refuse
    if (-not [string]::IsNullOrWhiteSpace($refuse)) {
        $lines += ("WOULD REFUSE  {0}" -f $refuse)
    } else {
        $lines += "WOULD RUN"
    }
    foreach ($w in @($Plan.would)) {
        $lines += ("  would  {0}" -f $w)
    }
    $lines -join [Environment]::NewLine
}
