# Qwen-Image-2.1 on 127.0.0.1:8871. One GPU slot.
# The 16 GB 4080 cannot hold the 7B DiT and the 8B text encoder together.
# This door uses CPU offload and 1024, not the native 2048.
# Stop whoever owns :8888 before starting. CPU http.server on :8000 is allowed.
[CmdletBinding()]
param([switch]$Allow2K)
$ErrorActionPreference = "Stop"
$Weights = "C:\nvme\Qwen-Image-2.1"
$Py = Join-Path $Weights ".venv\Scripts\python.exe"
$Server = Join-Path $PSScriptRoot "qwen_image_server.py"

function Test-LoopbackPort([int]$Port) {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $ok = $client.ConnectAsync("127.0.0.1", $Port).Wait(400)
        $client.Close()
        return [bool]$ok
    } catch { return $false }
}

function Assert-ImageGpuSlot {
    if (Test-LoopbackPort 8000) {
        $listeners = @(Get-NetTCPConnection -LocalPort 8000 -State Listen -ErrorAction Stop)
        if ($listeners.Count -eq 0) { throw "Could not identify the :8000 listener. Image was not started." }
        foreach ($listener in $listeners) {
            $owner = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f [int]$listener.OwningProcess) -ErrorAction Stop
            if (-not $owner -or $owner.Name -notmatch '^python(?:w)?\.exe$' -or
                $owner.CommandLine -notmatch '(?:^|\s)-m\s+http\.server(?:\s|$)') {
                throw ":8000 is held by a model or unknown process. Stop it before starting Qwen-Image-2.1. One GPU slot."
            }
        }
    }
    if (Test-LoopbackPort 8888) {
        throw ":8888 is still listening. Stop 27B or Qwen-VL before starting the image model. One GPU slot."
    }
}

if (-not (Test-Path -LiteralPath (Join-Path $Weights "model_index.json"))) {
    throw "Qwen-Image-2.1 weights missing under $Weights."
}
if (-not (Test-Path -LiteralPath $Py)) { throw "Image venv missing at $Py" }
if (-not (Test-Path -LiteralPath $Server)) { throw "Image server missing at $Server" }
Assert-ImageGpuSlot
if (Test-LoopbackPort 8871) {
    Write-Output "already up http://127.0.0.1:8871/health"
    exit 0
}

$env:PYTHONIOENCODING = "utf-8"
$env:PYTHONUTF8 = "1"
$env:QWEN_IMAGE_WEIGHTS = $Weights
$env:QWEN_IMAGE_MAX = $(if ($Allow2K) { "2048" } else { "1024" })
try { $Host.UI.RawUI.WindowTitle = "qwen-image-2.1" } catch {}
Write-Output "Starting Qwen-Image-2.1 with CPU offload. Max side $($env:QWEN_IMAGE_MAX). Native 2K is -Allow2K."
& $Py -u $Server
if ($LASTEXITCODE -ne 0) { throw "Qwen-Image-2.1 server failed (exit $LASTEXITCODE)." }
