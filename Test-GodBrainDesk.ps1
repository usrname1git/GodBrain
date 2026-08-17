# Fail-closed desk check. No generate. No GPU. Safe after Start or Heal.
# Exit 0 only if the local doors answer and the one-slot map is intact.

[CmdletBinding()]
param(
    [string]$RepoRoot = $PSScriptRoot,
    [string]$Base = "http://127.0.0.1:8083"
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($RepoRoot) -and $MyInvocation.MyCommand.Path) {
    $RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$fails = [System.Collections.Generic.List[string]]::new()

function Get-Json([string]$Path) {
    return Invoke-RestMethod -Uri ($Base + $Path) -TimeoutSec 4
}

try { $status = Get-Json "/api/status" } catch { $fails.Add("status: $_"); $status = $null }
try { $brief = Get-Json "/api/brief" } catch { $fails.Add("brief: $_"); $brief = $null }
try { $vram = Get-Json "/api/vram" } catch { $fails.Add("vram: $_"); $vram = $null }
try { $doors = Get-Json "/api/doors" } catch { $fails.Add("doors: $_"); $doors = $null }
try { $heal = Get-Json "/api/heal" } catch { $fails.Add("heal: $_"); $heal = $null }
try {
    $deskApi = Get-Json "/api/desk"
    if ($deskApi.response -notmatch "desk=") { $fails.Add("desk api missing desk=") }
} catch {
    $fails.Add("desk: $_")
}
try { $null = Get-Json "/api/last" } catch { $fails.Add("last: $_") }
try {
    $pending = Get-Json "/api/pending"
    if ($pending.response -notmatch "judge=") { $fails.Add("pending api missing judge=") }
    if ($pending.response -notmatch "/verify") { $fails.Add("pending api missing /verify hint") }
    if ($null -eq $pending.items) { $fails.Add("pending api missing items") }
} catch {
    $fails.Add("pending: $_")
}

if ($status -and -not $status.kernel) { $fails.Add("status.kernel is false") }
if ($status -and $status.vram -and [int]$status.vram.slots -ne 1) {
    $fails.Add("vram.slots is not 1")
}
if ($brief -and [string]$brief.response -notmatch "llama=|coli=") {
    $fails.Add("brief missing mouth state")
}
if ($brief -and [string]$brief.response -notmatch "desk=") {
    $fails.Add("brief missing desk=")
}
$briefFile = Join-Path $RepoRoot "logs\last-brief.txt"
if (-not (Test-Path -LiteralPath $briefFile)) {
    $fails.Add("missing logs/last-brief.txt")
} elseif ((Get-Content -LiteralPath $briefFile -Raw) -notmatch "llama=|coli=") {
    $fails.Add("last-brief.txt missing mouth state")
}
if ($vram -and [string]$vram.response -notmatch "1 slot") {
    $fails.Add("vram missing 1 slot")
}
if ($doors) {
    if (-not $doors.loopback.brief) { $fails.Add("doors.loopback.brief missing") }
    if (-not $doors.loopback.desk) { $fails.Add("doors.loopback.desk missing") }
    if (-not $doors.loopback.pending) { $fails.Add("doors.loopback.pending missing") }
    if ($doors.tailscale.chat) { $fails.Add("chat must not be on Tailscale doors") }
    if ([int]$doors.slots -ne 1) { $fails.Add("doors.slots is not 1") }
}
$doorsFile = Join-Path $RepoRoot "logs\last-doors.json"
if (-not (Test-Path -LiteralPath $doorsFile)) {
    $fails.Add("missing logs/last-doors.json")
} else {
    try {
        $onDisk = Get-Content -LiteralPath $doorsFile -Raw | ConvertFrom-Json
        if ([int]$onDisk.slots -ne 1) { $fails.Add("last-doors.json slots is not 1") }
        if ($onDisk.tailscale.chat) { $fails.Add("last-doors.json has chat on Tailscale") }
    } catch {
        $fails.Add("last-doors.json unreadable")
    }
}
$pendingFile = Join-Path $RepoRoot "logs\last-pending.json"
if (-not (Test-Path -LiteralPath $pendingFile)) {
    $fails.Add("missing logs/last-pending.json")
} else {
    try {
        $onPending = Get-Content -LiteralPath $pendingFile -Raw | ConvertFrom-Json
        if ($null -eq $onPending.items) { $fails.Add("last-pending.json missing items") }
        if (-not $onPending.PSObject.Properties.Name.Contains("total")) {
            $fails.Add("last-pending.json missing total")
        }
    } catch {
        $fails.Add("last-pending.json unreadable")
    }
}
if ($heal -and -not $heal.live.kernel) { $fails.Add("heal.live.kernel is false") }
$healFile = Join-Path $RepoRoot "logs\heal-last.json"
if (-not (Test-Path -LiteralPath $healFile)) {
    $fails.Add("missing logs/heal-last.json")
} else {
    try {
        $hl = Get-Content -LiteralPath $healFile -Raw | ConvertFrom-Json
        if ([int]$hl.version -lt 3) { $fails.Add("heal-last.json version < 3") }
        if (-not $hl.PSObject.Properties.Name.Contains("mouth")) {
            $fails.Add("heal-last.json missing mouth")
        }
    } catch {
        $fails.Add("heal-last.json unreadable")
    }
}
foreach ($tn in @("GodBrainWatch", "GodBrainLogon", "GodBrainCs2Pause")) {
    & schtasks.exe /Query /TN $tn 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { $fails.Add("missing scheduled task $tn") }
}
$cs2sleep = [bool]($status -and $status.cs2 -and $status.cs2.sleep)
if (-not $cs2sleep) {
    foreach ($tn in @("GodBrainWatch", "GodBrainLogon")) {
        $qv = & schtasks.exe /Query /TN $tn /FO LIST /V 2>$null | Out-String
        if ($qv -notmatch "Scheduled Task State:\s+Enabled") {
            $fails.Add("task $tn should be Enabled while CS2 is idle")
        }
    }
    $watchTr = (& schtasks.exe /Query /TN GodBrainWatch /FO LIST /V 2>$null | Out-String) -replace "\s+", " "
    if ($watchTr -notmatch "watch\.cmd") {
        $fails.Add("GodBrainWatch TR missing watch.cmd")
    }
    if ($watchTr -match "-RepoRoot") {
        $fails.Add("GodBrainWatch TR still passes -RepoRoot (over 261 chars)")
    }
    $cs2Tr = (& schtasks.exe /Query /TN GodBrainCs2Pause /FO LIST /V 2>$null | Out-String) -replace "\s+", " "
    if ($cs2Tr -notmatch "cs2pause\.cmd") {
        $fails.Add("GodBrainCs2Pause TR missing cs2pause.cmd")
    }
    if ($cs2Tr -match "-RepoRoot") {
        $fails.Add("GodBrainCs2Pause TR still passes -RepoRoot (over 261 chars)")
    }
    if (Test-Path -LiteralPath $briefFile) {
        $ageMin = ((Get-Date) - (Get-Item -LiteralPath $briefFile).LastWriteTime).TotalMinutes
        if ($ageMin -gt 20) {
            $fails.Add(("last-brief.txt stale ({0:n0} min; Watch/Heal should refresh)" -f $ageMin))
        }
    }
    if (Test-Path -LiteralPath $doorsFile) {
        $doorAge = ((Get-Date) - (Get-Item -LiteralPath $doorsFile).LastWriteTime).TotalMinutes
        if ($doorAge -gt 20) {
            $fails.Add(("last-doors.json stale ({0:n0} min; Watch/Heal should refresh)" -f $doorAge))
        }
    }
    if (Test-Path -LiteralPath $pendingFile) {
        $pendAge = ((Get-Date) - (Get-Item -LiteralPath $pendingFile).LastWriteTime).TotalMinutes
        if ($pendAge -gt 20) {
            $fails.Add(("last-pending.json stale ({0:n0} min; Watch/Heal should refresh)" -f $pendAge))
        }
    }
    if (Test-Path -LiteralPath $healFile) {
        $healAge = ((Get-Date) - (Get-Item -LiteralPath $healFile).LastWriteTime).TotalMinutes
        if ($healAge -gt 20) {
            $fails.Add(("heal-last.json stale ({0:n0} min; Watch/Heal should refresh)" -f $healAge))
        }
    }
    $watchLog = Join-Path $RepoRoot "logs\watch.log"
    if (-not (Test-Path -LiteralPath $watchLog)) {
        $fails.Add("missing logs/watch.log (Watch should append each tick)")
    } else {
        $watchAge = ((Get-Date) - (Get-Item -LiteralPath $watchLog).LastWriteTime).TotalMinutes
        if ($watchAge -gt 20) {
            $fails.Add(("watch.log stale ({0:n0} min; Watch should append)" -f $watchAge))
        }
    }
    $watchXml = & schtasks.exe /Query /TN GodBrainWatch /XML 2>$null | Out-String
    if ($watchXml -match "DisallowStartIfOnBatteries>\s*true") {
        $fails.Add("GodBrainWatch will not start on batteries")
    }
}
try {
    $galaxy = Invoke-WebRequest -UseBasicParsing -TimeoutSec 4 -Uri ($Base + "/galaxy")
    $html = [string]$galaxy.Content
    if ($html -notmatch "GodBrain mouth") { $fails.Add("galaxy title missing GodBrain mouth") }
    if ($html -match "Colibri RAG Uplink") { $fails.Add("galaxy still says Colibri RAG Uplink") }
    if ($html -notmatch "desk_test") { $fails.Add("galaxy overlay missing desk_test") }
    if ($html -notmatch "desk-btn") { $fails.Add("galaxy missing Desk button") }
    if ($html -notmatch "pending-btn") { $fails.Add("galaxy missing Pending button") }
} catch {
    $fails.Add("galaxy: $_")
}

$result = [ordered]@{
    at     = (Get-Date).ToUniversalTime().ToString("o")
    ok     = ($fails.Count -eq 0)
    fails  = @($fails)
    mouth  = $(if ($status) { $status.mouth.label } else { "" })
    serve  = $(if ($status) { [bool]$status.coli.up } else { $false })
    cs2    = $cs2sleep
}
$logDir = Join-Path $RepoRoot "logs"
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}
$out = Join-Path $logDir "last-desk-test.json"
$tmp = $out + ".tmp"
$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($tmp, ($result | ConvertTo-Json -Compress), $utf8)
Move-Item -LiteralPath $tmp -Destination $out -Force

if ($fails.Count -gt 0) {
    Write-Host ("desk FAIL: {0}" -f ($fails -join "; "))
    exit 1
}
Write-Host ("desk ok mouth={0} serve={1}" -f $result.mouth, $result.serve)
exit 0
