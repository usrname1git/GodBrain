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
    $proc = Start-Process -FilePath $FilePath -ArgumentList $Arguments `
        -WorkingDirectory $WorkingDirectory -WindowStyle Minimized `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    Write-Log "started $Name pid=$($proc.Id) $FilePath $Arguments"
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

$coliDir = Join-Path $RepoRoot "LLM\colibri_LLM\c"
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
                COLI_GPU = "0"
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
    Start-LoggedProcess -Name "kernel" -FilePath $kernel `
        -WorkingDirectory (Split-Path $kernel -Parent)
}

Write-Log "GodBrain logon start finished"
Write-Log "Galaxy: http://127.0.0.1:8083/galaxy"
Write-Log "Shortcuts remember: POST http://127.0.0.1:8083/api/remember {`"text`":`"idea`"}"
