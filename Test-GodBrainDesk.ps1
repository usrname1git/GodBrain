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
try { $null = Get-Json "/api/last" } catch { $fails.Add("last: $_") }

if ($status -and -not $status.kernel) { $fails.Add("status.kernel is false") }
if ($status -and $status.vram -and [int]$status.vram.slots -ne 1) {
    $fails.Add("vram.slots is not 1")
}
if ($brief -and [string]$brief.response -notmatch "llama=|coli=") {
    $fails.Add("brief missing mouth state")
}
if ($vram -and [string]$vram.response -notmatch "1 slot") {
    $fails.Add("vram missing 1 slot")
}
if ($doors) {
    if (-not $doors.loopback.brief) { $fails.Add("doors.loopback.brief missing") }
    if ($doors.tailscale.chat) { $fails.Add("chat must not be on Tailscale doors") }
    if ([int]$doors.slots -ne 1) { $fails.Add("doors.slots is not 1") }
}
if ($heal -and -not $heal.live.kernel) { $fails.Add("heal.live.kernel is false") }
try {
    $galaxy = Invoke-WebRequest -UseBasicParsing -TimeoutSec 4 -Uri ($Base + "/galaxy")
    $html = [string]$galaxy.Content
    if ($html -notmatch "GodBrain mouth") { $fails.Add("galaxy title missing GodBrain mouth") }
    if ($html -match "Colibri RAG Uplink") { $fails.Add("galaxy still says Colibri RAG Uplink") }
    if ($html -notmatch "desk_test") { $fails.Add("galaxy overlay missing desk_test") }
} catch {
    $fails.Add("galaxy: $_")
}

$result = [ordered]@{
    at     = (Get-Date).ToUniversalTime().ToString("o")
    ok     = ($fails.Count -eq 0)
    fails  = @($fails)
    mouth  = $(if ($status) { $status.mouth.label } else { "" })
    serve  = $(if ($status) { [bool]$status.coli.up } else { $false })
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
