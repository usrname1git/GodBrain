# Gaming NIC tune: disable power-saving / EEE / interrupt moderation /
# checksum / LSO / VLAN tags, set RSS on, bump Rx/Tx buffers.
# Keyword map, not per-vendor scripts. Do not force Speed/Duplex.
# Physical Ethernet only (skip Wi-Fi, VMware, Tailscale, Bluetooth).
# restore.json first. -T is DeviceCleanupCmd-t. Never BFE.

[CmdletBinding()]
param(
    [string]$Restore = "",
    [switch]$IntelHidden,
    [string]$AdapterName = "",
    [Alias("T", "Test")]
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:Reclaim11Here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$invBoot = Join-Path $script:Reclaim11Here "inventory.ps1"
if (Test-Path -LiteralPath $invBoot) { . $invBoot }

$script:NicSkipDesc = @(
    "*VMnet*", "*Virtual Ethernet Adapter for VMnet*",
    "*VirtualBox Host-Only*", "*Hyper-V*", "*vEthernet*",
    "*Tailscale*", "*WireGuard*", "*Bluetooth*", "*WAN Miniport*",
    "*Kernel Debug*", "*Npcap*", "*TAP-*"
)

# Disable = power / latency / offload junk. VLAN/priority off (n00b kit;
# anyone on tagged LAN knows how to turn it back). Not Speed/Duplex.
$script:NicDisable = @(
    @{ Keyword = "*EEE"; Display = @("Energy Efficient Ethernet", "EEE") },
    @{ Keyword = "*EEELinkAdvertisement"; Display = @("EEE Link Advertisement") },
    @{ Keyword = "*InterruptModeration"; Display = @("Interrupt Moderation") },
    @{ Keyword = "ITR"; Display = @("Interrupt Moderation Rate") },
    @{ Keyword = "*FlowControl"; Display = @("Flow Control") },
    @{ Keyword = "*TCPChecksumOffloadIPv4"; Display = @("TCP Checksum Offload (IPv4)") },
    @{ Keyword = "*TCPChecksumOffloadIPv6"; Display = @("TCP Checksum Offload (IPv6)") },
    @{ Keyword = "*UDPChecksumOffloadIPv4"; Display = @("UDP Checksum Offload (IPv4)") },
    @{ Keyword = "*UDPChecksumOffloadIPv6"; Display = @("UDP Checksum Offload (IPv6)") },
    @{ Keyword = "*IPChecksumOffloadIPv4"; Display = @("IPv4 Checksum Offload") },
    @{ Keyword = "*IPChecksumOffloadIPv6"; Display = @("IPv6 Checksum Offload") },
    @{ Keyword = "*LsoV2IPv4"; Display = @("Large Send Offload V2 (IPv4)") },
    @{ Keyword = "*LsoV2IPv6"; Display = @("Large Send Offload V2 (IPv6)") },
    @{ Keyword = "*LsoV1IPv4"; Display = @("Large Send Offload (IPv4)") },
    @{ Keyword = "*PriorityVLANTag"; Display = @("Packet Priority & VLAN", "Priority & VLAN") },
    @{ Keyword = "*PMARPOffload"; Display = @("ARP Offload") },
    @{ Keyword = "*PMNSOffload"; Display = @("NS Offload") },
    @{ Keyword = "*WakeOnMagicPacket"; Display = @("Wake on Magic Packet", "Wake on magic packet") },
    @{ Keyword = "*WakeOnPattern"; Display = @("Wake on Pattern Match", "Wake on pattern match") },
    @{ Keyword = "WakeOnMagicPacketFromS5"; Display = @("Wake On Magic Packet From S5") },
    @{ Keyword = "*PacketCoalescing"; Display = @("Packet Coalescing") },
    @{ Keyword = "EnableWakeOnLan"; Display = @("Wake on LAN", "Wake On LAN") },
    @{ Keyword = "GreenEthernet"; Display = @("Green Ethernet", "GreenEthernet") },
    @{ Keyword = "PowerSavingMode"; Display = @("Power Saving Mode", "Ultra Low Power Mode") },
    @{ Keyword = "*IdlePowerDown"; Display = @("Reduce Speed On Power Down", "Auto Disable Gigabit") },
    @{ Keyword = "*IdleRestriction"; Display = @("Idle power down restriction") },
    @{ Keyword = "AdaptiveIFS"; Display = @("Adaptive Inter-Frame Spacing") }
)

$script:NicEnable = @(
    @{ Keyword = "*RSS"; Display = @("Receive Side Scaling"); On = "1" }
)

# CS2/latency: 256-512. 2048+ is throughput and adds queue delay.
$script:NicBufferMin = 256
$script:NicBufferMax = 512
$script:NicBufferWant = 512

function Test-Reclaim11NicSkipAdapter {
    param($Adapter)
    $desc = [string]$Adapter.InterfaceDescription
    $name = [string]$Adapter.Name
    foreach ($p in $script:NicSkipDesc) {
        if ($desc -like $p -or $name -like $p) { return $true }
    }
    $media = [string]$Adapter.PhysicalMediaType
    if ($media -match "802\.11|Native 802\.11|Wireless|Wi-?Fi|Bluetooth") { return $true }
    if ($Adapter.Status -eq "Not Present") { return $true }
    $false
}

function Get-Reclaim11NicTargets {
    $out = @()
    $nics = @(Get-Reclaim11NetAdapters)
    foreach ($a in $nics) {
        if (Test-Reclaim11NicSkipAdapter -Adapter $a) { continue }
        $media = [string]$a.PhysicalMediaType
        if ($media -and $media -notmatch "802\.3|Ethernet") { continue }
        $out += $a
    }
    $out
}

function Pick-Reclaim11NicBufferValue {
    param($Prop, [int]$Want = 512, [string]$Current = "")
    $lo = $script:NicBufferMin
    $hi = $script:NicBufferMax
    $cur = $null
    if ($Current -match '^\d+$') { $cur = [int]$Current }
    if ($null -ne $cur -and $cur -ge $lo -and $cur -le $hi) { return $cur }
    $raw = @()
    if ($Prop.PSObject.Properties["ValidRegistryValues"] -and $Prop.ValidRegistryValues) {
        $raw = @($Prop.ValidRegistryValues)
    }
    $vals = @()
    foreach ($v in $raw) {
        $s = [string]$v
        if ($s -match '^\d+$') { $vals += [int]$s }
    }
    $band = @($vals | Where-Object { $_ -ge $lo -and $_ -le $hi } | Sort-Object)
    if ($band.Count -gt 0) {
        if ($band -contains $Want) { return $Want }
        return [int]$band[-1]
    }
    if ($vals.Count -gt 0) {
        $near = @($vals | Sort-Object { [math]::Abs($_ - $Want) })
        return [int]$near[0]
    }
    $Want
}

function Find-Reclaim11NicProp {
    param($Props, $Spec)
    $kw = [string]$Spec.Keyword
    foreach ($p in @($Props)) {
        if ([string]$p.RegistryKeyword -ieq $kw) { return $p }
    }
    foreach ($d in @($Spec.Display)) {
        foreach ($p in @($Props)) {
            if ([string]$p.DisplayName -ieq $d) { return $p }
        }
    }
    $null
}

function Get-Reclaim11NicRegValue {
    param($Prop)
    $rv = $Prop.RegistryValue
    if ($rv -is [System.Array] -and $rv.Count -gt 0) { return [string]$rv[0] }
    [string]$rv
}

function Resolve-Reclaim11NicPlan {
    param(
        [string]$AdapterName,
        $Props
    )
    $actions = @()
    foreach ($spec in $script:NicDisable) {
        $p = Find-Reclaim11NicProp -Props $Props -Spec $spec
        if (-not $p) { continue }
        $cur = Get-Reclaim11NicRegValue -Prop $p
        $actions += [pscustomobject]@{
            adapter  = $AdapterName
            keyword  = [string]$p.RegistryKeyword
            display  = [string]$p.DisplayName
            before   = $cur
            wanted   = "0"
            kind     = "disable"
        }
    }
    foreach ($spec in $script:NicEnable) {
        $p = Find-Reclaim11NicProp -Props $Props -Spec $spec
        if (-not $p) { continue }
        $cur = Get-Reclaim11NicRegValue -Prop $p
        $on = [string]$spec.On
        $actions += [pscustomobject]@{
            adapter  = $AdapterName
            keyword  = [string]$p.RegistryKeyword
            display  = [string]$p.DisplayName
            before   = $cur
            wanted   = $on
            kind     = "enable"
        }
    }
    foreach ($kw in @("*ReceiveBuffers", "*TransmitBuffers")) {
        $display = if ($kw -eq "*ReceiveBuffers") { "Receive Buffers" } else { "Transmit Buffers" }
        $spec = @{ Keyword = $kw; Display = @($display) }
        $p = Find-Reclaim11NicProp -Props $Props -Spec $spec
        if (-not $p) { continue }
        $cur = Get-Reclaim11NicRegValue -Prop $p
        $want = [string](Pick-Reclaim11NicBufferValue -Prop $p -Want $script:NicBufferWant -Current $cur)
        $actions += [pscustomobject]@{
            adapter  = $AdapterName
            keyword  = [string]$p.RegistryKeyword
            display  = [string]$p.DisplayName
            before   = $cur
            wanted   = $want
            kind     = "buffer"
        }
    }
    $rssq = Find-Reclaim11NicProp -Props $Props -Spec @{ Keyword = "*NumRssQueues"; Display = @("Maximum Number of RSS Queues", "RSS Queues") }
    if ($rssq) {
        $cur = Get-Reclaim11NicRegValue -Prop $rssq
        $qvals = @()
        if ($rssq.PSObject.Properties["ValidRegistryValues"] -and $rssq.ValidRegistryValues) {
            foreach ($v in @($rssq.ValidRegistryValues)) {
                if ([string]$v -match '^\d+$') { $qvals += [int]$v }
            }
        }
        $qwant = $cur
        if ($qvals.Count -gt 0) {
            if ($qvals -contains 8) { $qwant = 8 }
            else { $qwant = [int](($qvals | Measure-Object -Maximum).Maximum) }
        }
        $actions += [pscustomobject]@{
            adapter  = $AdapterName
            keyword  = [string]$rssq.RegistryKeyword
            display  = [string]$rssq.DisplayName
            before   = $cur
            wanted   = [string]$qwant
            kind     = "rssq"
        }
    }
    $actions
}

function Get-Reclaim11IntelNicProfile {
    foreach ($spec in @(
        @{ keyword = "*RSS"; display = "Receive Side Scaling"; wanted = "1" },
        @{ keyword = "*ReceiveBuffers"; display = "Receive Buffers"; wanted = "256" },
        @{ keyword = "*TransmitBuffers"; display = "Transmit Buffers"; wanted = "256" }
    )) {
        $metadata = [ordered]@{ ParamDesc = $spec.display; Type = "int"; Default = "512"; Min = "128"; Max = "4096"; Step = "64" }
        if ($spec.keyword -eq "*RSS") { $metadata = [ordered]@{ ParamDesc = $spec.display; Type = "enum"; Default = "1" } }
        [pscustomobject]@{ keyword = $spec.keyword; wanted = $spec.wanted; metadata = $metadata }
    }
}

function Invoke-Reclaim11IntelNicTune {
    param([string]$Root = "", [string]$AdapterName = "", [switch]$WhatIf)
    $targets = @(Get-Reclaim11IntelNicRegistryTargets -AdapterName $AdapterName)
    $rows = @()
    $createdKeys = @()
    foreach ($target in $targets) {
        $parent = Get-Reclaim11RegistryKey -Path "$($target.class_path)\Ndi\Params" -RequireKey
        $parent.Dispose()
        $binding = [pscustomobject]@{ kind = "intel_nic"; instance_id = $target.instance_id; guid = $target.guid; class_path = $target.class_path }
        $values = @()
        foreach ($spec in @(Get-Reclaim11IntelNicProfile)) {
            $path = "$($target.class_path)\Ndi\Params\$($spec.keyword)"
            $type = Get-Reclaim11RegistrySnapshot -Path $path -Name "Type"
            if ($type.exists -and ($type.kind -ne "String" -or $type.value -ine $spec.metadata.Type)) {
                throw "Intel NIC driver definition conflicts with the recovered profile: $($spec.keyword)"
            }
            if ($spec.keyword -ne "*RSS") {
                $bounds = @{}
                foreach ($name in @("Min", "Max", "Step")) {
                    $current = Get-Reclaim11RegistrySnapshot -Path $path -Name $name
                    $text = if ($current.exists) { [string]$current.value } else { [string]$spec.metadata[$name] }
                    $number = 0
                    if (-not [int]::TryParse($text, [ref]$number) -or $number -lt 1) { throw "Invalid Intel buffer range: $name" }
                    $bounds[$name] = $number
                }
                if (256 -lt $bounds.Min -or 256 -gt $bounds.Max -or (256 - $bounds.Min) % $bounds.Step -ne 0) {
                    throw "Intel NIC driver definition does not allow buffer256; leaving it unchanged"
                }
            }
            foreach ($entry in $spec.metadata.GetEnumerator()) {
                $before = Get-Reclaim11RegistrySnapshot -Path $path -Name $entry.Key
                # Driver-supplied definitions win; fill only absent metadata.
                if (-not $before.exists) { $values += @{ path = $path; name = $entry.Key; wanted = $entry.Value; kind = "String"; before = $before } }
            }
            if ($spec.keyword -eq "*RSS") {
                foreach ($entry in @(@{ name = "0"; value = "Disabled" }, @{ name = "1"; value = "Enabled" })) {
                    $before = Get-Reclaim11RegistrySnapshot -Path "$path\enum" -Name $entry.name
                    if (-not $before.exists) { $values += @{ path = "$path\enum"; name = $entry.name; wanted = $entry.value; kind = "String"; before = $before } }
                }
            }
            $values += @{ path = $target.class_path; name = $spec.keyword; wanted = $spec.wanted; kind = "String"
                before = Get-Reclaim11RegistrySnapshot -Path $target.class_path -Name $spec.keyword -RequireKey }
        }
        $values += @{ path = $target.class_path; name = "PnPCapabilities"; wanted = 24; kind = "DWord"
            before = Get-Reclaim11RegistrySnapshot -Path $target.class_path -Name "PnPCapabilities" -RequireKey }
        foreach ($value in $values) {
            $rows += [pscustomobject]@{ path = $value.path; name = $value.name; wanted = $value.wanted; wanted_kind = $value.kind
                before = $value.before.value; before_snapshot = $value.before; binding = $binding }
            if (-not $value.before.key_exists -and @($createdKeys | Where-Object path -IEQ $value.path).Count -eq 0) {
                $createdKeys += [pscustomobject]@{ path = $value.path; binding = $binding }
            }
        }
    }
    $admin = Test-Reclaim11Admin
    $pe = Test-Reclaim11PeHost
    $refuse = if ($pe) { "WinPE (MiniNT)" } elseif (-not $admin) { "needs elevation" }
        elseif ($targets.Count -eq 0) { "no matching physical Intel I225-V/I226-V adapter" } else { "" }
    $backupRoot = Join-Path $env:SystemDrive.TrimEnd("\") ("reclaim11\backup\" + (New-Reclaim11BackupStamp))
    $manifestPath = Join-Path $backupRoot "restore.json"
    $plan = [pscustomobject]@{
        id = "reclaim11-nic-intel-v1"; at = [datetime]::UtcNow.ToString("o")
        adapters = $targets; actions = @(); registry = @($rows); created_keys = @($createdKeys)
        backup_root = $backupRoot; manifest_path = $manifestPath; skipped = @()
        what_if = [bool]$WhatIf; mutate = -not [bool]$WhatIf; would_refuse = $refuse
        checks = @((New-Reclaim11Check -Name "intel-nic" -Ok (-not $refuse) -Detail $refuse))
        would = @($rows | ForEach-Object { "reg $($_.path) $($_.name)=$($_.wanted) ($($_.wanted_kind); readback)" })
        note = "Recovered legacy profile: RSS1, Rx/Tx256, PnPCapabilities24 plus missing Advanced metadata. No queues/CPU affinity or automatic restart. Registry storage is not proof of driver consumption; reboot then check runtime RSS."
        applied = @(); failed = @(); restart_required = $true
    }
    if ($WhatIf) { return $plan }
    if ($refuse) { throw "Refuse: $refuse" }
    Write-Reclaim11NicManifest -Manifest $plan -Path $manifestPath
    foreach ($row in $rows) {
        try {
            Assert-Reclaim11RegistryBinding -Row $row
            $current = Get-Reclaim11RegistrySnapshot -Path $row.path -Name $row.name
            if (-not (Test-Reclaim11RegistrySnapshotEqual $current $row.before_snapshot)) {
                throw "Intel NIC value changed since backup: $($row.name)"
            }
            Set-Reclaim11RegistrySnapshot -Path $row.path -Name $row.name -RequireKey:($row.path -ieq $row.binding.class_path) -Snapshot (
                [pscustomobject]@{ exists = $true; kind = $row.wanted_kind; value = $row.wanted }
            )
            $plan.applied += "reg:$($row.path):$($row.name)=$($row.wanted)"
        } catch {
            $plan.failed += "reg:$($row.path):$($row.name) $($_.Exception.Message)"
            break
        }
    }
    Write-Reclaim11NicManifest -Manifest $plan -Path $manifestPath
    $plan
}

function Write-Reclaim11NicManifest {
    param($Manifest, [string]$Path)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    ($Manifest | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-Reclaim11NicTune {
    param(
        [string]$Root,
        [switch]$WhatIf
    )
    if ([string]::IsNullOrWhiteSpace($Root)) {
        $Root = $script:Reclaim11Here
    }
    $pe = Test-Reclaim11PeHost
    if ($pe -and -not $WhatIf) { throw "Refuse: WinPE (MiniNT). NIC tuning is in-Windows." }
    $admin = $false
    if (Get-Command Test-Reclaim11Admin -ErrorAction SilentlyContinue) {
        $admin = Test-Reclaim11Admin
    }

    $targets = @(Get-Reclaim11NicTargets)
    $actions = @()
    $skipped = @()
    $nics = @(Get-Reclaim11NetAdapters)
    foreach ($a in $nics) {
        if (Test-Reclaim11NicSkipAdapter -Adapter $a) {
            $skipped += ("{0} ({1})" -f $a.Name, $a.InterfaceDescription)
            continue
        }
    }
    foreach ($a in $targets) {
        $props = @(Get-NetAdapterAdvancedProperty -Name $a.Name -AllProperties -ErrorAction Stop)
        $actions += @(Resolve-Reclaim11NicPlan -AdapterName $a.Name -Props $props)
        foreach ($keyword in @("*RSS", "*ReceiveBuffers", "*TransmitBuffers")) {
            if (-not @($props | Where-Object RegistryKeyword -IEQ $keyword).Count) {
                $skipped += "$($a.Name): $keyword absent; Intel I225-V/I226-V users can use the separate Intel RSS/BUFFERS action"
            }
        }
    }
    $registry = @()
    $tcpTargets = @(Get-Reclaim11TcpInterfaceTargets -Adapters $targets)
    foreach ($target in $tcpTargets) {
        foreach ($name in @("TcpAckFrequency", "TCPNoDelay")) {
            $registry += New-Reclaim11RegistryWrite -Path $target.path -Name $name -Wanted 1 -Binding (
                [pscustomobject]@{ kind = "tcp"; guid = $target.guid }
            )
        }
    }
    if ($tcpTargets.Count -eq 0) { $skipped += "TCP registry: no connected physical Ethernet interface" }

    $stamp = New-Reclaim11BackupStamp
    $backupRoot = Join-Path $env:SystemDrive.TrimEnd("\") ("reclaim11\backup\" + $stamp)
    $manPath = Join-Path $backupRoot "restore.json"
    $manifest = [pscustomobject]@{
        id           = "reclaim11-nic-v1"
        at           = [datetime]::UtcNow.ToString("o")
        adapters     = @($targets | ForEach-Object { [pscustomobject]@{ name = $_.Name; desc = $_.InterfaceDescription } })
        skipped      = @($skipped)
        actions      = @($actions)
        registry     = @($registry)
        backup_root  = $backupRoot
        note         = "Restore with pwsh -File nic_tune.ps1 -Restore restore.json. Ethernet only. Never BFE."
    }

    $would = @()
    foreach ($x in $actions) {
        if ([string]$x.before -eq [string]$x.wanted) {
            $would += ("keep {0} {1}={2}" -f $x.adapter, $x.keyword, $x.wanted)
        } else {
            $would += ("set {0} {1} {2}->{3}" -f $x.adapter, $x.keyword, $x.before, $x.wanted)
        }
    }
    foreach ($x in $registry) {
        $would += ("reg {0} {1} {2}->{3} (DWORD; readback)" -f $x.path, $x.name, $x.before, $x.wanted)
    }
    foreach ($s in $skipped) { $would += ("skip {0}" -f $s) }

    $checks = @(
        (New-Reclaim11Check -Name "admin" -Ok $admin -Detail "Set-NetAdapterAdvancedProperty needs admin"),
        (New-Reclaim11Check -Name "winpe" -Ok (-not $pe) -Detail "NIC/TCP tuning is in-Windows"),
        (New-Reclaim11Check -Name "ethernet" -Ok ($targets.Count -gt 0) -Detail ("targets={0}" -f $targets.Count))
    )
    $refuse = ""
    if ($pe) { $refuse = "WinPE (MiniNT)" }
    elseif (-not $admin) { $refuse = "needs elevation" }
    elseif ($targets.Count -lt 1) { $refuse = "no physical Ethernet" }

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
    Write-Reclaim11NicManifest -Manifest $manifest -Path $manPath
    $applied = @()
    $failed = @()
    foreach ($x in $actions) {
        if ([string]$x.before -eq [string]$x.wanted) { continue }
        try {
            Set-NetAdapterAdvancedProperty -Name $x.adapter -RegistryKeyword $x.keyword -RegistryValue $x.wanted -NoRestart -ErrorAction Stop
            $applied += ("{0}:{1}={2}" -f $x.adapter, $x.keyword, $x.wanted)
        } catch {
            $failed += ("{0}:{1} {2}" -f $x.adapter, $x.keyword, $_.Exception.Message)
        }
    }
    foreach ($x in $registry) {
        try {
            Assert-Reclaim11RegistryBinding -Row $x
            Set-Reclaim11RegistryDword -Path $x.path -Name $x.name -Value $x.wanted -RequireKey
            $applied += ("reg:{0}:{1}={2}" -f $x.path, $x.name, $x.wanted)
        } catch {
            $failed += ("reg:{0}:{1} {2}" -f $x.path, $x.name, $_.Exception.Message)
        }
    }
    $manifest | Add-Member -NotePropertyName applied -NotePropertyValue $applied
    $manifest | Add-Member -NotePropertyName failed -NotePropertyValue $failed
    $manifest | Add-Member -NotePropertyName manifest_path -NotePropertyValue $manPath
    Write-Reclaim11NicManifest -Manifest $manifest -Path $manPath
    $manifest
}

function Restore-Reclaim11NicBackup {
    param(
        [string]$Manifest,
        [string]$Root
    )
    if (-not (Test-Path -LiteralPath $Manifest)) {
        throw "Restore-Reclaim11NicBackup: missing $Manifest"
    }
    $m = Get-Content -LiteralPath $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$m.id -notlike "reclaim11-nic*") {
        throw "Restore-Reclaim11NicBackup: not a NIC manifest"
    }
    if (Test-Reclaim11PeHost) { throw "Refuse: WinPE (MiniNT). NIC restore is in-Windows." }
    $restored = @()
    $failed = @()
    foreach ($x in @($m.actions)) {
        $kw = [string]$x.keyword
        $ad = [string]$x.adapter
        $before = [string]$x.before
        if ([string]::IsNullOrWhiteSpace($kw) -or [string]::IsNullOrWhiteSpace($ad)) { continue }
        try {
            Set-NetAdapterAdvancedProperty -Name $ad -RegistryKeyword $kw -RegistryValue $before -NoRestart -ErrorAction Stop
            $restored += ("{0}:{1}" -f $ad, $kw)
        } catch {
            $failed += ("{0}:{1} {2}" -f $ad, $kw, $_.Exception.Message)
        }
    }
    if ($m.PSObject.Properties["registry"]) {
        foreach ($row in @($m.registry)) {
            try {
                Restore-Reclaim11RegistryWrite -Row $row
                $restored += ("reg:{0}:{1}" -f $row.path, $row.name)
            } catch {
                $failed += ("reg:{0}:{1} {2}" -f $row.path, $row.name, $_.Exception.Message)
            }
        }
        if ($m.PSObject.Properties["created_keys"] -and $failed.Count -eq 0) {
            foreach ($entry in @($m.created_keys | Sort-Object { $_.path.Length } -Descending)) {
                try {
                    $probeName = if ($entry.path -like '*\enum') { "0" } else { "Type" }
                    Assert-Reclaim11RegistryBinding -Row ([pscustomobject]@{ path = $entry.path; name = $probeName; binding = $entry.binding })
                    $key = Get-Reclaim11RegistryKey -Path $entry.path
                    if ($null -eq $key) { continue }
                    try { $empty = $key.GetValueNames().Count -eq 0 -and $key.GetSubKeyNames().Count -eq 0 } finally { $key.Dispose() }
                    if (-not $empty) { throw "Created metadata key now contains unrelated data; retained" }
                    Remove-Item -LiteralPath $entry.path -ErrorAction Stop
                    $restored += "empty-key:$($entry.path)"
                } catch { $failed += "empty-key:$($entry.path) $($_.Exception.Message)" }
            }
        }
    }
    [pscustomobject]@{ manifest = $Manifest; restored = @($restored); failed = @($failed) }
}

if ($MyInvocation.InvocationName -ne ".") {
    if (-not [string]::IsNullOrWhiteSpace($Restore)) {
        $result = Restore-Reclaim11NicBackup -Manifest $Restore
        $result | ConvertTo-Json -Depth 6
        if (@($result.failed).Count -gt 0) { exit 1 }
    } else {
        $plan = if ($IntelHidden) {
            Invoke-Reclaim11IntelNicTune -AdapterName $AdapterName -WhatIf:$WhatIf
        } else {
            if ($AdapterName) { throw "-AdapterName is scoped to -IntelHidden" }
            Invoke-Reclaim11NicTune -WhatIf:$WhatIf
        }
        if ($WhatIf) {
            Write-Host (Format-Reclaim11TestReport -Plan $plan -Title "nic_tune")
        }
        $plan | ConvertTo-Json -Depth 8
        if ((-not $WhatIf) -and $plan.PSObject.Properties["manifest_path"] -and $plan.manifest_path) {
            Write-Host ("restore.json {0}" -f $plan.manifest_path)
        }
        if (-not $WhatIf -and @($plan.failed).Count -gt 0) { exit 1 }
    }
}
