# Start GodBrain as the logged-in user after Windows logon.
# Not a LocalSystem service: Colibri/CUDA must see an interactive session.
# MongoDB is the Windows service named MongoDB. Heal/Start may start it if
# :27017 is down. Never kill it.

[CmdletBinding()]
param(
    [string]$RepoRoot = $PSScriptRoot,
    [int]$MongoWaitSeconds = 30
)

# Nested powershell -File can leave $PSScriptRoot empty. Never start with
# an empty root: that is how a "cleanup" path becomes a wipe of cwd.
if ([string]::IsNullOrWhiteSpace($RepoRoot) -and $MyInvocation.MyCommand.Path) {
    $RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    throw "Start-GodBrain: RepoRoot is empty. Pass -RepoRoot explicitly."
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$marker = Join-Path $RepoRoot "Start-GodBrain.ps1"
if (-not (Test-Path -LiteralPath $marker)) {
    throw "Start-GodBrain: $RepoRoot is not the GodBrain repo (missing Start-GodBrain.ps1)."
}

$ErrorActionPreference = "Continue"
$logDir = Join-Path $RepoRoot "logs"
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}
$log = Join-Path $logDir "godbrain-logon.log"

function Write-Log([string]$Message) {
    $line = "{0:u} {1}" -f (Get-Date).ToUniversalTime(), $Message
    Add-Content -LiteralPath $log -Value $line
    Write-Host $line
}

function Test-Port([string]$HostName, [int]$Port) {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(400)
        if ($ok) { $client.EndConnect($iar) }
        $client.Close()
        return $ok
    } catch {
        return $false
    }
}

function Start-LoggedProcess {
    param(
        [string]$Name,
        [string]$FilePath,
        [string]$Arguments = "",
        [string]$WorkingDirectory,
        [hashtable]$Environment = @{}
    )
    if (-not (Test-Path -LiteralPath $FilePath)) {
        Write-Log "skip $Name (missing $FilePath)"
        return
    }
    foreach ($key in $Environment.Keys) {
        Set-Item -Path "Env:$key" -Value $Environment[$key]
    }
    $stdout = Join-Path $logDir "$Name.out.log"
    $stderr = Join-Path $logDir "$Name.err.log"
    $wrap = Join-Path $logDir "$Name.launch.cmd"
    $lines = @(
        "@echo off"
        "cd /d `"$WorkingDirectory`""
    )
    foreach ($key in $Environment.Keys) {
        if ($key -eq "MONGODB_URI" -or $key -eq "GODBRAIN_API_TOKEN") { continue }
        $lines += "set `"$key=$($Environment[$key])`""
    }
    # Do not persist MONGODB_URI or GODBRAIN_API_TOKEN. The kernel defaults
    # the URI; the token must come from the user/task environment.
    if ($Arguments) {
        $lines += "`"$FilePath`" $Arguments >> `"$stdout`" 2>> `"$stderr`""
    } else {
        $lines += "`"$FilePath`" >> `"$stdout`" 2>> `"$stderr`""
    }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllLines($wrap, $lines, $utf8)
    # WMI Create is owned by the SCM host, not this console/job. Start-Process
    # children die when the starter window or agent job exits — that is the
    # "kernel window popped and Galaxy died" failure.
    $created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine      = "cmd.exe /c `"$wrap`""
        CurrentDirectory = $WorkingDirectory
    }
    if ($created.ReturnValue -ne 0) {
        Write-Log "failed $Name Win32_Process.Create=$($created.ReturnValue)"
        return
    }
    Write-Log "started $Name pid=$($created.ProcessId) $FilePath $Arguments"
}

Write-Log "GodBrain logon start from $RepoRoot"

if (-not (Test-Port "127.0.0.1" 27017)) {
    $svc = Get-Service -Name "MongoDB" -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne "Running") {
        try {
            Start-Service -Name "MongoDB" -ErrorAction Stop
            Write-Log "started Windows service MongoDB"
        } catch {
            Write-Log "could not start MongoDB: $_"
        }
    } elseif (-not $svc) {
        Write-Log "Windows service MongoDB is not installed"
    }
}

$mongoDeadline = (Get-Date).AddSeconds($MongoWaitSeconds)
while (-not (Test-Port "127.0.0.1" 27017)) {
    if ((Get-Date) -gt $mongoDeadline) {
        Write-Log "MongoDB :27017 not up after ${MongoWaitSeconds}s; RAG will fail until it is"
        break
    }
    Start-Sleep -Seconds 1
}

if (-not $env:MONGODB_URI) {
    $env:MONGODB_URI = "mongodb://127.0.0.1:27017"
}

$rag = Join-Path $RepoRoot "godbrain_core\memory_store\rag-service.exe"
if (Test-Port "127.0.0.1" 8084) {
    Write-Log "skip rag-service (:8084 already listening)"
} else {
    Start-LoggedProcess -Name "rag-service" -FilePath $rag `
        -WorkingDirectory (Split-Path $rag -Parent)
}

$coliDir = $env:GODBRAIN_COLIBRI_DIR
if (-not $coliDir) {
    $sibling = Join-Path (Split-Path $RepoRoot -Parent) "colibri\c"
    if (Test-Path -LiteralPath (Join-Path $sibling "coli")) {
        $coliDir = $sibling
    } else {
        $coliDir = Join-Path $RepoRoot "LLM\colibri_LLM\c"
    }
}
Write-Log "coli dir $coliDir"
$coli = Join-Path $coliDir "coli"
if (-not (Test-Path -LiteralPath $coli)) {
    $coli = Join-Path $coliDir "coli.exe"
}

# Host pin for Heal/Watch/logon. Env wins for one-shot tests; otherwise the
# last Switch/Start path in logs/coli-model.txt. Default is the uncensored
# snapshot; never invent a second tree if persist/env is empty.
$persistModel = Join-Path $logDir "coli-model.txt"
function Get-PersistedModel {
    if (-not (Test-Path -LiteralPath $persistModel)) { return $null }
    $line = (Get-Content -LiteralPath $persistModel -TotalCount 1 -ErrorAction SilentlyContinue)
    if ($line) { $line = $line.Trim() }
    if ($line -and (Test-Path -LiteralPath $line)) { return $line }
    return $null
}
function Set-PersistedModel([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $tmp = $persistModel + ".tmp"
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($tmp, $Path.Trim() + [Environment]::NewLine, $utf8)
    Move-Item -LiteralPath $tmp -Destination $persistModel -Force
}
function Test-ColiServeProcess {
    $hit = Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'coli["'']? serve' }
    return [bool]$hit
}

$model = $env:GODBRAIN_SNAPSHOT_PATH
if (-not $model) { $model = $env:COLI_MODEL }
if ($model -and -not (Test-Path -LiteralPath $model)) {
    Write-Log "coli model $model is gone; fall through to persist/default"
    $model = $null
}
if (-not $model) { $model = Get-PersistedModel }
if (-not $model) { $model = "C:\nvme\glm52-uncensored" }
Write-Log "coli model $model"
if (Test-Path -LiteralPath $model) {
    Set-PersistedModel $model
}
if (Test-Port "127.0.0.1" 8000) {
    Write-Log "skip coli serve (:8000 already listening)"
} elseif (Test-ColiServeProcess) {
    Write-Log "skip coli serve (process already running, still loading)"
} elseif ((Test-Path -LiteralPath $coli) -and (Test-Path -LiteralPath $model)) {
    $pythonCmd = Get-Command python, python.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    $python = if ($pythonCmd) { $pythonCmd.Source } else { $null }
    if ($python) {
        Start-LoggedProcess -Name "coli-serve" -FilePath $python `
            -Arguments "`"$coli`" serve --host 127.0.0.1 --port 8000 --model `"$model`"" `
            -WorkingDirectory $coliDir `
            -Environment @{
                COLI_CUDA = "1"
                CUDA_EXPERT_GB = "12"
                # Auto RAM_GB is ~88% of free at boot. On 48 GB that became a
                # 32 GB working set, 0.8 GB commit left, and decode hung after
                # prefill until the kernel 720s cap. Leave room for Windows.
                RAM_GB = "28"
                CAP_RAISE = "0"
                RSS_GUARD_GB = "26"
                PIN = "C:\nvme\glm52-uncensored\.coli_usage"
                PIN_GB = "8"
                # Next CONTINUE/auto-chunk reuses the KV prefix instead of a
                # 78-layer re-prefill. Takes effect on the next coli start.
                COLI_KV_SHARE = "1"
            }
    } else {
        Write-Log "skip coli serve (python not on PATH)"
    }
} else {
    Write-Log "skip coli serve (need $coli and model dir $model)"
}

$kernel = Join-Path $RepoRoot "godbrain_core\cpp_kernel\godbrain-kernel.exe"
if (Test-Port "127.0.0.1" 8083) {
    Write-Log "skip kernel (:8083 already listening)"
} else {
    $kernelEnv = @{}
    if ($env:MONGODB_URI) { $kernelEnv["MONGODB_URI"] = $env:MONGODB_URI }
    if ($env:GODBRAIN_API_TOKEN) { $kernelEnv["GODBRAIN_API_TOKEN"] = $env:GODBRAIN_API_TOKEN }
    Start-LoggedProcess -Name "kernel" -FilePath $kernel `
        -WorkingDirectory (Split-Path $kernel -Parent) `
        -Environment $kernelEnv
}

$kernelDeadline = (Get-Date).AddSeconds(20)
while (-not (Test-Port "127.0.0.1" 8083)) {
    if ((Get-Date) -gt $kernelDeadline) {
        Write-Log "kernel :8083 not up after 20s; skip observe"
        break
    }
    Start-Sleep -Milliseconds 400
}
if (Test-Port "127.0.0.1" 8083) {
    if (-not $env:GODBRAIN_API_TOKEN) {
        Write-Log "skip observe (no GODBRAIN_API_TOKEN in this process)"
    } else {
        try {
            $headers = @{
                "Content-Type"  = "application/json"
                "Authorization" = "Bearer $($env:GODBRAIN_API_TOKEN)"
            }
            $observe = Invoke-RestMethod -Uri "http://127.0.0.1:8083/api/observe" `
                -Method POST -Headers $headers -Body "{}"
            Write-Log ("observe {0} stable_id={1}" -f $observe.store_status, $observe.stable_id)
        } catch {
            Write-Log "observe failed: $_"
        }
    }
}

Write-Log "GodBrain logon start finished"
Write-Log "Galaxy: http://127.0.0.1:8083/galaxy"
Write-Log "Shortcuts remember: POST http://127.0.0.1:8083/api/remember {`"text`":`"idea`"}"
Write-Log "Judge: POST http://127.0.0.1:8083/api/judge {`"id`":`"stable_id`",`"status`":`"verified`",`"reasoning`":`"why`"}"
