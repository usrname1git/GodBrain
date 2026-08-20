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
    $sre = Get-Json "/api/sre"
    if ($sre.response -notmatch "sre=diagnose-only") { $fails.Add("sre api missing diagnose-only") }
    if ($sre.response -notmatch "layer=") { $fails.Add("sre api missing layer=") }
} catch {
    $fails.Add("sre: $_")
    $sre = $null
}
try {
    $deskApi = Get-Json "/api/desk"
    if ($deskApi.response -notmatch "desk=") { $fails.Add("desk api missing desk=") }
} catch {
    $fails.Add("desk: $_")
}
try {
    $lastApi = Get-Json "/api/last"
    if ($lastApi.response -notmatch "Oracle turn|No Oracle") {
        $fails.Add("last api missing Oracle turn text")
    }
} catch { $fails.Add("last: $_") }
$lastOracleFile = Join-Path $RepoRoot "logs\last-oracle.txt"
if (-not (Test-Path -LiteralPath $lastOracleFile)) {
    $fails.Add("missing logs/last-oracle.txt")
} elseif ((Get-Content -LiteralPath $lastOracleFile -Raw) -notmatch "Oracle turn|No Oracle") {
    $fails.Add("last-oracle.txt missing Oracle turn text")
}
try {
    $lastEditApi = Get-Json "/api/last-edit"
    if ($lastEditApi.response -notmatch "edit=") { $fails.Add("last-edit api missing edit=") }
} catch {
    if ("$_" -notmatch "404") { $fails.Add("last-edit: $_") }
}
$lastEditFile = Join-Path $RepoRoot "logs\last-edit.txt"
if (-not (Test-Path -LiteralPath $lastEditFile)) {
    $fails.Add("missing logs/last-edit.txt")
} elseif ((Get-Content -LiteralPath $lastEditFile -Raw) -notmatch "edit=") {
    $fails.Add("last-edit.txt missing edit=")
}
try {
    $pending = Get-Json "/api/pending"
    if ($pending.response -notmatch "judge=") { $fails.Add("pending api missing judge=") }
    if ($pending.response -notmatch "/verify") { $fails.Add("pending api missing /verify hint") }
    if ($null -eq $pending.items) { $fails.Add("pending api missing items") }
    if ($pending.items) {
        foreach ($item in @($pending.items)) {
            if ([string]$item.preview -match "^Heal loop") {
                $fails.Add("pending includes Heal loop remember noise")
                break
            }
            if ([string]$item.preview -match "^Session digest") {
                $fails.Add("pending includes Session digest sludge")
                break
            }
            if ([string]$item.kind -eq "concept") {
                $fails.Add("pending includes concept sludge")
                break
            }
        }
    }
} catch {
    $fails.Add("pending: $_")
}

if ($status -and -not $status.kernel) { $fails.Add("status.kernel is false") }
if ($status -and $status.host_record) {
    $hostLabel = [string]$status.host_record.label
    if ($hostLabel -match "Playbook") {
        $fails.Add("host_record is a playbook, not the os_pin inventory")
    } elseif ($hostLabel -notmatch "os_pin=|Windows host inventory") {
        $fails.Add("host_record missing os_pin inventory text")
    }
}
if ($status -and $null -eq $status.pending_items) {
    $fails.Add("status missing pending_items")
}
if ($status -and $status.heal -and $status.heal.ok -ne $null -and $null -eq $status.heal.age_min) {
    $fails.Add("status.heal missing age_min")
}
$gateExe = Join-Path $RepoRoot "godbrain_core\cpp_tools\cs2_gate.exe"
if (-not (Test-Path -LiteralPath $gateExe)) {
    $fails.Add("missing cs2_gate.exe")
}
$ask = Join-Path $RepoRoot "scripts\Ask-GodBrain.ps1"
if (-not (Test-Path -LiteralPath $ask)) {
    $fails.Add("missing scripts/Ask-GodBrain.ps1")
}
foreach ($helper in @(
        "scripts\Start-LlamaServer.ps1",
        "scripts\Invoke-Librarian.ps1",
        "scripts\Resolve-GodBrainRoot.ps1"
    )) {
    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $helper))) {
        $fails.Add("missing $helper")
    }
}
foreach ($stale in @(
        "Ask-GodBrain.ps1",
        "Invoke-Librarian.ps1",
        "Start-LlamaServer.ps1",
        "build_pipeline.ps1",
        "AGENT_FACTORY_ROSTER.md"
    )) {
    if (Test-Path -LiteralPath (Join-Path $RepoRoot $stale)) {
        $fails.Add("stale root $stale (moved to scripts/ or docs/)")
    }
}
if ($status -and $status.vram -and [int]$status.vram.slots -ne 1) {
    $fails.Add("vram.slots is not 1")
}
if ($brief -and [string]$brief.response -notmatch "llama=|coli=") {
    $fails.Add("brief missing mouth state")
}
if ($brief -and [string]$brief.response -notmatch "desk=") {
    $fails.Add("brief missing desk=")
}
if ($brief -and [string]$brief.response -notmatch "inbox=") {
    $fails.Add("brief missing inbox=")
}
if ($brief -and [string]$brief.response -notmatch "sre=") {
    $fails.Add("brief missing sre=")
}
if ($brief -and [string]$brief.response -match "heal=lie") {
    $ragDown = -not ($status -and $status.rag -and [bool]$status.rag.ready)
    $mouthDown = -not ($status -and $status.coli -and [bool]$status.coli.up)
    if ($ragDown -or $mouthDown) {
        $fails.Add("brief heal=lie (live ports disagree with heal-last)")
    }
}
if ($brief -and [string]$brief.response -match " rag=ready" -and $status -and $status.rag -and -not [bool]$status.rag.ready) {
    $fails.Add("brief rag=ready but status.rag.ready is false")
}
if ($brief -and [string]$brief.response -match "=(serve|busy) " -and $status -and $status.coli -and -not [bool]$status.coli.up) {
    $fails.Add("brief mouth serve/busy but coli.up is false")
}
if ($status -and $status.pending_judge -and [int]$status.pending_judge.total -gt 0) {
    if ($brief -and [string]$brief.response -notmatch "next=") {
        $fails.Add("brief missing next= while judge waiting")
    }
}
if ($status -and ($null -eq $status.inbox -or $null -eq $status.inbox.waiting)) {
    $fails.Add("status missing inbox.waiting")
}
if ($status -and $status.tailscale -and $status.tailscale.bound) {
    if ($brief -and [string]$brief.response -notmatch "tail=door/") {
        $fails.Add("brief missing tail=door/<ip> while Tailscale door is bound")
    }
}
$briefFile = Join-Path $RepoRoot "logs\last-brief.txt"
if (-not (Test-Path -LiteralPath $briefFile)) {
    $fails.Add("missing logs/last-brief.txt")
} elseif ((Get-Content -LiteralPath $briefFile -Raw) -notmatch "llama=|coli=") {
    $fails.Add("last-brief.txt missing mouth state")
} elseif ((Get-Content -LiteralPath $briefFile -Raw) -notmatch "inbox=") {
    $fails.Add("last-brief.txt missing inbox=")
} elseif ((Get-Content -LiteralPath $briefFile -Raw) -notmatch "sre=") {
    $fails.Add("last-brief.txt missing sre=")
}
if ($vram -and [string]$vram.response -notmatch "1 slot") {
    $fails.Add("vram missing 1 slot")
}
$vramFile = Join-Path $RepoRoot "logs\last-vram.json"
if (-not (Test-Path -LiteralPath $vramFile)) {
    $fails.Add("missing logs/last-vram.json")
} else {
    try {
        $onVram = Get-Content -LiteralPath $vramFile -Raw | ConvertFrom-Json
        if ([int]$onVram.slots -ne 1) { $fails.Add("last-vram.json slots is not 1") }
        if ([string]$onVram.response -notmatch "1 slot") {
            $fails.Add("last-vram.json missing 1 slot")
        }
    } catch {
        $fails.Add("last-vram.json unreadable")
    }
}
if ($doors) {
    if (-not $doors.loopback.brief) { $fails.Add("doors.loopback.brief missing") }
    if (-not $doors.loopback.desk) { $fails.Add("doors.loopback.desk missing") }
    if (-not $doors.loopback.pending) { $fails.Add("doors.loopback.pending missing") }
    if (-not $doors.loopback.vram) { $fails.Add("doors.loopback.vram missing") }
    if (-not $doors.loopback.last_edit) { $fails.Add("doors.loopback.last_edit missing") }
    if (-not $doors.loopback.sre) { $fails.Add("doors.loopback.sre missing") }
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
        if (-not $onPending.PSObject.Properties.Name.Contains("cards")) {
            $fails.Add("last-pending.json missing cards")
        }
    } catch {
        $fails.Add("last-pending.json unreadable")
    }
}
if ($heal -and -not $heal.live.kernel) { $fails.Add("heal.live.kernel is false") }
if ($heal -and [string]$heal.response -notmatch "last ok=|no heal run") {
    $fails.Add("heal api missing last ok= text")
}
if ($heal -and $heal.last -and $heal.response -notmatch "sre=") {
    $fails.Add("heal api missing sre=")
}
if ($heal -and $heal.last -and $heal.response -notmatch "match=") {
    $fails.Add("heal api missing match=live|lie")
}
if ($heal -and [string]$heal.response -match "match=lie") {
    $fails.Add("heal match=lie (live ports disagree with heal-last)")
}
if ($heal -and $heal.last -and $null -eq $heal.age_min) {
    $fails.Add("heal api missing age_min")
}
$lastHealFile = Join-Path $RepoRoot "logs\last-heal.txt"
if (-not (Test-Path -LiteralPath $lastHealFile)) {
    $fails.Add("missing logs/last-heal.txt")
} elseif ((Get-Content -LiteralPath $lastHealFile -Raw) -notmatch "last ok=|no heal run") {
    $fails.Add("last-heal.txt missing last ok=")
} elseif ((Get-Content -LiteralPath $lastHealFile -Raw) -notmatch "sre=") {
    $fails.Add("last-heal.txt missing sre=")
} elseif ((Get-Content -LiteralPath $lastHealFile -Raw) -notmatch "match=") {
    $fails.Add("last-heal.txt missing match=")
}
$lastSreFile = Join-Path $RepoRoot "logs\last-sre.txt"
if (-not (Test-Path -LiteralPath $lastSreFile)) {
    $fails.Add("missing logs/last-sre.txt")
} elseif ((Get-Content -LiteralPath $lastSreFile -Raw) -notmatch "sre=diagnose-only") {
    $fails.Add("last-sre.txt missing diagnose-only")
}
$healFile = Join-Path $RepoRoot "logs\heal-last.json"
if (-not (Test-Path -LiteralPath $healFile)) {
    $fails.Add("missing logs/heal-last.json")
} else {
    try {
        $hl = Get-Content -LiteralPath $healFile -Raw | ConvertFrom-Json
        if ([int]$hl.version -lt 4) { $fails.Add("heal-last.json version < 4") }
        if (-not $hl.PSObject.Properties.Name.Contains("mouth")) {
            $fails.Add("heal-last.json missing mouth")
        }
        if (-not $hl.PSObject.Properties.Name.Contains("rag_ready")) {
            $fails.Add("heal-last.json missing rag_ready")
        }
        if (-not $hl.PSObject.Properties.Name.Contains("inbox")) {
            $fails.Add("heal-last.json missing inbox")
        } elseif ($null -eq $hl.inbox.failed) {
            $fails.Add("heal-last.json inbox missing failed")
        }
        if (-not $hl.PSObject.Properties.Name.Contains("sre_diagnose")) {
            $fails.Add("heal-last.json missing sre_diagnose")
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
    if ($watchTr -match "watch\.cmd|\.cmd") {
        $fails.Add("GodBrainWatch TR still launches a .cmd (flashes WT)")
    }
    if ($watchTr -notmatch "Watch-GodBrain\.ps1") {
        $fails.Add("GodBrainWatch TR missing Watch-GodBrain.ps1")
    }
    if ($watchTr -notmatch "-RepoRoot") {
        $fails.Add("GodBrainWatch should pass -RepoRoot (Register-ScheduledTask, not schtasks /TR)")
    }
    $cs2Tr = (& schtasks.exe /Query /TN GodBrainCs2Pause /FO LIST /V 2>$null | Out-String) -replace "\s+", " "
    if ($cs2Tr -match "cs2pause\.cmd|\.cmd") {
        $fails.Add("GodBrainCs2Pause TR still launches a .cmd (flashes WT)")
    }
    if ($cs2Tr -notmatch "cs2_gate\.exe") {
        $fails.Add("GodBrainCs2Pause TR missing cs2_gate.exe")
    }
    if ($cs2Tr -match "pwsh\.exe|powershell\.exe") {
        $fails.Add("GodBrainCs2Pause should not start pwsh every minute")
    }
    $logonTr = (& schtasks.exe /Query /TN GodBrainLogon /FO LIST /V 2>$null | Out-String) -replace "\s+", " "
    if ($logonTr -match "\.cmd") {
        $fails.Add("GodBrainLogon TR still launches a .cmd (flashes WT)")
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
    if (Test-Path -LiteralPath $vramFile) {
        $vramAge = ((Get-Date) - (Get-Item -LiteralPath $vramFile).LastWriteTime).TotalMinutes
        if ($vramAge -gt 20) {
            $fails.Add(("last-vram.json stale ({0:n0} min; Watch/Heal should refresh)" -f $vramAge))
        }
    }
    if (Test-Path -LiteralPath $lastHealFile) {
        $lastHealAge = ((Get-Date) - (Get-Item -LiteralPath $lastHealFile).LastWriteTime).TotalMinutes
        if ($lastHealAge -gt 20) {
            $fails.Add(("last-heal.txt stale ({0:n0} min; Watch/Heal should refresh)" -f $lastHealAge))
        }
    }
    if (Test-Path -LiteralPath $lastSreFile) {
        $lastSreAge = ((Get-Date) - (Get-Item -LiteralPath $lastSreFile).LastWriteTime).TotalMinutes
        if ($lastSreAge -gt 20) {
            $fails.Add(("last-sre.txt stale ({0:n0} min; Watch/Heal should refresh)" -f $lastSreAge))
        }
    }
    if (Test-Path -LiteralPath $lastOracleFile) {
        $lastOracleAge = ((Get-Date) - (Get-Item -LiteralPath $lastOracleFile).LastWriteTime).TotalMinutes
        if ($lastOracleAge -gt 20) {
            $fails.Add(("last-oracle.txt stale ({0:n0} min; Watch/Heal should refresh)" -f $lastOracleAge))
        }
    }
    if (Test-Path -LiteralPath $lastEditFile) {
        $lastEditAge = ((Get-Date) - (Get-Item -LiteralPath $lastEditFile).LastWriteTime).TotalMinutes
        if ($lastEditAge -gt 20) {
            $fails.Add(("last-edit.txt stale ({0:n0} min; Watch/Heal should refresh)" -f $lastEditAge))
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
    if ($html -notmatch "last-edit-btn") { $fails.Add("galaxy missing Last edit button") }
    if ($html -notmatch "sre-btn") { $fails.Add("galaxy missing SRE button") }
    if ($html -notmatch "pendingOverlayLines") { $fails.Add("galaxy overlay missing pending list") }
    if ($html -notmatch "healAgeMinutes") { $fails.Add("galaxy overlay missing heal age") }
    if ($html -notmatch "inboxOverlayLine") { $fails.Add("galaxy overlay missing inbox") }
    if ($html -notmatch "brief\|vram\|doors\|heal\|sre\|last-edit\|last\|desk\|pending") {
        $fails.Add("galaxy chat still sends /pending through generate")
    }
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
