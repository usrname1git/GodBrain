# Put llama-server on :8000 so Galaxy can talk to a GGUF (Gemma 4 12B).
# Mouth persist: logs/mouth.txt. Do not pass -ngl with --fit on.
# Stops coli first. One GPU slot. Watch will skip coli while :8000 is up.

[CmdletBinding()]
param(
    [string]$RepoRoot = $PSScriptRoot,
    [string]$Model = "C:\nvme\gemma4-12b-hauhau\Gemma4-12B-QAT-Uncensored-HauhauCS-Balanced-Q4_K_M.gguf",
    [string]$Draft = "C:\nvme\gemma4-12b-hauhau\mtp-gemma-4-12B-it.gguf",
    [string]$Server = "C:\nvme\llama-cpp\llama-server.exe",
    [int]$Port = 8000,
    [int]$Ctx = 8192,
    # MTP + Gemma4 hit CUDA illegal-memory-access twice on this 4080 Super.
    [switch]$UseDraft
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($RepoRoot) -and $MyInvocation.MyCommand.Path) {
    $RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
if (-not (Test-Path -LiteralPath $Model)) { throw "missing model $Model" }
if (-not (Test-Path -LiteralPath $Server)) { throw "missing llama-server $Server" }
if ($UseDraft -and -not (Test-Path -LiteralPath $Draft)) { throw "missing draft $Draft" }

$logDir = Join-Path $RepoRoot "logs"
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}

function Test-Port([int]$PortNum) {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $iar = $c.BeginConnect("127.0.0.1", $PortNum, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(400)
        if ($ok) { $c.EndConnect($iar) }
        $c.Close()
        return [bool]$ok
    } catch { return $false }
}

Write-Host "Start-LlamaServer: disabling Watch so it cannot restart coli mid-swap"
schtasks /Change /TN GodBrainWatch /DISABLE 2>$null | Out-Null
try {
$coli = @(Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match '(?i)coli(\.exe)?["'']?\s+serve' })
foreach ($p in $coli) {
    Write-Host ("Start-LlamaServer: stopping coli pid={0}" -f $p.ProcessId)
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
}
Get-Process -Name "coli" -ErrorAction SilentlyContinue | Stop-Process -Force
Get-Process -Name "llama-server" -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host ("Start-LlamaServer: stopping llama-server pid={0}" -f $_.Id)
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
}
$deadline = (Get-Date).AddSeconds(20)
while (Test-Port $Port) {
    if ((Get-Date) -gt $deadline) { throw ":$Port still busy after stopping coli" }
    Start-Sleep -Milliseconds 400
}

$stdout = Join-Path $logDir "llama-server.out.log"
$stderr = Join-Path $logDir "llama-server.err.log"
# Rotate logs so a killed llama-server handle cannot block the new redirect.
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
foreach ($log in @($stdout, $stderr)) {
    if (Test-Path -LiteralPath $log) {
        Move-Item -LiteralPath $log -Destination "$log.$stamp" -Force -ErrorAction SilentlyContinue
    }
}
# Mouth file first so Galaxy shows llama=down while weights load.
[System.IO.File]::WriteAllText((Join-Path $logDir "mouth.txt"), "llama-server gemma4-12b-hauhau-q4_k_m`n")

# Do not pass -ngl: --fit on only adjusts unset knobs. 999 packed the 16 GB card.
# WMI Create so llama-server is not a child of this shell's Job Object.
# Start-Process dies with the agent wrapper; Win32_Process.Create does not.
$wrap = Join-Path $logDir "llama-server.launch.cmd"
$argParts = @(
    "--host 127.0.0.1",
    "--port $Port",
    "-m `"$Model`"",
    "--fit on",
    "-np 1",
    "-c $Ctx",
    "-fa on",
    "--jinja",
    "-a Gemma4-12B-HauhauCS"
)
if ($UseDraft) {
    $argParts += @(
        "-md `"$Draft`"",
        "--spec-type draft-mtp",
        "--spec-draft-n-max 3"
    )
}
$quotedArgs = $argParts -join " "
$lines = @(
    "@echo off",
    "cd /d `"$(Split-Path $Server -Parent)`"",
    "`"$Server`" $quotedArgs >> `"$stdout`" 2>> `"$stderr`""
)
$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllLines($wrap, $lines, $utf8)

Write-Host "Start-LlamaServer: starting $Server"
$created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
    CommandLine      = "cmd.exe /c `"$wrap`""
    CurrentDirectory = (Split-Path $Server -Parent)
}
if ($created.ReturnValue -ne 0) {
    throw "Win32_Process.Create=$($created.ReturnValue)"
}
$cmdPid = [int]$created.ProcessId
Write-Host "Start-LlamaServer: cmd pid=$cmdPid"

$up = $false
$waitUntil = (Get-Date).AddMinutes(8)
while ((Get-Date) -lt $waitUntil) {
    $alive = Get-Process -Id $cmdPid -ErrorAction SilentlyContinue
    $llama = Get-Process -Name "llama-server" -ErrorAction SilentlyContinue
    if (-not $alive -and -not $llama) {
        throw "llama-server process gone before healthy. See $stderr"
    }
    if (Test-Port $Port) {
        try {
            $h = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 2
            if ($h.StatusCode -eq 200) { $up = $true; break }
        } catch { }
    }
    Start-Sleep -Seconds 2
}
if (-not $up) {
    throw "llama-server did not become healthy on :$Port. See $stderr"
}
Write-Host "Start-LlamaServer: up on :$Port  model=$Model"
Write-Host "Galaxy: http://127.0.0.1:8083/galaxy"
} finally {
    schtasks /Change /TN GodBrainWatch /ENABLE 2>$null | Out-Null
}
exit 0
