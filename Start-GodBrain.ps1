# Start GodBrain as the logged-in user after Windows logon.
# Not a LocalSystem service: Colibri/CUDA must see an interactive session.
# MongoDB is assumed to already run as its own Windows service.

[CmdletBinding()]
param(
    [string]$RepoRoot = $PSScriptRoot,
    [int]$MongoWaitSeconds = 30
)

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
$model = $env:GODBRAIN_SNAPSHOT_PATH
if (-not $model) { $model = $env:COLI_MODEL }
if (-not $model) { $model = "C:\nvme\glm52" }
if (Test-Port "127.0.0.1" 8000) {
    Write-Log "skip coli serve (:8000 already listening)"
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
    try {
        $headers = @{ "Content-Type" = "application/json" }
        if ($env:GODBRAIN_API_TOKEN) {
            $headers["Authorization"] = "Bearer $($env:GODBRAIN_API_TOKEN)"
        }
        $observe = Invoke-RestMethod -Uri "http://127.0.0.1:8083/api/observe" `
            -Method POST -Headers $headers -Body "{}"
        Write-Log ("observe {0} stable_id={1}" -f $observe.store_status, $observe.stable_id)
    } catch {
        Write-Log "observe failed: $_"
    }
}

Write-Log "GodBrain logon start finished"
Write-Log "Galaxy: http://127.0.0.1:8083/galaxy"
Write-Log "Shortcuts remember: POST http://127.0.0.1:8083/api/remember {`"text`":`"idea`"}"
Write-Log "Judge: POST http://127.0.0.1:8083/api/judge {`"id`":`"stable_id`",`"status`":`"verified`",`"reasoning`":`"why`"}"
