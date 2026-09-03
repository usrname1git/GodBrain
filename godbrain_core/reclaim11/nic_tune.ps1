# Gaming NIC tune: disable power-saving / EEE / interrupt moderation,
# set RSS on, bump Rx/Tx buffers. Keyword map, not per-vendor scripts.
# Physical Ethernet only (skip Wi-Fi, VMware, Tailscale, Bluetooth).
# restore.json first. Desk refused. -T is DeviceCleanupCmd-t. Never BFE.

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

$script:NicSkipDesc = @(
    "*VMnet*", "*Virtual Ethernet Adapter for VMnet*",
    "*VirtualBox Host-Only*", "*Hyper-V*", "*vEthernet*",
    "*Tailscale*", "*WireGuard*", "*Bluetooth*", "*WAN Miniport*",
    "*Kernel Debug*", "*Npcap*", "*TAP-*"
)

# Disable = power / latency junk. Not checksum/LSO (CPU vs packets).
$script:NicDisable = @(
    @{ Keyword = "*EEE"; Display = @("Energy Efficient Ethernet", "EEE") },
    @{ Keyword = "*EEELinkAdvertisement"; Display = @("EEE Link Advertisement") },
    @{ Keyword = "*InterruptModeration"; Display = @("Interrupt Moderation") },
    @{ Keyword = "ITR"; Display = @("Interrupt Moderation Rate") },
    @{ Keyword = "*FlowControl"; Display = @("Flow Control") },
    @{ Keyword = "*PMARPOffload"; Display = @("ARP Offload") },
    @{ Keyword = "*PMNSOffload"; Display = @("NS Offload") },
    @{ Keyword = "*WakeOnMagicPacket"; Display = @("Wake on Magic Packet", "Wake on magic packet") },
    @{ Keyword = "*WakeOnPattern"; Display = @("Wake on Pattern Match", "Wake on pattern match") },
    @{ Keyword = "*PacketCoalescing"; Display = @("Packet Coalescing") },
    @{ Keyword = "EnableWakeOnLan"; Display = @("Wake on LAN", "Wake On LAN") },
    @{ Keyword = "GreenEthernet"; Display = @("Green Ethernet", "GreenEthernet") },
    @{ Keyword = "PowerSavingMode"; Display = @("Power Saving Mode", "Ultra Low Power Mode") },
    @{ Keyword = "*IdlePowerDown"; Display = @("Reduce Speed On Power Down", "Auto Disable Gigabit") }
)

$script:NicEnable = @(
    @{ Keyword = "*RSS"; Display = @("Receive Side Scaling"); On = "1" }
)

# CS2/latency: 256-512. 2048+ is throughput and adds queue delay.
$script:NicBufferMin = 256
$script:NicBufferMax = 512
$script:NicBufferWant = 512

function Test-Reclaim11NicDeskHost {
    $n = Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
    [string]$n.EditionID -eq "IoTEnterpriseS"
}

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
    $nics = @()
    try { $nics = @(Get-NetAdapter -ErrorAction Stop) } catch { return $out }
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
        $spec = @{ Keyword = $kw; Display = @("Receive Buffers", "Transmit Buffers") }
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
        $qwant = 8
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
    $desk = Test-Reclaim11NicDeskHost
    if ($desk -and -not $WhatIf) {
        throw "Refuse: desk (IoTEnterpriseS). NIC tune is VM-only. Not M1ABRAMS."
    }
    $admin = $false
    if (Get-Command Test-Reclaim11Admin -ErrorAction SilentlyContinue) {
        $admin = Test-Reclaim11Admin
    }

    $targets = @(Get-Reclaim11NicTargets)
    $actions = @()
    $skipped = @()
    $nics = @()
    try { $nics = @(Get-NetAdapter -ErrorAction Stop) } catch { }
    foreach ($a in $nics) {
        if (Test-Reclaim11NicSkipAdapter -Adapter $a) {
            $skipped += ("{0} ({1})" -f $a.Name, $a.InterfaceDescription)
            continue
        }
    }
    foreach ($a in $targets) {
        $props = @(Get-NetAdapterAdvancedProperty -Name $a.Name -ErrorAction SilentlyContinue)
        $actions += @(Resolve-Reclaim11NicPlan -AdapterName $a.Name -Props $props)
    }

    $stamp = [datetime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
    $backupRoot = Join-Path $env:SystemDrive.TrimEnd("\") ("reclaim11\backup\" + $stamp)
    $manPath = Join-Path $backupRoot "restore.json"
    $manifest = [pscustomobject]@{
        id           = "reclaim11-nic-v1"
        at           = [datetime]::UtcNow.ToString("o")
        adapters     = @($targets | ForEach-Object { [pscustomobject]@{ name = $_.Name; desc = $_.InterfaceDescription } })
        skipped      = @($skipped)
        actions      = @($actions)
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
    foreach ($s in $skipped) { $would += ("skip {0}" -f $s) }

    $checks = @(
        (New-Reclaim11Check -Name "admin" -Ok $admin -Detail "Set-NetAdapterAdvancedProperty needs admin"),
        (New-Reclaim11Check -Name "desk" -Ok (-not $desk) -Detail $(if ($desk) { "IoTEnterpriseS would refuse" } else { "not desk SKU" })),
        (New-Reclaim11Check -Name "ethernet" -Ok ($targets.Count -gt 0) -Detail ("targets={0}" -f $targets.Count))
    )
    $refuse = ""
    if ($desk) { $refuse = "desk (IoTEnterpriseS)" }
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

    Write-Reclaim11NicManifest -Manifest $manifest -Path $manPath
    $applied = @()
    $failed = @()
    foreach ($x in $actions) {
        if ([string]$x.before -eq [string]$x.wanted) { continue }
        try {
            Set-NetAdapterAdvancedProperty -Name $x.adapter -RegistryKeyword $x.keyword -RegistryValue $x.wanted -NoRestart -ErrorAction Stop
            $applied += ("{0}:{1}={2}" -f $x.adapter, $x.keyword, $x.wanted)
        } catch {
            try {
                Set-NetAdapterAdvancedProperty -Name $x.adapter -RegistryKeyword $x.keyword -RegistryValue $x.wanted -ErrorAction Stop
                $applied += ("{0}:{1}={2}" -f $x.adapter, $x.keyword, $x.wanted)
            } catch {
                $failed += ("{0}:{1} {2}" -f $x.adapter, $x.keyword, $_.Exception.Message)
            }
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
    if (Test-Reclaim11NicDeskHost) {
        throw "Refuse: desk (IoTEnterpriseS). NIC restore is VM-only. Not M1ABRAMS."
    }
    $restored = @()
    foreach ($x in @($m.actions)) {
        $kw = [string]$x.keyword
        $ad = [string]$x.adapter
        $before = [string]$x.before
        if ([string]::IsNullOrWhiteSpace($kw) -or [string]::IsNullOrWhiteSpace($ad)) { continue }
        try {
            Set-NetAdapterAdvancedProperty -Name $ad -RegistryKeyword $kw -RegistryValue $before -NoRestart -ErrorAction Stop
            $restored += ("{0}:{1}" -f $ad, $kw)
        } catch {
            try {
                Set-NetAdapterAdvancedProperty -Name $ad -RegistryKeyword $kw -RegistryValue $before -ErrorAction Stop
                $restored += ("{0}:{1}" -f $ad, $kw)
            } catch { }
        }
    }
    [pscustomobject]@{ manifest = $Manifest; restored = @($restored) }
}

if ($MyInvocation.InvocationName -ne ".") {
    if (-not [string]::IsNullOrWhiteSpace($Restore)) {
        Restore-Reclaim11NicBackup -Manifest $Restore | ConvertTo-Json -Depth 6
    } else {
        $plan = Invoke-Reclaim11NicTune -WhatIf:$WhatIf
        if ($WhatIf) {
            Write-Host (Format-Reclaim11TestReport -Plan $plan -Title "nic_tune")
        }
        $plan | ConvertTo-Json -Depth 8
        if ((-not $WhatIf) -and $plan.PSObject.Properties["manifest_path"] -and $plan.manifest_path) {
            Write-Host ("restore.json {0}" -f $plan.manifest_path)
        }
    }
}
