# Load Qwen3-VL 8B EXL3 on :8888 (vision on). One GPU slot: stop Paper Qwen first.
# Does not kill a generate. If :8888 is already up, leave it.
[CmdletBinding()]
param(
    [double]$Zoom = 1.0,
    [double]$Fps = 1
)
$ErrorActionPreference = "Stop"
$Kit = "C:\nvme\Qwen3.8-27B-16gb"
$model = "C:\nvme\qwen3-vl-8b-exl3"
if (-not (Test-Path -LiteralPath (Join-Path $model "config.json"))) {
    throw "Qwen3-VL 8B weights missing under $model. hf download ArtusDev/Qwen_Qwen3-VL-8B-Instruct-EXL3 --revision 5.0bpw_H6 --local-dir $model"
}

function Test-LoopbackPort([int]$Port) {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $ok = $client.ConnectAsync("127.0.0.1", $Port).Wait(400)
        $client.Close()
        return [bool]$ok
    } catch { return $false }
}

if (Test-LoopbackPort 8000) {
    throw ":8000 is still listening. Stop llama-server before starting VL. One GPU slot."
}
if (Test-LoopbackPort 8888) {
    Write-Output "already up http://127.0.0.1:8888/v1 (stop Paper Qwen before swapping to VL)"
    exit 0
}

$py = Join-Path $Kit ".venv\Scripts\python.exe"
if (-not (Test-Path -LiteralPath $py)) { throw "Paper Qwen venv missing at $py" }
$serve = Join-Path $Kit "tools\serve_openai.py"
if (-not (Test-Path -LiteralPath $serve)) { throw "serve_openai.py missing" }

Remove-Item Env:CUDA_HOME -ErrorAction SilentlyContinue
$ptxas = "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.3\bin\ptxas.exe"
if (Test-Path -LiteralPath $ptxas) { $env:TRITON_PTXAS_PATH = $ptxas }
$env:PYTHONIOENCODING = "utf-8"
$env:PYTHONUTF8 = "1"
$env:TRITON_CACHE_DIR = Join-Path $Kit "paper-godbrain\triton-cache"

try { $Host.UI.RawUI.WindowTitle = "qwen3-vl-8b-exl3" } catch {}
Write-Output "Starting qwen3-vl-8b-exl3 (vision on, ~110s CS clips: sample 1-2 fps, never full 60fps into VRAM)"
Set-Location -LiteralPath $Kit
& $py -u $serve `
    --model $model `
    --model_id qwen3-vl-8b-exl3 `
    --host 127.0.0.1 `
    --port 8888 `
    --cache_size 57344 `
    --grid_size 14.5 `
    --cpu_cache_size 4 `
    --draft_model none `
    --vision auto `
    --image_max_pixels 1555200 `
    --media_root "C:\nvme\cs-clips" `
    --video_fps $Fps `
    --video_max_frames 60 `
    --video_max_pixels 307200 `
    --video_zoom $Zoom `
    --ffmpeg "C:\Tools\ffmpeg\ffmpeg.exe" `
    --ui off
