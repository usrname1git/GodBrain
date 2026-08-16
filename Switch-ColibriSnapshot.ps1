# Switch coli serve to another Colibri snapshot on this host.
# Never deletes by default. Never touches kernel. Refuses if the dest tree
# looks incomplete. Use after a full download, not mid-pull.

[CmdletBinding()]
param(
    [string]$RepoRoot = $PSScriptRoot,
    [string]$NewModel = "C:\nvme\glm52-uncensored",
    [switch]$RemoveOld
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($RepoRoot) -and $MyInvocation.MyCommand.Path) {
    $RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    throw "Switch-ColibriSnapshot: RepoRoot is empty."
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)

function Test-ColibriSnapshot([string]$Path) {
    $need = @(
        (Join-Path $Path "config.json"),
        (Join-Path $Path "tokenizer.json")
    )
    foreach ($f in $need) {
        if (-not (Test-Path -LiteralPath $f)) {
            throw "Incomplete snapshot: missing $f"
        }
    }
    $shards = @(Get-ChildItem -LiteralPath $Path -Filter "out-*.safetensors" -File -ErrorAction SilentlyContinue)
    if ($shards.Count -lt 130) {
        throw "Incomplete snapshot: $($shards.Count) out-*.safetensors (need >= 130)"
    }
    $gb = [math]::Round((($shards | Measure-Object Length -Sum).Sum) / 1GB, 1)
    if ($gb -lt 300) {
        throw "Incomplete snapshot: ${gb} GB of shards (need >= 300)"
    }
    return @{ shards = $shards.Count; gb = $gb }
}

$check = Test-ColibriSnapshot $NewModel
Write-Host ("dest ok shards={0} gb={1}" -f $check.shards, $check.gb)

$coliDir = $env:GODBRAIN_COLIBRI_DIR
if (-not $coliDir) {
    $sibling = Join-Path (Split-Path $RepoRoot -Parent) "colibri\c"
    if (Test-Path -LiteralPath (Join-Path $sibling "coli")) {
        $coliDir = $sibling
    } else {
        $coliDir = Join-Path $RepoRoot "LLM\colibri_LLM\c"
    }
}
$coli = Join-Path $coliDir "coli"
if (-not (Test-Path -LiteralPath $coli)) { $coli = Join-Path $coliDir "coli.exe" }
if (-not (Test-Path -LiteralPath $coli)) { throw "missing coli at $coliDir" }

# Stop only coli serve (python ... coli serve). Never kernel, never random python.
$stopped = $false
Get-CimInstance Win32_Process -Filter "Name='python.exe'" | ForEach-Object {
    if ($_.CommandLine -match 'coli["'']? serve') {
        Write-Host "stopping coli serve pid=$($_.ProcessId)"
        Stop-Process -Id $_.ProcessId -Force
        $stopped = $true
    }
}
if ($stopped) { Start-Sleep -Seconds 3 }

$env:GODBRAIN_SNAPSHOT_PATH = $NewModel
$env:COLI_MODEL = $NewModel
# Persist for Heal/Watch/logon. User env is what schtasks inherit; the
# file is the fallback when env is empty. Session-only env is not enough.
$logDir = Join-Path $RepoRoot "logs"
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}
$persist = Join-Path $logDir "coli-model.txt"
$tmp = $persist + ".tmp"
$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($tmp, $NewModel + [Environment]::NewLine, $utf8)
Move-Item -LiteralPath $tmp -Destination $persist -Force
[Environment]::SetEnvironmentVariable("GODBRAIN_SNAPSHOT_PATH", $NewModel, "User")
Write-Host "pinned $NewModel (logs/coli-model.txt + User env)"

$starter = Join-Path $RepoRoot "Start-GodBrain.ps1"
& $starter -RepoRoot $RepoRoot -MongoWaitSeconds 5

$deadline = (Get-Date).AddSeconds(180)
$up = $false
while ((Get-Date) -lt $deadline) {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect("127.0.0.1", 8000, $null, $null)
        $up = $iar.AsyncWaitHandle.WaitOne(400)
        if ($up) { $client.EndConnect($iar) }
        $client.Close()
        if ($up) { break }
    } catch { $up = $false }
    Start-Sleep -Milliseconds 500
}
if (-not $up) { throw "coli :8000 did not come back after switch to $NewModel" }
Write-Host "coli serve up on $NewModel"

if ($RemoveOld) {
    Write-Host "RemoveOld is ignored. This host has a single snapshot: $NewModel"
}
