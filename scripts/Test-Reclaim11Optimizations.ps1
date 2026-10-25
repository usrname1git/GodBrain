# Offline fixtures only: no real registry, adapter, BCD or power mutations.
[CmdletBinding()]
param(
    [string]$RepoRoot = "",
    [string]$ReceiptPath = "",
    [switch]$CaptureUi
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$ps1 = Join-Path $RepoRoot "godbrain_core\reclaim11\ps1"
foreach ($name in @("nic_tune.ps1", "latency_bake.ps1", "restore.ps1")) {
    . (Join-Path $ps1 $name)
}
$script:ReadRestoreManifests = ${function:Get-Reclaim11RestoreManifests}
$script:NativeBcdEdit = ${function:Invoke-Reclaim11BcdEdit}
$script:Cases = [System.Collections.Generic.List[string]]::new()
$script:Temp = Join-Path ([IO.Path]::GetTempPath()) ("reclaim11-offline-" + [guid]::NewGuid().ToString("N"))
$null = [IO.Directory]::CreateDirectory($script:Temp)
$script:Manifest = Join-Path $script:Temp "restore.json"
$script:TcpGuid = "{11111111-1111-4111-8111-111111111111}"
$script:TcpPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$script:TcpGuid"
$script:Device = "PCI\VEN_10DE&DEV_1234&SUBSYS_11111111&REV_A1\4&11111111&0&0008"
$script:Driver = "{4d36e968-e325-11ce-bfc1-08002be10318}\0007"
$script:ClassPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$script:Driver"
$script:VideoPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Video\{22222222-2222-4222-8222-222222222222}\0000"

class Reclaim11FixtureKey {
    [hashtable]$State
    [string]$Path
    [bool]$Writable
    Reclaim11FixtureKey([hashtable]$state, [string]$path, [bool]$writable) {
        $this.State = $state
        $this.Path = $path
        $this.Writable = $writable
    }
    [string[]] GetValueNames() { return [string[]]@($this.State.Registry[$this.Path].Keys) }
    [Microsoft.Win32.RegistryValueKind] GetValueKind([string]$name) {
        return [Microsoft.Win32.RegistryValueKind]$this.State.Registry[$this.Path][$name].kind
    }
    [object] GetValue([string]$name, [object]$fallback, [Microsoft.Win32.RegistryValueOptions]$options) {
        if ($options -ne [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) {
            throw "Snapshot expanded registry data"
        }
        if (-not $this.State.Registry[$this.Path].ContainsKey($name)) { return $fallback }
        return $this.State.Registry[$this.Path][$name].value
    }
    [void] SetValue([string]$name, [object]$value, [Microsoft.Win32.RegistryValueKind]$kind) {
        if (-not $this.Writable) { throw "Read-only handle used for a write" }
        if ($this.State.RequireBackup -and $this.State.Backups -eq 0) { throw "Write preceded backup" }
        if ($this.State.FailWrite -eq $name) { throw "Synthetic write refusal: $name" }
        $this.State.Events.Add("reg:$($this.Path):$name")
        if ($this.State.IgnoreWrite -eq $name) { return }
        $this.State.Registry[$this.Path][$name] = @{ kind = [string]$kind; value = $value }
    }
    [void] DeleteValue([string]$name, [bool]$throwOnMissing) {
        if (-not $this.Writable) { throw "Read-only handle used for a delete" }
        if ($this.State.RequireBackup -and $this.State.Backups -eq 0) { throw "Delete preceded backup" }
        if ($this.State.FailDelete -eq $name) { throw "Synthetic restore refusal: $name" }
        $this.State.Events.Add("delete:$($this.Path):$name")
        $this.State.Registry[$this.Path].Remove($name)
    }
    [void] Dispose() { }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Add-FixtureValue {
    param([string]$Path, [string]$Name, [string]$Kind, $Value)
    if (-not $script:F.Registry.ContainsKey($Path)) { $script:F.Registry[$Path] = @{} }
    $script:F.Registry[$Path][$Name] = @{ kind = $Kind; value = $Value }
}
function Add-FixtureGpu {
    param([string]$Id, [string]$DriverKey, [string]$VideoId)
    $script:F.Devices += [pscustomobject]@{ InstanceId = $Id; Present = $true }
    $script:F.Drivers[$Id] = $DriverKey
    $root = "HKLM:\SYSTEM\CurrentControlSet\Enum\$Id"
    Add-FixtureValue $root "Driver" "String" $DriverKey
    Add-FixtureValue "$root\Device Parameters" "VideoID" "String" $VideoId
    $class = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$DriverKey"
    $video = "HKLM:\SYSTEM\CurrentControlSet\Control\Video\$VideoId\0000"
    Add-FixtureValue $class "MatchingDeviceId" "String" "PCI\VEN_10DE&DEV_1234"
    Add-FixtureValue $video "MatchingDeviceId" "String" "PCI\VEN_10DE&DEV_1234"
    Add-FixtureValue $video "PowerMizerEnable" "DWord" 1
    Add-FixtureValue $video "PerfLevelSrc" "String" "original-mode"
}
function Reset-Fixture {
    $script:F = @{
        Registry = @{}; Devices = @(); Drivers = @{}; Events = [System.Collections.Generic.List[string]]::new()
        Backups = 0; Saved = @{}; RequireBackup = $true; FailBackup = $false
        FailWrite = ""; IgnoreWrite = ""; FailDelete = ""; DeniedPath = ""; FailDiscovery = $false
        NoDisplayClass = $false; NoAdapterObjects = $false
        Admin = $true; Pe = $false; Active = "381b4222-f694-41f0-9685-ff5bb260df2e"
        PowerMissing = $false; HpPresent = $true; RestoreItems = @()
        Bcd = @{ "{current}" = @{}; "{bootmgr}" = @{} }
        FailBcdRead = $false; FailBcdDelete = $false; BcdQueries = 0
        Adapters = @(
            [pscustomobject]@{ Name = "Ethernet"; InterfaceDescription = "Physical Ethernet"; PhysicalMediaType = "802.3"; Status = "Up"; HardwareInterface = $true; Virtual = $false; InterfaceGuid = $script:TcpGuid },
            [pscustomobject]@{ Name = "Ethernet down"; InterfaceDescription = "Physical Ethernet"; PhysicalMediaType = "802.3"; Status = "Disconnected"; HardwareInterface = $true; Virtual = $false; InterfaceGuid = "{33333333-3333-4333-8333-333333333333}" },
            [pscustomobject]@{ Name = "Tailscale"; InterfaceDescription = "Virtual"; PhysicalMediaType = "802.3"; Status = "Up"; HardwareInterface = $false; Virtual = $true; InterfaceGuid = "{44444444-4444-4444-8444-444444444444}" },
            [pscustomobject]@{ Name = "Wi-Fi"; InterfaceDescription = "Wireless"; PhysicalMediaType = "802.11"; Status = "Up"; HardwareInterface = $true; Virtual = $false; InterfaceGuid = "{55555555-5555-4555-8555-555555555555}" }
        )
    }
    foreach ($row in $script:BcdCurrent) { $script:F.Bcd["{current}"][$row.Name] = "old" }
    foreach ($row in $script:BcdBootmgr) { $script:F.Bcd["{bootmgr}"][$row.Name] = "old" }
    foreach ($row in $script:RegBake) { Add-FixtureValue $row.Path $row.Name "DWord" 100 }
    Add-FixtureValue $script:TcpPath "TcpAckFrequency" "String" "original-ack"
    Add-FixtureGpu $script:Device $script:Driver "{22222222-2222-4222-8222-222222222222}"
    $script:F.Devices += [pscustomobject]@{ InstanceId = "PCI\VEN_1002&DEV_1234\AMD"; Present = $true }
    $script:F.Devices += [pscustomobject]@{ InstanceId = "PCI\VEN_10DE&DEV_1234\STALE"; Present = $false }
    $games = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games"
    Add-FixtureValue $games "GPU Priority" "DWord" 8
    Add-FixtureValue $games "Priority" "DWord" 6
    Add-FixtureValue $games "Scheduling Category" "String" "High"
    Add-FixtureValue $games "SFIO Priority" "String" "High"
    Add-FixtureValue "HKLM:\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters" "KeyboardDataQueueSize" "DWord" 100
}
function Invoke-FixtureCase {
    param([string]$Name, [scriptblock]$Body)
    Reset-Fixture
    try { & $Body } catch { throw "$Name -- $($_.Exception.Message)" }
    $script:Cases.Add($Name)
}
function Get-Reclaim11RegistryKey {
    param([string]$Path, [switch]$RequireKey, [switch]$Writable)
    if ($script:F.DeniedPath -eq $Path) { throw [UnauthorizedAccessException]::new("Synthetic registry access denied") }
    if (-not $script:F.Registry.ContainsKey($Path)) {
        if ($RequireKey) { throw "Registry target is missing: $Path" }
        return $null
    }
    [Reclaim11FixtureKey]::new($script:F, $Path, [bool]$Writable)
}
function New-Item {
    [CmdletBinding()]
    param([string]$Path, [switch]$Force)
    if (-not $Path.StartsWith("HKLM:\", [StringComparison]::OrdinalIgnoreCase)) { throw "Unexpected fixture create: $Path" }
    if ($script:F.RequireBackup -and $script:F.Backups -eq 0) { throw "Create preceded backup" }
    $script:F.Registry[$Path] = @{}
    $script:F.Events.Add("create:$Path")
}
function Get-NetAdapter {
    [CmdletBinding()]
    param([switch]$Physical, [switch]$IncludeHidden)
    if ($script:F.NoAdapterObjects) {
        $PSCmdlet.ThrowTerminatingError([Management.Automation.ErrorRecord]::new(
            [Exception]::new("No network adapters"), "CmdletizationQuery_NotFound",
            [Management.Automation.ErrorCategory]::ObjectNotFound, $null))
    }
    $script:F.Adapters
}
function Get-NetAdapterAdvancedProperty {
    [CmdletBinding()]
    param([string]$Name)
}
function Set-NetAdapterAdvancedProperty {
    [CmdletBinding()]
    param($Name, $RegistryKeyword, $RegistryValue, [switch]$NoRestart)
    if ($script:F.Backups -eq 0) { throw "Adapter mutation preceded backup" }
    $script:F.Events.Add("adapter:$RegistryKeyword")
}
function Get-PnpDevice {
    [CmdletBinding()]
    param([string]$Class, [switch]$PresentOnly)
    if ($script:F.FailDiscovery) { throw "Synthetic device discovery failure" }
    if ($script:F.NoDisplayClass) {
        $PSCmdlet.ThrowTerminatingError([Management.Automation.ErrorRecord]::new(
            [Exception]::new("No Display class"), "CmdletizationQuery_NotFound_Class",
            [Management.Automation.ErrorCategory]::ObjectNotFound, "Display"))
    }
    Assert-True ($Class -eq "Display" -and $PresentOnly) "Non-present display enumeration requested"
    $script:F.Devices | Where-Object { $_.Present }
}
function Get-PnpDeviceProperty {
    [CmdletBinding()]
    param([string]$InstanceId, [string]$KeyName)
    Assert-True ($KeyName -eq "DEVPKEY_Device_Driver" -and $script:F.Drivers.ContainsKey($InstanceId)) "Unexpected device-property lookup"
    [pscustomobject]@{ Data = $script:F.Drivers[$InstanceId] }
}
function Test-Reclaim11Admin { $script:F.Admin }
function Test-Reclaim11PeHost { $script:F.Pe }
function Invoke-Reclaim11BcdEdit {
    param($BcdArgs)
    if ($BcdArgs[0] -eq "/enum") {
        $script:F.BcdQueries++
        if ($script:F.FailBcdRead) { throw "Synthetic BCD enumeration failure" }
        return @($script:F.Bcd[$BcdArgs[1]].GetEnumerator() | ForEach-Object { "$($_.Key) $($_.Value)" }) -join "`n"
    }
    if ($script:F.Backups -eq 0) { throw "BCD mutation preceded backup" }
    $script:F.Events.Add("bcd:" + ($BcdArgs -join " "))
    switch ($BcdArgs[0]) {
        "/set" { $script:F.Bcd[$BcdArgs[1]][$BcdArgs[2]] = $BcdArgs[3] }
        "/deletevalue" {
            if ($script:F.FailBcdDelete) { throw "Synthetic BCD access denied" }
            if (-not $script:F.Bcd[$BcdArgs[1]].ContainsKey($BcdArgs[2])) { throw "Element not found" }
            $script:F.Bcd[$BcdArgs[1]].Remove($BcdArgs[2])
        }
        default { throw "Unapproved BCD operation: $($BcdArgs -join ' ')" }
    }
}
function Invoke-Reclaim11PowerCfg {
    param([string[]]$PowerArgs, [switch]$AllowFail)
    switch ($PowerArgs[0]) {
        "/getactivescheme" { return "Omdopt: $($script:F.Active)" }
        "/list" {
            if ($script:F.HpPresent) { return "$($script:F.Active)`n$script:PowerHighPerfGuid (Omdopt)" }
            return $script:F.Active
        }
        "/qh" {
            if ($script:F.PowerMissing) { return "Unavailable" }
            Assert-True (@($script:PowerAcBake | Where-Object { $_.Sub -eq $PowerArgs[2] -and $_.Setting -eq $PowerArgs[3] }).Count -eq 1) "Wrong power identifiers"
            return "Current AC Power Setting Index: 0x00000001"
        }
        { $_ -in @("/setacvalueindex", "/setactive") } {
            if ($script:F.Backups -eq 0) { throw "Power mutation preceded backup" }
            $script:F.Events.Add("power:" + ($PowerArgs -join " "))
            return ""
        }
        default { throw "Unapproved power operation: $($PowerArgs -join ' ')" }
    }
}
function Write-FixtureManifest {
    param($Manifest, [string]$Path)
    if ($script:F.FailBackup) { throw "Synthetic backup refusal" }
    $script:F.Saved[$Path] = $Manifest | ConvertTo-Json -Depth 12
    $script:F.Backups++
    $script:F.Events.Add("backup")
}
function Write-Reclaim11NicManifest { param($Manifest, $Path) Write-FixtureManifest $Manifest $Path }
function Write-Reclaim11LatencyManifest { param($Manifest, $Path) Write-FixtureManifest $Manifest $Path }
function Save-FixtureRestore {
    param($Plan)
    [IO.File]::WriteAllText($script:Manifest, $script:F.Saved[$Plan.manifest_path])
}
function Get-Reclaim11RestoreManifests { $script:F.RestoreItems }
function Get-Reclaim11BackupRoot { $script:Temp }

try {
    Invoke-FixtureCase "TCP discovery excludes disconnected, virtual and wireless adapters" {
        $targets = @(Get-Reclaim11TcpInterfaceTargets -Adapters $script:F.Adapters)
        Assert-True ($targets.Count -eq 1 -and $targets[0].path -eq $script:TcpPath) "Wrong TCP targets"
    }
    Invoke-FixtureCase "NVIDIA discovery follows present device to class 0007 and its VideoID" {
        $targets = @(Get-Reclaim11NvidiaRegistryTargets)
        Assert-True ($targets.Count -eq 1 -and $targets[0].class_path -eq $script:ClassPath -and $targets[0].video_path -eq $script:VideoPath) "Wrong NVIDIA mapping"
    }
    Invoke-FixtureCase "Multiple NVIDIA cards are mapped independently" {
        Add-FixtureGpu "PCI\VEN_10DE&DEV_1234\SECOND" "{4d36e968-e325-11ce-bfc1-08002be10318}\0008" "{66666666-6666-4666-8666-666666666666}"
        Assert-True (@(Get-Reclaim11NvidiaRegistryTargets).Count -eq 2) "Lost second GPU"
    }
    Invoke-FixtureCase "NIC TEST lists both TCP writes even without advanced-property actions" {
        $plan = Invoke-Reclaim11NicTune -Root $RepoRoot -WhatIf
        Assert-True ($plan.registry.Count -eq 2 -and $plan.actions.Count -eq 0) "Missing TCP rows"
        Assert-True (@($plan.would | Where-Object { $_ -like "reg *" }).Count -eq 2) "Missing TCP TEST lines"
        Assert-True ($script:F.Backups -eq 0 -and $script:F.Events.Count -eq 0) "TEST mutated"
    }
    Invoke-FixtureCase "Latency TEST includes NVIDIA, mouse and every read-only inspection" {
        $plan = Invoke-Reclaim11LatencyBake -Root $RepoRoot -WhatIf
        Assert-True ($plan.registry.Count -eq 7 -and $plan.inspection.Count -eq 7) "Incomplete latency plan"
        Assert-True (@($plan.would | Where-Object { $_ -like "inspect *" }).Count -eq 7) "Missing inspections"
        Assert-True (@($plan.registry | Where-Object { $_.name -eq "PerfLevelSrc" -and $_.wanted -eq 3322 }).Count -eq 1) "PerfLevelSrc changed base"
        Assert-True ($script:F.Backups -eq 0 -and $script:F.Events.Count -eq 0 -and -not $plan.power_switch_high_performance) "TEST mutated or implicitly switched"
    }
    Invoke-FixtureCase "TCP apply backs up first, reads back DWORDs and restores type/absence" {
        $plan = Invoke-Reclaim11NicTune -Root $RepoRoot
        Assert-True ($plan.failed.Count -eq 0 -and $plan.applied.Count -eq 2 -and $script:F.Events[0] -eq "backup") "TCP apply failed: $($plan.failed -join '; ')"
        Assert-True ($script:F.Registry[$script:TcpPath].TcpAckFrequency.kind -eq "DWord" -and $script:F.Registry[$script:TcpPath].TcpAckFrequency.value -eq 1) "TCP not stored as DWORD1"
        Save-FixtureRestore $plan
        $restore = Restore-Reclaim11NicBackup -Manifest $script:Manifest
        Assert-True ($restore.failed.Count -eq 0 -and $script:F.Registry[$script:TcpPath].TcpAckFrequency.kind -eq "String" -and $script:F.Registry[$script:TcpPath].TcpAckFrequency.value -eq "original-ack") "TCP original type/data not restored"
        Assert-True (-not $script:F.Registry[$script:TcpPath].ContainsKey("TCPNoDelay")) "Originally absent TCP value retained"
    }
    Invoke-FixtureCase "NVIDIA/mouse apply and restore preserve exact values, types and absence" {
        $plan = Invoke-Reclaim11LatencyBake -Root $RepoRoot
        Assert-True ($plan.failed.Count -eq 0 -and $script:F.Events[0] -eq "backup") "Latency apply failed: $($plan.failed -join '; ')"
        Assert-True ($script:F.Registry[$script:ClassPath].DisableLinesetting.value -eq 1 -and $script:F.Registry[$script:VideoPath].PowerMizerEnable.value -eq 0 -and $script:F.Registry[$script:VideoPath].PerfLevelSrc.value -eq 3322) "Wrong NVIDIA values"
        Assert-True (@($script:F.Events | Where-Object { $_ -match ':(GPU Priority|Priority|Scheduling Category|SFIO Priority|KeyboardDataQueueSize)$' }).Count -eq 0) "Inspection caused a write"
        Save-FixtureRestore $plan
        $restore = Restore-Reclaim11LatencyBackup -Manifest $script:Manifest
        Assert-True ($restore.failed.Count -eq 0 -and -not $script:F.Registry[$script:ClassPath].ContainsKey("DisableLinesetting")) "Absent NVIDIA value not restored"
        Assert-True ($script:F.Registry[$script:VideoPath].PerfLevelSrc.kind -eq "String" -and $script:F.Registry[$script:VideoPath].PerfLevelSrc.value -eq "original-mode") "NVIDIA original type/data lost"
    }
    Invoke-FixtureCase "Repeated direct and aggregate restores preserve originally absent BCD elements" {
        $script:F.Bcd["{current}"].Remove("useplatformclock")
        $plan = Invoke-Reclaim11LatencyBake -Root $RepoRoot
        Save-FixtureRestore $plan
        foreach ($attempt in 1..2) {
            $result = Restore-Reclaim11LatencyBackup -Manifest $script:Manifest
            Assert-True ($result.failed.Count -eq 0 -and -not $script:F.Bcd["{current}"].ContainsKey("useplatformclock")) "Repeated BCD restore failed on attempt $attempt"
        }
        $script:F.RestoreItems = @([pscustomobject]@{ kind = "latency"; path = $script:Manifest; id = $plan.id })
        $result = Restore-Reclaim11Selected -Kinds @("latency") -Root $RepoRoot
        Assert-True ($result.failed.Count -eq 0) "Aggregate replay reported an already restored BCD element as failed"
        Assert-True (@($script:F.Events | Where-Object { $_ -eq "bcd:/deletevalue {current} useplatformclock" }).Count -eq 1) "Already absent BCD element was deleted again"
        Assert-True ($script:F.BcdQueries -gt 0) "BCD absence was not confirmed through the production reader"
    }
    Invoke-FixtureCase "BCD delete refusal remains an aggregate restore failure" {
        $script:F.Bcd["{current}"].Remove("useplatformclock")
        $plan = Invoke-Reclaim11LatencyBake -Root $RepoRoot
        Save-FixtureRestore $plan
        $script:F.FailBcdDelete = $true
        $script:F.RestoreItems = @([pscustomobject]@{ kind = "latency"; path = $script:Manifest; id = $plan.id })
        $result = Restore-Reclaim11Selected -Kinds @("latency") -Root $RepoRoot
        Assert-True ($result.failed.Count -eq 1 -and $result.failed[0] -match "BCD access denied") "Genuine BCD delete failure was hidden"
        Assert-True ($script:F.Bcd["{current}"].useplatformclock -eq "No") "Failed BCD deletion mutated the element"
    }
    Invoke-FixtureCase "Failed BCD enumeration cannot confirm restore absence" {
        $script:F.Bcd["{current}"].Remove("useplatformclock")
        $plan = Invoke-Reclaim11LatencyBake -Root $RepoRoot
        Save-FixtureRestore $plan
        $script:F.FailBcdRead = $true
        $result = Restore-Reclaim11LatencyBackup -Manifest $script:Manifest
        Assert-True ($result.failed.Count -eq 1 -and $result.failed[0] -match "BCD enumeration failure") "Failed BCD read was mistaken for absence"
        Assert-True (@($script:F.Events | Where-Object { $_ -like "bcd:/deletevalue*" }).Count -eq 0) "Deletion followed an unsuccessful BCD read"
    }
    Invoke-FixtureCase "BCD backup read failure prevents tuning mutations" {
        $script:F.FailBcdRead = $true
        $errorText = ""
        try { Invoke-Reclaim11LatencyBake -Root $RepoRoot | Out-Null } catch { $errorText = $_.Exception.Message }
        Assert-True ($errorText -match "BCD enumeration failure" -and $script:F.Backups -eq 0 -and $script:F.Events.Count -eq 0) "Unread BCD state became an absent-before backup"
    }
    Invoke-FixtureCase "Unavailable BCD executable fails despite a stale successful exit code" {
        $oldRoot = $env:SystemRoot
        $oldPreference = $ErrorActionPreference
        $errorText = ""
        try {
            $env:SystemRoot = $script:Temp
            $global:LASTEXITCODE = 0
            try { & $script:NativeBcdEdit -BcdArgs @("/enum", "{current}") | Out-Null } catch { $errorText = $_.Exception.Message }
        } finally {
            $env:SystemRoot = $oldRoot
        }
        Assert-True (-not [string]::IsNullOrWhiteSpace($errorText) -and $ErrorActionPreference -eq $oldPreference) "Failed invocation became a successful empty BCD read or changed error handling"
    }
    Invoke-FixtureCase "Snapshots round-trip all supported registry kinds through JSON" {
        $script:F.RequireBackup = $false
        $path = "HKLM:\RECLAIM11_FIXTURE\Types"
        foreach ($spec in @(
            @{ kind = "DWord"; value = -1 }, @{ kind = "QWord"; value = [long]9223372036854775806 },
            @{ kind = "String"; value = "" }, @{ kind = "ExpandString"; value = "%UNCHANGED%\file" },
            @{ kind = "MultiString"; value = @("A", "b") }, @{ kind = "Binary"; value = [byte[]]@(0, 128, 255) },
            @{ kind = "None"; value = [byte[]]@(1, 2) }
        )) {
            Add-FixtureValue $path "Typed" $spec.kind $spec.value
            $before = Get-Reclaim11RegistrySnapshot -Path $path -Name "Typed"
            $roundTrip = $before | ConvertTo-Json -Depth 6 | ConvertFrom-Json
            Set-Reclaim11RegistryDword -Path $path -Name "Typed" -Value 1
            Set-Reclaim11RegistrySnapshot -Path $path -Name "Typed" -Snapshot $roundTrip
            Assert-True (Test-Reclaim11RegistrySnapshotEqual $before (Get-Reclaim11RegistrySnapshot $path "Typed")) "Typed round trip failed: $($spec.kind)"
        }
    }
    Invoke-FixtureCase "Missing hardware produces explicit skips rather than phantom keys" {
        $script:F.Devices = @()
        $script:F.Adapters = @()
        $nic = Invoke-Reclaim11NicTune -Root $RepoRoot -WhatIf
        $latency = Invoke-Reclaim11LatencyBake -Root $RepoRoot -WhatIf
        Assert-True ($nic.registry.Count -eq 0 -and $nic.skipped.Count -gt 0 -and $latency.registry.Count -eq 4 -and $latency.skipped.Count -gt 0) "Missing hardware not reported"
        Assert-True ($script:F.Events.Count -eq 0) "Missing hardware created keys"
    }
    Invoke-FixtureCase "Native no-object errors are hardware absence, not discovery success or writes" {
        $script:F.NoDisplayClass = $true
        $script:F.NoAdapterObjects = $true
        $nic = Invoke-Reclaim11NicTune -Root $RepoRoot -WhatIf
        $latency = Invoke-Reclaim11LatencyBake -Root $RepoRoot -WhatIf
        Assert-True ($nic.registry.Count -eq 0 -and $nic.would_refuse -eq "no physical Ethernet" -and $latency.skipped.Count -gt 0 -and $script:F.Events.Count -eq 0) "Native missing-hardware result mishandled"
    }
    Invoke-FixtureCase "Missing inspection values are reported without guessed replacements" {
        $path = "HKLM:\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters"
        $script:F.Registry.Remove($path)
        $plan = Invoke-Reclaim11LatencyBake -Root $RepoRoot -WhatIf
        $item = @($plan.inspection | Where-Object { $_.name -eq "KeyboardDataQueueSize" })
        Assert-True ($item.Count -eq 1 -and -not $item[0].snapshot.exists -and @($plan.registry | Where-Object { $_.name -eq "KeyboardDataQueueSize" }).Count -eq 0) "Missing inspection became a write"
    }
    Invoke-FixtureCase "Backup failure prevents all profile mutations" {
        $script:F.FailBackup = $true
        foreach ($command in @("Invoke-Reclaim11NicTune", "Invoke-Reclaim11LatencyBake")) {
            $errorText = ""
            try { & $command -Root $RepoRoot | Out-Null } catch { $errorText = $_.Exception.Message }
            Assert-True ($errorText -eq "Synthetic backup refusal" -and $script:F.Events.Count -eq 0) "Mutation after failed backup"
        }
    }
    Invoke-FixtureCase "Read denial and malformed device identity fail before backup" {
        $script:F.DeniedPath = $script:VideoPath
        $errorText = ""
        try { Invoke-Reclaim11LatencyBake -Root $RepoRoot -WhatIf | Out-Null } catch { $errorText = $_.Exception.Message }
        Assert-True ($errorText -match "access denied" -and $script:F.Events.Count -eq 0) "Denied read became absent data"
        $script:F.DeniedPath = ""
        $script:F.Registry["HKLM:\SYSTEM\CurrentControlSet\Enum\$script:Device\Device Parameters"].VideoID.value = "not-a-guid"
        $errorText = ""
        try { Invoke-Reclaim11LatencyBake -Root $RepoRoot | Out-Null } catch { $errorText = $_.Exception.Message }
        Assert-True ($errorText -match "VideoID" -and $script:F.Backups -eq 0) "Bad VideoID was accepted"
    }
    Invoke-FixtureCase "Discovery failure is not converted to a no-GPU skip" {
        $script:F.FailDiscovery = $true
        $errorText = ""
        try { Invoke-Reclaim11LatencyBake -Root $RepoRoot -WhatIf | Out-Null } catch { $errorText = $_.Exception.Message }
        Assert-True ($errorText -match "discovery failure" -and $script:F.Events.Count -eq 0) "Discovery failure hidden"
    }
    Invoke-FixtureCase "Foreign-vendor and ambiguous video targets are rejected" {
        $script:F.Registry[$script:VideoPath].MatchingDeviceId.value = "PCI\VEN_1002&DEV_1234"
        $errorText = ""
        try { Get-Reclaim11NvidiaRegistryTargets | Out-Null } catch { $errorText = $_.Exception.Message }
        Assert-True ($errorText -match "does not match") "Foreign vendor accepted"
        $script:F.Registry[$script:VideoPath].MatchingDeviceId.value = "PCI\VEN_10DE&DEV_1234"
        Add-FixtureGpu "PCI\VEN_10DE&DEV_1234\SECOND" "{4d36e968-e325-11ce-bfc1-08002be10318}\0008" "{22222222-2222-4222-8222-222222222222}"
        $errorText = ""
        try { Get-Reclaim11NvidiaRegistryTargets | Out-Null } catch { $errorText = $_.Exception.Message }
        Assert-True ($errorText -match "Ambiguous") "Ambiguous video mapping accepted"
    }
    Invoke-FixtureCase "Registry write errors are explicit failures, not applied receipts" {
        $script:F.FailWrite = "PerfLevelSrc"
        $plan = Invoke-Reclaim11LatencyBake -Root $RepoRoot
        Assert-True (@($plan.failed | Where-Object { $_ -match "PerfLevelSrc.*Synthetic write refusal" }).Count -eq 1 -and @($plan.applied | Where-Object { $_ -match "PerfLevelSrc" }).Count -eq 0) "Write failure misreported"
        Assert-True ((Format-Reclaim11ActionReport $plan "Latency") -match "FAIL.*PerfLevelSrc") "GUI report hides failure"
    }
    Invoke-FixtureCase "Successful calls with wrong readback cannot claim TCP success" {
        $script:F.IgnoreWrite = "TcpAckFrequency"
        $plan = Invoke-Reclaim11NicTune -Root $RepoRoot
        Assert-True (@($plan.failed | Where-Object { $_ -match "readback mismatch" }).Count -eq 1 -and @($plan.applied | Where-Object { $_ -match "TcpAckFrequency" }).Count -eq 0) "Readback mismatch ignored"
    }
    Invoke-FixtureCase "Restore failure reaches the aggregate restore result" {
        $plan = Invoke-Reclaim11LatencyBake -Root $RepoRoot
        Save-FixtureRestore $plan
        $script:F.FailDelete = "DisableLinesetting"
        $script:F.RestoreItems = @([pscustomobject]@{ kind = "latency"; path = $script:Manifest; id = $plan.id })
        $result = Restore-Reclaim11Selected -Kinds @("latency") -Root $RepoRoot
        Assert-True ($result.failed.Count -eq 1 -and $result.failed[0] -match "Synthetic restore refusal") "Aggregate restore hid failure"
    }
    Invoke-FixtureCase "Changed NVIDIA identity blocks old-target restoration" {
        $plan = Invoke-Reclaim11LatencyBake -Root $RepoRoot
        Save-FixtureRestore $plan
        $script:F.Drivers[$script:Device] = "{4d36e968-e325-11ce-bfc1-08002be10318}\0009"
        $result = Restore-Reclaim11LatencyBackup -Manifest $script:Manifest
        Assert-True (@($result.failed | Where-Object { $_ -match "reg:.*(DisableLinesetting|PowerMizerEnable|PerfLevelSrc)" }).Count -eq 3 -and $script:F.Registry[$script:ClassPath].DisableLinesetting.value -eq 1) "Changed GPU target was modified"
    }
    Invoke-FixtureCase "Changed NIC identity blocks old-interface restoration" {
        $plan = Invoke-Reclaim11NicTune -Root $RepoRoot
        Save-FixtureRestore $plan
        $script:F.Adapters[0].InterfaceGuid = "{77777777-7777-4777-8777-777777777777}"
        $newPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($script:F.Adapters[0].InterfaceGuid)"
        Add-FixtureValue $newPath "TcpAckFrequency" "DWord" 9
        $result = Restore-Reclaim11NicBackup -Manifest $script:Manifest
        Assert-True ($result.failed.Count -eq 2 -and $script:F.Registry[$newPath].TcpAckFrequency.value -eq 9) "Changed NIC target was modified"
    }
    Invoke-FixtureCase "The original physical interface can be restored while disconnected" {
        $plan = Invoke-Reclaim11NicTune -Root $RepoRoot
        Save-FixtureRestore $plan
        $script:F.Adapters[0].Status = "Disconnected"
        $result = Restore-Reclaim11NicBackup -Manifest $script:Manifest
        Assert-True ($result.failed.Count -eq 0 -and $script:F.Registry[$script:TcpPath].TcpAckFrequency.value -eq "original-ack") "Disconnected original NIC could not be restored"
    }
    Invoke-FixtureCase "Older NIC and latency restore manifests remain supported" {
        [IO.File]::WriteAllText($script:Manifest, '{"id":"reclaim11-nic-v1","actions":[]}')
        Assert-True ((Restore-Reclaim11NicBackup -Manifest $script:Manifest).failed.Count -eq 0) "Old NIC restore failed"
        $script:F.RequireBackup = $false
        $old = @{ id = "reclaim11-latency-v1"; bcd = @(); power = @(); power_active = ""; registry = @(@{ path = $script:ClassPath; name = "Legacy"; before = 123 }, @{ path = $script:ClassPath; name = "OriginallyAbsent"; before = $null }) }
        [IO.File]::WriteAllText($script:Manifest, ($old | ConvertTo-Json -Depth 8))
        $result = Restore-Reclaim11LatencyBackup -Manifest $script:Manifest
        Assert-True ($result.failed.Count -eq 0 -and $script:F.Registry[$script:ClassPath].Legacy.value -eq 123 -and -not $script:F.Registry[$script:ClassPath].ContainsKey("OriginallyAbsent")) "Old latency restore failed"
    }
    Invoke-FixtureCase "Admin, WinPE and protected-plan gates stay mutation-free" {
        foreach ($gate in @("admin", "pe")) {
            $script:F.Admin = ($gate -ne "admin")
            $script:F.Pe = ($gate -eq "pe")
            foreach ($command in @("Invoke-Reclaim11NicTune", "Invoke-Reclaim11LatencyBake")) {
                $errorText = ""
                try { & $command -Root $RepoRoot | Out-Null } catch { $errorText = $_.Exception.Message }
                Assert-True ($errorText -match "^Refuse:" -and $script:F.Events.Count -eq 0) "$gate guard failed"
            }
        }
        $script:F.Admin = $true
        $script:F.Pe = $false
        foreach ($guid in $script:PowerForbiddenGuid) {
            $script:F.Active = $guid
            $errorText = ""
            try { Invoke-Reclaim11LatencyBake -Root $RepoRoot | Out-Null } catch { $errorText = $_.Exception.Message }
            Assert-True ($errorText -match "^Refuse:" -and $script:F.Events.Count -eq 0) "Protected plan mutated"
        }
    }
    Invoke-FixtureCase "Power selection, missing settings and unique backups remain bounded" {
        $dry = Invoke-Reclaim11LatencyBake -Root $RepoRoot -WhatIf -SwitchHighPerformance
        Assert-True ($dry.power_switch_high_performance -and $script:F.Events.Count -eq 0) "Explicit-switch preview failed"
        $script:F.HpPresent = $false
        $script:F.PowerMissing = $true
        $latency = Invoke-Reclaim11LatencyBake -Root $RepoRoot -SwitchHighPerformance
        Assert-True (-not $latency.power_switch_high_performance -and @($script:F.Events | Where-Object { $_ -like "power:*" }).Count -eq 0) "Missing plan/settings fabricated"
        $nic = Invoke-Reclaim11NicTune -Root $RepoRoot
        Assert-True ($latency.manifest_path -ne $nic.manifest_path -and $script:F.Saved.Count -eq 2) "Backups collided"
    }

    Invoke-FixtureCase "Documented power identifiers match the implemented scheme, subgroups and settings" {
        $readme = Get-Content -LiteralPath (Join-Path $RepoRoot "godbrain_core\reclaim11\README.md") -Raw
        foreach ($id in @($script:PowerHighPerfGuid) + @($script:PowerAcBake | ForEach-Object { $_.Sub; $_.Setting })) {
            Assert-True ($readme.Contains($id)) "README omits implemented power identifier $id"
        }
        Assert-True ($readme.Contains("Current AC Power Setting Index")) "README must identify the current locale-dependent parser"
    }
    Invoke-FixtureCase "PREP prefers v13 and preserves explicit legacy ISO discovery" {
        $tokens = $null
        $errors = $null
        $source = Get-Content -LiteralPath (Join-Path $ps1 "Reclaim11.ps1") -Raw -Encoding UTF8
        $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
        Assert-True ($errors.Count -eq 0) "Launcher parse failed"
        $helper = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Get-Reclaim11PrepIsoPath"
        }, $true)
        Assert-True ($null -ne $helper) "Missing ISO discovery helper"
        & {
            function Test-Path {
                param([string]$LiteralPath)
                $isoFiles -contains (Split-Path -Leaf $LiteralPath)
            }
            . ([scriptblock]::Create($helper.Extent.Text))
            $isoFiles = @("Reclaim11-WinPE-v12.iso", "Reclaim11-WinPE-v13.iso")
            $info = Get-Reclaim11PrepIsoPath
            Assert-True ($info.have -and $info.iso -eq "C:\Reclaim11\Reclaim11-WinPE-v13.iso") "v13 was not preferred"
            $isoFiles = @("Reclaim11-WinPE-v12.iso")
            $info = Get-Reclaim11PrepIsoPath
            Assert-True ($info.have -and $info.iso -eq "C:\Reclaim11\Reclaim11-WinPE-v12.iso") "Legacy ISO discovery changed"
            $isoFiles = @()
            $info = Get-Reclaim11PrepIsoPath
            Assert-True (-not $info.have -and $info.want -eq "C:\Reclaim11\Reclaim11-WinPE-v13.iso") "Missing ISO did not request a v13 build"
        }
    }
    Invoke-FixtureCase "Restore order uses exact receipt times across same-second legacy/new stamps" {
        $specs = @(
            @{ stamp = "20261024T120000Z"; at = "2026-10-24T12:00:00.9000000Z" },
            @{ stamp = "20261024T120000Z-0000001-fixture"; at = "2026-10-24T12:00:00.1000000Z" },
            @{ stamp = "20261024T120000Z-0000002-fixture"; at = "2026-10-24T13:00:00.0500000+01:00" },
            @{ stamp = "invalid-time-fixture"; at = "not-a-timestamp" }
        )
        $dirs = @()
        try {
            foreach ($spec in $specs) {
                $dir = Join-Path $script:Temp $spec.stamp
                $null = [IO.Directory]::CreateDirectory($dir)
                $dirs += $dir
                if ($spec.at -eq "not-a-timestamp") { continue }
                [IO.File]::WriteAllText((Join-Path $dir "restore.json"), (
                    @{ id = "reclaim11-nic-v1"; at = $spec.at } | ConvertTo-Json
                ))
            }
            $items = @(& $script:ReadRestoreManifests)
            Assert-True (($items.stamp -join "|") -eq (($specs[0..2].stamp) -join "|")) "Same-second restore chronology changed with legacy/new directory formats or lost timestamp precision"
            [IO.File]::WriteAllText((Join-Path $dirs[3] "restore.json"), (
                @{ id = "reclaim11-nic-v1"; at = $specs[3].at } | ConvertTo-Json
            ))
            $rejected = $false
            try { $null = & $script:ReadRestoreManifests } catch { $rejected = $_.Exception.Message -like "*Invalid restore timestamp*" }
            Assert-True $rejected "An invalid timestamp silently acquired a restore position"
        } finally {
            foreach ($dir in $dirs) {
                $file = Join-Path $dir "restore.json"
                if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) }
                [IO.Directory]::Delete($dir, $false)
            }
        }
    }
    foreach ($path in @("inventory.ps1", "nic_tune.ps1", "latency_bake.ps1", "restore.ps1", "Reclaim11.ps1")) {
        $tokens = $null; $errors = $null
        $source = [IO.File]::ReadAllText((Join-Path $ps1 $path), [Text.Encoding]::UTF8)
        $null = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
        Assert-True ($errors.Count -eq 0) "Parse errors in $path"
    }
    $script:Cases.Add("Affected UTF-8 source syntax parses; GUI execution is not part of the PS5.1 fixtures")
    if ($CaptureUi) {
        if ([string]::IsNullOrWhiteSpace($ReceiptPath)) { throw "-CaptureUi needs -ReceiptPath for its images" }
        Add-Type -AssemblyName PresentationFramework, PresentationCore
        [System.Windows.Media.RenderOptions]::ProcessRenderMode = "SoftwareOnly"
        $reader = [Xml.XmlReader]::Create([IO.StringReader]::new([IO.File]::ReadAllText((Join-Path $RepoRoot "godbrain_core\reclaim11\ui\MainWindow.xaml"))))
        try { $window = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Dispose() }
        $window.ShowActivated = $false; $window.ShowInTaskbar = $false
        $window.WindowStartupLocation = "Manual"; $window.Left = -20000; $window.Top = -20000
        try {
            foreach ($name in @("BtnNoobNic", "BtnNoobLatency", "RowNic", "RowLatency")) {
                $control = $window.FindName($name)
                Assert-True ($null -ne $control) "Missing control $name"
                for ($node = $control; $null -ne $node; $node = [Windows.LogicalTreeHelper]::GetParent($node)) {
                    if ($node -is [Windows.UIElement]) { $node.Visibility = "Visible" }
                }
                $window.Show(); $window.UpdateLayout()
                $window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
                $width = [int][Math]::Ceiling($control.ActualWidth)
                $height = [int][Math]::Ceiling($control.ActualHeight)
                Assert-True ($width -gt 0 -and $height -gt 0) "Empty UI layout $name"
                $visual = [Windows.Media.DrawingVisual]::new()
                $drawing = $visual.RenderOpen()
                try { $drawing.DrawRectangle([Windows.Media.VisualBrush]::new($control), $null, [Windows.Rect]::new(0, 0, $width, $height)) } finally { $drawing.Close() }
                $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new($width, $height, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
                $bitmap.Render($visual)
                $pixels = [byte[]]::new($width * $height * 4)
                $bitmap.CopyPixels($pixels, $width * 4, 0)
                $text = 0
                for ($i = 0; $i -lt $pixels.Length; $i += 4) {
                    if ($pixels[$i + 3] -gt 0 -and $pixels[$i] -gt 150 -and $pixels[$i + 1] -gt 150 -and $pixels[$i + 2] -gt 150) { $text++ }
                }
                Assert-True ($text -gt 20) "Blank UI capture $name"
                $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
                $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
                $stream = [IO.File]::Create((Join-Path (Split-Path -Parent $ReceiptPath) "$name.png"))
                try { $encoder.Save($stream) } finally { $stream.Dispose() }
            }
            Assert-True ($window.FindName("BtnNoobNic").Content -match "TCP" -and $window.FindName("BtnNoobLatency").Content -match "NVIDIA") "UI hides added actions"
        } finally { $window.Close() }
        $script:Cases.Add("Both UI routes render with visible text; no event handlers/optimizer run")
    }
    if ($ReceiptPath) {
        [ordered]@{ ok = $true; cases = @($script:Cases); real_registry_writes = 0; real_adapter_writes = 0; real_bcd_writes = 0; real_power_writes = 0; vm_suite_run = $false } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ReceiptPath -Encoding UTF8
    }
    Write-Output ("PASS: {0} offline Reclaim11 cases; all host mutations mocked." -f $script:Cases.Count)
} finally {
    if ([IO.File]::Exists($script:Manifest)) { [IO.File]::Delete($script:Manifest) }
    [IO.Directory]::Delete($script:Temp, $false)
}
