# One loop for THIS host: detect → reason (layer) → allowlist patch → verify.
# TCP ports, then HTTP readiness (rag /health.ready, mouth /health).
# Allowlist starts: Windows services MongoDB, Dnscache, iphlpsvc, nsi + rag/coli/kernel.
# Allowlist repair: Clear-DnsClientCache only when dns_self fails, Dnscache is
# up, and icmp_loopback is up. If rag listens but the projection is unready,
# rag-rebuild.exe once (30 min cooldown, never kills rag-service).
# Inbox: one oldest inbox\*.txt via Librarian when the mouth is healthy,
# not busy, and CS2 is idle. A failed extract is quarantined to inbox\failed\
# so the next Watch tick does not steal the GPU. Claims stay candidate.
# Empty inbox is a no-op. Each tick POSTs /api/observe (idempotent pin).
# release, winsock reset, int ip reset, DeviceCleanup, and reboot need an
# operator GO in chat — Heal must not run them unattended.
# nic_tcpip is detect-only. Do not start NICs or firewall from here.
# Skip coli / inbox while CS2.exe is running or has been gone under 5 minutes.
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
    Write-Host "heal: Clear-DnsClientCache (dns_self failed, Dnscache up, icmp ok)"
    Clear-DnsClientCache
}

function Test-TailscaleCgNat {
    $hit = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -like "100.*" -and $_.InterfaceAlias -match "tail|Tail" } |
        Select-Object -First 1
    return [bool]$hit
}

function Test-HttpOk([string]$Url) {
    try {
        $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 -Uri $Url
        return [bool]($r.StatusCode -eq 200)
    } catch {
        return $false
    }
}

function Get-RagHealth {
    try {
        return Invoke-RestMethod -TimeoutSec 3 -Uri "http://127.0.0.1:8084/health"
    } catch {
        return $null
    }
}

function Test-MouthBusy([bool]$KernelUp) {
    if (-not $KernelUp) { return $true }
    try {
        $st = Invoke-RestMethod -TimeoutSec 3 -Uri "http://127.0.0.1:8083/api/status"
        if ($st.coli -and [bool]$st.coli.busy) { return $true }
        if ($st.mouth -and $st.mouth.PSObject.Properties.Name -contains "busy" -and [bool]$st.mouth.busy) {
            return $true
        }
        return $false
    } catch {
        return $true
    }
}

function Test-LibrarianRunning {
    return [bool](Get-Process -Name "librarian" -ErrorAction SilentlyContinue)
}

function Get-InboxWaiting {
    $inboxDir = Join-Path $RepoRoot "inbox"
    if (-not (Test-Path -LiteralPath $inboxDir)) { return @() }
    return @(Get-ChildItem -LiteralPath $inboxDir -File -Filter "*.txt" -ErrorAction SilentlyContinue)
}

function Get-InboxFailed {
    $failDir = Join-Path $RepoRoot "inbox\failed"
    if (-not (Test-Path -LiteralPath $failDir)) { return @() }
    return @(Get-ChildItem -LiteralPath $failDir -File -Filter "*.txt" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '\.reason$' })
}

function Get-Probe {
    $mouth = Test-Port "127.0.0.1" 8000
    $rag = Test-Port "127.0.0.1" 8084
    $ragHealth = $null
    if ($rag) { $ragHealth = Get-RagHealth }
    return [ordered]@{
        mongo         = Test-Port "127.0.0.1" 27017
        rag           = $rag
        rag_ready     = [bool]($ragHealth -and $ragHealth.ready)
        rag_building  = [bool]($ragHealth -and -not [string]::IsNullOrWhiteSpace([string]$ragHealth.building_generation))
        coli          = $mouth
        mouth         = $mouth
        mouth_ready   = [bool]($mouth -and (Test-HttpOk "http://127.0.0.1:8000/health"))
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
    if (-not $probe.rag_ready) { return "rag" }
    if (-not $probe.mouth_ready -and -not $coliSleep) { return "mouth" }
    return "ok"
}

function Invoke-AllowlistedRagRebuild {
    $exe = Join-Path $RepoRoot "godbrain_core\memory_store\rag-rebuild.exe"
    if (-not (Test-Path -LiteralPath $exe)) { return "skip:missing-exe" }
    $stamp = Join-Path $logDir "heal-rag-rebuild.stamp"
    if (Test-Path -LiteralPath $stamp) {
        $age = ((Get-Date) - (Get-Item -LiteralPath $stamp).LastWriteTime).TotalMinutes
        if ($age -lt 30) { return "skip:cooldown" }
    }
    $lock = Join-Path $logDir "heal-rag-rebuild.lock"
    if (Test-Path -LiteralPath $lock) {
        $lockAge = ((Get-Date) - (Get-Item -LiteralPath $lock).LastWriteTime).TotalMinutes
        if ($lockAge -lt 15) { return "skip:in-progress" }
    }
    if (-not $env:MONGODB_URI) { $env:MONGODB_URI = "mongodb://127.0.0.1:27017" }
    try {
        [System.IO.File]::WriteAllText($lock, "$PID $(Get-Date -Format o)")
        Write-Host "heal: rag-rebuild (projection not ready)"
        $null = & $exe
        $code = $LASTEXITCODE
        [System.IO.File]::WriteAllText($stamp, (Get-Date).ToUniversalTime().ToString("o"))
        if ($code -ne 0) { return "fail:$code" }
        return "ok"
    } catch {
        return "fail:throw"
    } finally {
        Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
    }
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
$ragRebuild = ""
if ($after.mongo -and $after.rag -and -not $after.rag_ready -and -not $after.rag_building) {
    $ragRebuild = Invoke-AllowlistedRagRebuild
    if ($ragRebuild -eq "ok") {
        $acted += "rag-rebuild"
        Start-Sleep -Milliseconds 400
        $after = Get-Probe
    } else {
        Write-Host ("heal rag-rebuild {0}" -f $ragRebuild)
    }
}

$inbox = [ordered]@{
    waiting     = 0
    failed      = 0
    acted       = $false
    skip        = ""
    quarantined = ""
}
$waitingFiles = @(Get-InboxWaiting)
$inbox.waiting = $waitingFiles.Count
$inbox.failed = @(Get-InboxFailed).Count
$inboxLock = Join-Path $logDir "heal-inbox.lock"
if ($waitingFiles.Count -gt 0) {
    if ($coliSleep) {
        $inbox.skip = "cs2"
    } elseif (-not $after.mouth_ready) {
        $inbox.skip = "mouth-down"
    } elseif (Test-LibrarianRunning) {
        $inbox.skip = "librarian-running"
    } elseif (Test-MouthBusy ([bool]$after.kernel)) {
        $inbox.skip = "mouth-busy"
    } elseif ((Test-Path -LiteralPath $inboxLock) -and
              (((Get-Date) - (Get-Item -LiteralPath $inboxLock).LastWriteTime).TotalMinutes -lt 20)) {
        $inbox.skip = "in-progress"
    } else {
        $lib = Join-Path $RepoRoot "Invoke-Librarian.ps1"
        if (-not (Test-Path -LiteralPath $lib)) {
            $inbox.skip = "missing-invoke"
        } else {
            try {
                [System.IO.File]::WriteAllText($inboxLock, "$PID $(Get-Date -Format o)")
                $beforeName = $waitingFiles[0].Name
                & $lib -Inbox -RepoRoot $RepoRoot
                if ($LASTEXITCODE -eq 0) {
                    $inbox.acted = $true
                    $acted += "inbox:librarian"
                } else {
                    $inbox.skip = "librarian-exit-$LASTEXITCODE"
                    $inbox.quarantined = $beforeName
                }
            } catch {
                $inbox.skip = "librarian-throw"
                Write-Host "heal inbox skipped: $_"
            } finally {
                Remove-Item -LiteralPath $inboxLock -Force -ErrorAction SilentlyContinue
            }
            $inbox.waiting = @(Get-InboxWaiting).Count
            $inbox.failed = @(Get-InboxFailed).Count
            if ($inbox.acted) {
                $after = Get-Probe
            }
        }
    }
    if ($inbox.skip) {
        Write-Host ("heal inbox waiting={0} failed={1} skip={2}" -f $inbox.waiting, $inbox.failed, $inbox.skip)
    }
}

$ok = [bool](
    $after.mongo -and $after.rag -and $after.rag_ready -and $after.kernel -and
    $after.dns -and $after.iphlp -and $after.nsi -and
    ($after.mouth_ready -or $coliSleep)
)
$diagnose = [ordered]@{
    icmp_loopback = [bool]$after.icmp_loopback
    dns_self      = [bool]$after.dns_self
    nic_tcpip     = [bool]$after.nic_tcpip
    rag_ready     = [bool]$after.rag_ready
    mouth_ready   = [bool]$after.mouth_ready
    layer         = Get-DiagnoseLayer $after
}
$result = [ordered]@{
    version     = 4
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
    mouth_ready = [bool]$after.mouth_ready
    rag_ready   = [bool]$after.rag_ready
    rag_rebuild = $ragRebuild
    inbox       = $inbox
    tailscale   = [bool]$after.tailscale
}

$json = $result | ConvertTo-Json -Depth 6
$last = Join-Path $logDir "heal-last.json"
$tmp = $last + ".tmp"
$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($tmp, $json, $utf8)
Move-Item -LiteralPath $tmp -Destination $last -Force
Add-Content -LiteralPath (Join-Path $logDir "heal.jsonl") -Value (($json -replace "`r?`n", " "))

Write-Host ("heal needed=[{0}] acted=[{1}] layer={2} rag_ready={3} inbox={4} ok={5}" -f `
    ($needed -join ","), ($acted -join ","), $diagnose.layer, $after.rag_ready, $inbox.waiting, $ok)

# Remember only a failed or acted loop. Success-every-5-min is wiki noise.
$shouldRemember = $needed.Count -gt 0 -or $acted.Count -gt 0 -or -not $ok `
    -or -not $after.icmp_loopback -or -not $after.dns_self -or -not $after.nic_tcpip `
    -or -not $after.rag_ready
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
    if ($env:GODBRAIN_API_TOKEN) {
        try {
            $obsHeaders = @{
                "Content-Type"  = "application/json"
                "Authorization" = "Bearer $($env:GODBRAIN_API_TOKEN)"
            }
            $observe = Invoke-RestMethod -Uri "http://127.0.0.1:8083/api/observe" `
                -Method POST -Headers $obsHeaders -Body "{}" -TimeoutSec 8
            Write-Host ("heal observed {0}" -f $observe.store_status)
        } catch {
            Write-Host "heal observe skipped: $_"
        }
    }
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
    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:8083/api/heal" -TimeoutSec 3 | Out-Null
        Write-Host "heal wrote last-heal"
    } catch {
        Write-Host "heal glance skipped: $_"
    }
    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:8083/api/last" -TimeoutSec 3 | Out-Null
        Write-Host "heal wrote last-oracle"
    } catch {
        Write-Host "heal last skipped: $_"
    }
    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:8083/api/last-edit" -TimeoutSec 3 | Out-Null
        Write-Host "heal wrote last-edit"
    } catch {
        Write-Host "heal last-edit skipped: $_"
    }
}

if (-not $ok) { exit 1 }
exit 0
