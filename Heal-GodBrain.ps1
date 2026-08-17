# One loop for THIS host: discover (probe) → start allowlist → diagnose
# (icmp / dns_self / nic_tcpip) → at most one flushdns if DNS missed after
# that split → verify → remember (candidate). Not a multi-agent graph.
# Allowlist starts: Windows services MongoDB, Dnscache, iphlpsvc, nsi + rag/coli/kernel.
# Allowlist repair: ipconfig /flushdns only when dns_self fails, Dnscache is
# up, and icmp_loopback is up. release, winsock reset, int ip reset,
# DeviceCleanup, and reboot are legal tools but need an operator GO in
# chat — Heal must not run them unattended.
# nic_tcpip is detect-only. Do not start NICs or firewall from here.
# Skip coli while CS2.exe is running or has been gone under 5 minutes.
# The verifier is the probe, not the model. Do not add extra nodes here.

[CmdletBinding()]
param(
    [string]$RepoRoot = $PSScriptRoot
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($RepoRoot) -and $MyInvocation.MyCommand.Path) {
    $RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    throw "Heal-GodBrain: RepoRoot is empty."
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$starter = Join-Path $RepoRoot "Start-GodBrain.ps1"
if (-not (Test-Path -LiteralPath $starter)) {
    throw "Heal-GodBrain: missing $starter"
}

$logDir = Join-Path $RepoRoot "logs"
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}

function Test-Port([string]$HostName, [int]$Port) {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(400)
        if ($ok) { $client.EndConnect($iar) }
        $client.Close()
        return [bool]$ok
    } catch {
        return $false
    }
}

function Test-IcmpLoopback {
    try {
        return [bool](Test-Connection -ComputerName "127.0.0.1" -Count 1 -Quiet -ErrorAction SilentlyContinue)
    } catch {
        return $false
    }
}

function Test-DnsSelf {
    try {
        $null = [System.Net.Dns]::GetHostEntry("localhost")
        $null = [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME)
        return $true
    } catch {
        return $false
    }
}

function Get-UplinkAdapter {
    $all = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)
    if ($all.Count -eq 0) { return $null }
    $pref = $all | Where-Object { $_.InterfaceDescription -match "I226-V" } | Select-Object -First 1
    if ($pref) { return $pref }
    return $all | Where-Object {
        $_.Status -eq "Up" -and
        $_.InterfaceDescription -notmatch "Wi-Fi|Wireless|Bluetooth|Virtual|Hyper-V|VMware|Tailscale"
    } | Select-Object -First 1
}

function Test-NicTcpip {
    try {
        $nic = Get-UplinkAdapter
        if (-not $nic) { return $false }
        if ($nic.Status -ne "Up") { return $false }
        $bind = Get-NetAdapterBinding -Name $nic.Name -ComponentID ms_tcpip -ErrorAction SilentlyContinue
        return [bool]($bind -and $bind.Enabled)
    } catch {
        return $false
    }
}

function Test-ServiceUp([string]$Name) {
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    return [bool]($svc -and $svc.Status -eq "Running")
}

function Start-AllowlistedService([string]$Name) {
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Host "heal: Windows service $Name is not installed"
        return
    }
    if ($svc.Status -eq "Running") { return }
    try {
        Start-Service -Name $Name -ErrorAction Stop
        Write-Host "heal: started Windows service $Name"
    } catch {
        Write-Host "heal: could not start ${Name}: $_"
    }
}

function Invoke-AllowlistedFlushDns {
    Write-Host "heal: ipconfig /flushdns (dns_self failed, Dnscache up, icmp ok)"
    & ipconfig.exe /flushdns | Out-Null
}

function Test-TailscaleCgNat {
    $hit = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -like "100.*" -and $_.InterfaceAlias -match "tail|Tail" } |
        Select-Object -First 1
    return [bool]$hit
}

function Get-Probe {
    $mouth = Test-Port "127.0.0.1" 8000
    return [ordered]@{
        mongo         = Test-Port "127.0.0.1" 27017
        rag           = Test-Port "127.0.0.1" 8084
        coli          = $mouth
        mouth         = $mouth
        kernel        = Test-Port "127.0.0.1" 8083
        tailscale     = Test-TailscaleCgNat
        dns           = Test-ServiceUp "Dnscache"
        iphlp         = Test-ServiceUp "iphlpsvc"
        nsi           = Test-ServiceUp "nsi"
        icmp_loopback = Test-IcmpLoopback
        dns_self      = Test-DnsSelf
        nic_tcpip     = Test-NicTcpip
    }
}

function Get-DiagnoseLayer($probe) {
    if (-not $probe.icmp_loopback) { return "icmp" }
    if (-not $probe.dns -or -not $probe.dns_self) { return "dns" }
    if (-not $probe.nic_tcpip) { return "nic" }
    if (-not ($probe.mongo -and $probe.rag -and $probe.coli -and $probe.kernel)) {
        return "listeners"
    }
    return "ok"
}

$ServiceAllowlist = [ordered]@{
    mongo = "MongoDB"
    dns   = "Dnscache"
    iphlp = "iphlpsvc"
    nsi   = "nsi"
}

$cs2Helper = Join-Path $RepoRoot "GodBrain-Cs2.ps1"
$coliSleep = $false
if (Test-Path -LiteralPath $cs2Helper) {
    . $cs2Helper
    $coliSleep = Test-GodBrainColiShouldSleep $RepoRoot
}

$before = Get-Probe
$needed = @()
$acted = @()
if (-not $before.mongo) { $needed += "mongo" }
if (-not $before.dns) { $needed += "dns" }
if (-not $before.iphlp) { $needed += "iphlp" }
if (-not $before.nsi) { $needed += "nsi" }
if (-not $before.rag) { $needed += "rag" }
# "coli" here means the :8000 mouth. Start-GodBrain starts llama-server
# instead of coli when logs/mouth.txt says llama-server.
if (-not $before.coli -and -not $coliSleep) { $needed += "coli" }
if (-not $before.kernel) { $needed += "kernel" }

foreach ($key in @("mongo", "dns", "iphlp", "nsi")) {
    if ($needed -contains $key) {
        Start-AllowlistedService $ServiceAllowlist[$key]
        $acted += ("start:" + $ServiceAllowlist[$key])
    }
}

$processNeeded = @($needed | Where-Object { $_ -notin @("mongo", "dns", "iphlp", "nsi") })
if ($processNeeded.Count -gt 0) {
    & $starter -RepoRoot $RepoRoot -MongoWaitSeconds 15
    Start-Sleep -Seconds 2
    $acted += "start:listeners"
} elseif ($needed -contains "mongo") {
    $deadline = (Get-Date).AddSeconds(15)
    while (-not (Test-Port "127.0.0.1" 27017)) {
        if ((Get-Date) -gt $deadline) { break }
        Start-Sleep -Milliseconds 400
    }
}

$mid = Get-Probe
if (-not $mid.dns_self -and $mid.dns -and $mid.icmp_loopback) {
    Invoke-AllowlistedFlushDns
    $acted += "flushdns"
    Start-Sleep -Milliseconds 200
}

$after = Get-Probe
$ok = [bool](
    $after.mongo -and $after.rag -and $after.kernel -and
    $after.dns -and $after.iphlp -and $after.nsi -and
    ($after.coli -or $coliSleep)
)
$diagnose = [ordered]@{
    icmp_loopback = [bool]$after.icmp_loopback
    dns_self      = [bool]$after.dns_self
    nic_tcpip     = [bool]$after.nic_tcpip
    layer         = Get-DiagnoseLayer $after
}
$result = [ordered]@{
    version     = 3
    at          = (Get-Date).ToUniversalTime().ToString("o")
    playbook    = "host-listeners"
    needed      = @($needed)
    acted       = @($acted)
    diagnose    = $diagnose
    before      = $before
    after       = $after
    ok          = $ok
    never_kills = $true
    cs2_sleep   = [bool]$coliSleep
    mouth       = [bool]$after.mouth
    tailscale   = [bool]$after.tailscale
}

$json = $result | ConvertTo-Json -Depth 6
$last = Join-Path $logDir "heal-last.json"
$tmp = $last + ".tmp"
$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($tmp, $json, $utf8)
Move-Item -LiteralPath $tmp -Destination $last -Force
Add-Content -LiteralPath (Join-Path $logDir "heal.jsonl") -Value (($json -replace "`r?`n", " "))

Write-Host ("heal needed=[{0}] acted=[{1}] layer={2} ok={3}" -f `
    ($needed -join ","), ($acted -join ","), $diagnose.layer, $ok)

# Remember only a failed or acted loop. Success-every-5-min is wiki noise.
$shouldRemember = $needed.Count -gt 0 -or $acted.Count -gt 0 -or -not $ok `
    -or -not $after.icmp_loopback -or -not $after.dns_self -or -not $after.nic_tcpip
if ($env:GODBRAIN_API_TOKEN -and $after.kernel -and $shouldRemember) {
    try {
        $headers = @{
            "Content-Type"  = "application/json"
            "Authorization" = "Bearer $($env:GODBRAIN_API_TOKEN)"
        }
        $body = @{
            text   = "Heal loop (candidate)`nneeded=$($needed -join ',')`nacted=$($acted -join ',')`nlayer=$($diagnose.layer)`nok=$ok`nicmp_loopback=$($after.icmp_loopback)`ndns_self=$($after.dns_self)`nnic_tcpip=$($after.nic_tcpip)`nbefore=$($before | ConvertTo-Json -Compress)`nafter=$($after | ConvertTo-Json -Compress)"
            sector = "windows-sre"
        } | ConvertTo-Json
        Invoke-RestMethod -Uri "http://127.0.0.1:8083/api/remember" `
            -Method POST -Headers $headers -Body $body | Out-Null
        Write-Host "heal remembered"
    } catch {
        Write-Host "heal remember skipped: $_"
    }
}

if ($after.kernel) {
    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:8083/api/doors" -TimeoutSec 3 | Out-Null
        Write-Host "heal wrote last-doors"
    } catch {
        Write-Host "heal doors skipped: $_"
    }
    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:8083/api/pending" -TimeoutSec 3 | Out-Null
        Write-Host "heal wrote last-pending"
    } catch {
        Write-Host "heal pending skipped: $_"
    }
    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:8083/api/vram" -TimeoutSec 3 | Out-Null
        Write-Host "heal wrote last-vram"
    } catch {
        Write-Host "heal vram skipped: $_"
    }
    $desk = Join-Path $RepoRoot "Test-GodBrainDesk.ps1"
    if (Test-Path -LiteralPath $desk) {
        try {
            & $desk -RepoRoot $RepoRoot
            if ($LASTEXITCODE -ne 0) { Write-Host "heal desk self-check failed" }
        } catch {
            Write-Host "heal desk self-check skipped: $_"
        }
    }
    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:8083/api/brief" -TimeoutSec 3 | Out-Null
        Write-Host "heal wrote last-brief"
    } catch {
        Write-Host "heal brief skipped: $_"
    }
}

if (-not $ok) { exit 1 }
exit 0
