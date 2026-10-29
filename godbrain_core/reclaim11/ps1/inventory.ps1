# Read-only Reclaim11 inventory + gate math. Never mutates. Not Heal.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

function Get-Reclaim11Pwsh7 {
    # Never Get-Command pwsh / where.exe: Win11 Store stub is WindowsApps.
    $cands = @(
        (Join-Path $PSHOME "pwsh.exe"),
        "C:\pwsh\pwsh.exe",
        (Join-Path ${env:ProgramFiles} "PowerShell\7\pwsh.exe"),
        (Join-Path ${env:ProgramFiles} "PowerShell\pwsh.exe")
    )
    foreach ($c in $cands) {
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        if ($c -match 'WindowsApps') { continue }
        if ($c -match 'WindowsPowerShell') { continue }
        if (Test-Path -LiteralPath $c) { return (Get-Item -LiteralPath $c).FullName }
    }
    $null
}

function Get-Reclaim11Pwsh {
    $pwsh7 = Get-Reclaim11Pwsh7
    if ($pwsh7) { return $pwsh7 }
    $cands = @(
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

function New-Reclaim11BackupStamp {
    [datetime]::UtcNow.ToString("yyyyMMddTHHmmssZ-fffffff") + "-" + [guid]::NewGuid().ToString("N")
}

function Test-Reclaim11PeHost {
    Test-Path -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT"
}

function Get-Reclaim11NetAdapters {
    try {
        Get-NetAdapter -ErrorAction Stop
    } catch {
        if ($_.CategoryInfo.Category -eq [Management.Automation.ErrorCategory]::ObjectNotFound -and
            $_.FullyQualifiedErrorId -like "CmdletizationQuery_NotFound*") { return }
        throw
    }
}

function Get-Reclaim11RegistryKey {
    param([string]$Path, [switch]$RequireKey, [switch]$Writable)
    try {
        $key = Get-Item -LiteralPath $Path -ErrorAction Stop
    } catch [System.Management.Automation.ItemNotFoundException] {
        if ($RequireKey) { throw "Registry target is missing: $Path" }
        return $null
    }
    if (-not $Writable) { return $key }
    try { $name = $key.Name } finally { $key.Dispose() }
    $parts = $name -split '\\', 2
    $hive = switch ($parts[0]) {
        "HKEY_LOCAL_MACHINE" { [Microsoft.Win32.Registry]::LocalMachine }
        "HKEY_CURRENT_USER" { [Microsoft.Win32.Registry]::CurrentUser }
        default { throw "Unsupported writable registry hive: $name" }
    }
    if ($parts.Count -ne 2) { throw "Refuse registry hive root write: $name" }
    $key = $hive.OpenSubKey($parts[1], $true)
    if ($null -eq $key) { throw "Registry target disappeared: $Path" }
    $key
}

function Get-Reclaim11RegistrySnapshot {
    param([string]$Path, [string]$Name, [switch]$RequireKey)
    $key = Get-Reclaim11RegistryKey -Path $Path -RequireKey:$RequireKey
    if ($null -eq $key) {
        return [pscustomobject]@{ key_exists = $false; exists = $false; kind = $null; value = $null }
    }
    try {
        if ($key.GetValueNames() -notcontains $Name) {
            return [pscustomobject]@{ key_exists = $true; exists = $false; kind = $null; value = $null }
        }
        [pscustomobject]@{
            key_exists = $true
            exists = $true
            kind = [string]$key.GetValueKind($Name)
            value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        }
    } finally {
        $key.Dispose()
    }
}

function Test-Reclaim11RegistrySnapshotEqual {
    param($Left, $Right)
    if ([bool]$Left.exists -ne [bool]$Right.exists) { return $false }
    if (-not $Left.exists) { return $true }
    if ([string]$Left.kind -cne [string]$Right.kind) { return $false }
    $a = @($Left.value)
    $b = @($Right.value)
    if ($a.Count -ne $b.Count) { return $false }
    for ($i = 0; $i -lt $a.Count; $i++) {
        if ($a[$i] -cne $b[$i]) { return $false }
    }
    $true
}

function Set-Reclaim11RegistrySnapshot {
    param([string]$Path, [string]$Name, $Snapshot, [switch]$RequireKey)
    $key = Get-Reclaim11RegistryKey -Path $Path -RequireKey:$RequireKey -Writable
    if (-not $Snapshot.exists) {
        if ($null -ne $key) {
            try { $key.DeleteValue($Name, $false) } finally { $key.Dispose() }
        }
    } else {
        if ($null -eq $key) {
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
            $key = Get-Reclaim11RegistryKey -Path $Path -RequireKey -Writable
        }
        try {
            $value = switch ([string]$Snapshot.kind) {
                "DWord" { [int]$Snapshot.value }
                "QWord" { [long]$Snapshot.value }
                "String" { [string]$Snapshot.value }
                "ExpandString" { [string]$Snapshot.value }
                "MultiString" { ,([string[]]@($Snapshot.value)) }
                "Binary" { ,([byte[]]@($Snapshot.value)) }
                "None" { ,([byte[]]@($Snapshot.value)) }
                default { throw "Unsupported registry value kind: $($Snapshot.kind)" }
            }
            $key.SetValue($Name, $value, [Microsoft.Win32.RegistryValueKind]$Snapshot.kind)
        } finally {
            $key.Dispose()
        }
    }
    $after = Get-Reclaim11RegistrySnapshot -Path $Path -Name $Name
    if (-not (Test-Reclaim11RegistrySnapshotEqual -Left $Snapshot -Right $after)) {
        throw "Registry readback mismatch: $Path $Name"
    }
}

function Set-Reclaim11RegistryDword {
    param([string]$Path, [string]$Name, [int]$Value, [switch]$RequireKey)
    Set-Reclaim11RegistrySnapshot -Path $Path -Name $Name -RequireKey:$RequireKey -Snapshot (
        [pscustomobject]@{ exists = $true; kind = "DWord"; value = $Value }
    )
}

function Get-Reclaim11TcpInterfaceTargets {
    param([object[]]$Adapters, [switch]$IncludeDisconnected, [guid]$InterfaceGuid = [guid]::Empty)
    $seen = @{}
    foreach ($adapter in @($Adapters)) {
        if ($InterfaceGuid -ne [guid]::Empty) {
            $candidate = [guid]::Empty
            if (-not $adapter.PSObject.Properties["InterfaceGuid"] -or
                -not [guid]::TryParse([string]$adapter.InterfaceGuid, [ref]$candidate) -or $candidate -ne $InterfaceGuid) { continue }
        }
        if ([string]$adapter.PhysicalMediaType -notmatch "802\.3|Ethernet") { continue }
        if (-not $adapter.PSObject.Properties["HardwareInterface"]) {
            throw "Cannot establish physical NIC identity: $($adapter.Name)"
        }
        if (-not $adapter.HardwareInterface) { continue }
        if ($adapter.PSObject.Properties["Virtual"] -and $adapter.Virtual) { continue }
        if ([string]$adapter.Status -eq "Not Present") { continue }
        if (-not $IncludeDisconnected -and [string]$adapter.Status -ne "Up") { continue }
        $guid = [guid]::Empty
        if (-not $adapter.PSObject.Properties["InterfaceGuid"] -or
            -not [guid]::TryParse([string]$adapter.InterfaceGuid, [ref]$guid) -or $guid -eq [guid]::Empty) {
            throw "Invalid NIC interface GUID: $($adapter.Name)"
        }
        $id = $guid.ToString("B")
        if ($seen.ContainsKey($id)) { throw "Ambiguous NIC interface GUID: $id" }
        $seen[$id] = $true
        $path = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$id"
        $key = Get-Reclaim11RegistryKey -Path $path -RequireKey
        $key.Dispose()
        [pscustomobject]@{ adapter = [string]$adapter.Name; guid = $id; path = $path }
    }
}

function Get-Reclaim11NvidiaRegistryTargets {
    $seen = @{}
    try {
        $devices = @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction Stop)
    } catch {
        if ($_.CategoryInfo.Category -eq [Management.Automation.ErrorCategory]::ObjectNotFound -and
            $_.FullyQualifiedErrorId -like "CmdletizationQuery_NotFound*") { return }
        throw
    }
    foreach ($device in $devices) {
        $id = [string]$device.InstanceId
        if ($id -notmatch '^PCI\\VEN_10DE&') { continue }
        if ($id -notmatch '^PCI\\VEN_10DE&[a-z0-9_&-]+\\[a-z0-9_&-]+$') {
            throw "Invalid NVIDIA device instance path"
        }
        $driver = [string](Get-PnpDeviceProperty -InstanceId $id -KeyName "DEVPKEY_Device_Driver" -ErrorAction Stop).Data
        if ($driver -notmatch '^\{4d36e968-e325-11ce-bfc1-08002be10318\}\\[0-9]{4}$') {
            throw "Invalid NVIDIA display-class binding: $driver"
        }
        $enumPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$id"
        $boundDriver = Get-Reclaim11RegistrySnapshot -Path $enumPath -Name "Driver" -RequireKey
        if (-not $boundDriver.exists -or $boundDriver.kind -ne "String" -or $boundDriver.value -ine $driver) {
            throw "NVIDIA driver binding changed during discovery"
        }
        $video = Get-Reclaim11RegistrySnapshot -Path "$enumPath\Device Parameters" -Name "VideoID" -RequireKey
        $videoGuid = [guid]::Empty
        if (-not $video.exists -or $video.kind -ne "String" -or
            -not [guid]::TryParse([string]$video.value, [ref]$videoGuid) -or $videoGuid -eq [guid]::Empty) {
            throw "Missing or invalid NVIDIA VideoID"
        }
        $classPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$driver"
        $videoPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Video\$($videoGuid.ToString('B'))\0000"
        foreach ($path in @($classPath, $videoPath)) {
            $match = Get-Reclaim11RegistrySnapshot -Path $path -Name "MatchingDeviceId" -RequireKey
            if (-not $match.exists -or $match.kind -ne "String" -or
                [string]$match.value -notmatch '^PCI\\VEN_10DE&' -or
                -not $id.StartsWith(([string]$match.value), [StringComparison]::OrdinalIgnoreCase)) {
                throw "NVIDIA registry target does not match its present device: $path"
            }
            if ($seen.ContainsKey($path)) { throw "Ambiguous NVIDIA registry target: $path" }
            $seen[$path] = $true
        }
        [pscustomobject]@{ instance_id = $id; class_path = $classPath; video_path = $videoPath }
    }
}

function Assert-Reclaim11RegistryBinding {
    param($Row)
    if (-not $Row.PSObject.Properties["binding"] -or $null -eq $Row.binding) { return }
    switch ([string]$Row.binding.kind) {
        "tcp" {
            $guid = [guid]$Row.binding.guid
            if ($guid -eq [guid]::Empty) { throw "Invalid saved TCP interface GUID" }
            $targets = @(Get-Reclaim11TcpInterfaceTargets -Adapters @(Get-Reclaim11NetAdapters) -IncludeDisconnected -InterfaceGuid $guid)
            $target = @($targets | Where-Object { $_.guid -ieq $Row.binding.guid })
            if ($target.Count -ne 1 -or $Row.path -ine $target[0].path -or
                [string]$Row.name -notin @("TcpAckFrequency", "TCPNoDelay")) {
                throw "TCP registry target changed since backup: $($Row.path)"
            }
        }
        "nvidia" {
            $target = @(Get-Reclaim11NvidiaRegistryTargets | Where-Object { $_.instance_id -ieq $Row.binding.instance_id })
            if ($target.Count -ne 1) { throw "NVIDIA backup device is no longer uniquely present" }
            $paths = @($target[0].class_path)
            # Older backups recorded the two power values through the Video alias.
            if ($Row.name -in @("PowerMizerEnable", "PerfLevelSrc")) {
                $paths += $target[0].video_path
            }
            if ($Row.name -notin @("DisableLinesetting", "PowerMizerEnable", "PerfLevelSrc") -or $Row.path -notin $paths) {
                throw "NVIDIA registry target changed since backup: $($Row.path)"
            }
        }
        default { throw "Unknown registry device binding: $($Row.binding.kind)" }
    }
}

function New-Reclaim11RegistryWrite {
    param([string]$Path, [string]$Name, [int]$Wanted, $Binding)
    $before = Get-Reclaim11RegistrySnapshot -Path $Path -Name $Name -RequireKey:($null -ne $Binding)
    [pscustomobject]@{
        path = $Path
        name = $Name
        before = $before.value
        before_snapshot = $before
        wanted = $Wanted
        binding = $Binding
    }
}

function Restore-Reclaim11RegistryWrite {
    param($Row)
    Assert-Reclaim11RegistryBinding -Row $Row
    if ($Row.PSObject.Properties["before_snapshot"]) {
        Set-Reclaim11RegistrySnapshot -Path $Row.path -Name $Row.name -Snapshot $Row.before_snapshot -RequireKey:(
            $Row.PSObject.Properties["binding"] -and $null -ne $Row.binding
        )
    } else {
        $before = [pscustomobject]@{ exists = ($null -ne $Row.before); kind = "DWord"; value = $Row.before }
        Set-Reclaim11RegistrySnapshot -Path $Row.path -Name $Row.name -Snapshot $before
    }
}

function Get-Reclaim11GamingInspection {
    $games = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games"
    $specs = @(
        @{ path = $games; name = "GPU Priority" },
        @{ path = $games; name = "Priority" },
        @{ path = $games; name = "Scheduling Category" },
        @{ path = $games; name = "SFIO Priority" },
        @{ path = "HKLM:\SYSTEM\CurrentControlSet\Services\mouclass\Parameters"; name = "MouseDataQueueSize" },
        @{ path = "HKLM:\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters"; name = "KeyboardDataQueueSize" }
    )
    foreach ($spec in $specs) {
        [pscustomobject]@{ path = $spec.path; name = $spec.name; snapshot = Get-Reclaim11RegistrySnapshot -Path $spec.path -Name $spec.name }
    }
    $path = "HKLM:\SYSTEM\CurrentControlSet\Services\mouclass\Parameters"
    $key = Get-Reclaim11RegistryKey -Path $path
    $names = @()
    if ($null -ne $key) {
        try { $names = @($key.GetValueNames()) } finally { $key.Dispose() }
    }
    [pscustomobject]@{
        path = $path
        name = "(property names)"
        snapshot = [pscustomobject]@{ exists = ($null -ne $key); kind = "Names"; value = $names }
    }
}

function Format-Reclaim11Inspection {
    param($Item)
    $value = if ($Item.snapshot.exists) { ConvertTo-Json -InputObject $Item.snapshot.value -Compress } else { "(absent)" }
    "inspect $($Item.path) $($Item.name)=$value"
}

function Format-Reclaim11ActionReport {
    param($Plan, [string]$Title)
    $lines = @("$Title applied=$(@($Plan.applied).Count) failed=$(@($Plan.failed).Count)")
    if ($Plan.PSObject.Properties["skipped"]) {
        foreach ($item in @($Plan.skipped)) { $lines += "skip $item" }
    }
    if ($Plan.PSObject.Properties["inspection"]) {
        foreach ($item in @($Plan.inspection)) { $lines += Format-Reclaim11Inspection -Item $item }
    }
    foreach ($failure in @($Plan.failed)) { $lines += "FAIL $failure" }
    $lines -join [Environment]::NewLine
}
