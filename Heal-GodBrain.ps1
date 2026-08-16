# One loop for THIS host: discover (probe) → execute (start missing allowlist)
# → verify (ports) → remember (candidate). Not a multi-agent graph.
# Allowlist: rag :8084, coli :8000, kernel :8083. Never kills, never deletes, never DISM.
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

function Get-Probe {
    return [ordered]@{
        mongo  = Test-Port "127.0.0.1" 27017
        rag    = Test-Port "127.0.0.1" 8084
        coli   = Test-Port "127.0.0.1" 8000
        kernel = Test-Port "127.0.0.1" 8083
    }
}

$before = Get-Probe
$needed = @()
if (-not $before.rag) { $needed += "rag" }
if (-not $before.coli) { $needed += "coli" }
if (-not $before.kernel) { $needed += "kernel" }

if ($needed.Count -gt 0) {
    & $starter -RepoRoot $RepoRoot -MongoWaitSeconds 5
    Start-Sleep -Seconds 2
}

$after = Get-Probe
$ok = [bool]($after.rag -and $after.coli -and $after.kernel)
$result = [ordered]@{
    version     = 1
    at          = (Get-Date).ToUniversalTime().ToString("o")
    playbook    = "host-listeners"
    needed      = @($needed)
    before      = $before
    after       = $after
    ok          = $ok
    never_kills = $true
}

$json = $result | ConvertTo-Json -Depth 6
$last = Join-Path $logDir "heal-last.json"
$tmp = $last + ".tmp"
$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($tmp, $json, $utf8)
Move-Item -LiteralPath $tmp -Destination $last -Force
Add-Content -LiteralPath (Join-Path $logDir "heal.jsonl") -Value (($json -replace "`r?`n", " "))

Write-Host ("heal needed=[{0}] ok={1}" -f ($needed -join ","), $ok)

if ($env:GODBRAIN_API_TOKEN -and $after.kernel) {
    try {
        $headers = @{
            "Content-Type"  = "application/json"
            "Authorization" = "Bearer $($env:GODBRAIN_API_TOKEN)"
        }
        $body = @{
            text   = "Heal loop (candidate)`nneeded=$($needed -join ',')`nok=$ok`nbefore=$($before | ConvertTo-Json -Compress)`nafter=$($after | ConvertTo-Json -Compress)"
            sector = "windows-sre"
        } | ConvertTo-Json
        Invoke-RestMethod -Uri "http://127.0.0.1:8083/api/remember" `
            -Method POST -Headers $headers -Body $body | Out-Null
        Write-Host "heal remembered"
    } catch {
        Write-Host "heal remember skipped: $_"
    }
}

if (-not $ok) { exit 1 }
exit 0
