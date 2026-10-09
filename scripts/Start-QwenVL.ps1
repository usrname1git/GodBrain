# Load Qwen3-VL 8B EXL3 on :8888 (vision on). One GPU slot: stop Paper Qwen first.
# Does not kill a generate. If :8888 is already up, leave it.
[CmdletBinding()]
param(
    [double]$Zoom = 1.0,
    [double]$Fps = 1,
    [ValidateRange(256, 262144)][int]$CacheSize = 57344,
    [ValidateSet("fp16", "4", "8", "8,4")][string]$CacheQuant = "fp16",
    [ValidateRange(0, 64)][double]$CpuCacheSizeGB = 4
)
$ErrorActionPreference = "Stop"
if ($CacheSize % 256) { throw "CacheSize must be a multiple of 256." }
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
if (Test-LoopbackPort 8871) {
    throw ":8871 is still listening. Stop the image model before starting VL. One GPU slot."
}
if (Test-LoopbackPort 8888) {
    $health = Invoke-RestMethod "http://127.0.0.1:8888/health" -TimeoutSec 3
    $models = Invoke-RestMethod "http://127.0.0.1:8888/v1/models" -TimeoutSec 3
    if ($models.data[0].id -ne "qwen3-vl-8b-exl3" -or
        $health.context_length -ne $CacheSize -or $health.cache_quant -ne $CacheQuant) {
        throw ":8888 is running a different model/cache configuration. Stop it before applying VL settings."
    }
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
$env:TRITON_CACHE_DIR = Join-Path $Kit "triton-cache"

try { $Host.UI.RawUI.WindowTitle = "qwen3-vl-8b-exl3" } catch {}
Write-Output "Starting qwen3-vl-8b-exl3 (vision on, ~110s CS clips: sample 1-2 fps, never full 60fps into VRAM)"
Set-Location -LiteralPath $Kit
$cacheArgs = if ($CacheQuant -eq "fp16") { @() } else { @("--cache_quant", $CacheQuant) }
& $py -u $serve `
    --model $model `
    --model_id qwen3-vl-8b-exl3 `
    --host 127.0.0.1 `
    --port 8888 `
    --cache_size $CacheSize `
    --grid_size 14.5 `
    --cpu_cache_size $CpuCacheSizeGB `
    --draft_model none `
    --vision auto `
    --image_max_pixels 1555200 `
    --media_root "C:\nvme\cs-clips" `
    --video_fps $Fps `
    --video_max_frames 60 `
    --video_max_pixels 307200 `
    --video_zoom $Zoom `
    --ffmpeg "C:\Tools\ffmpeg\ffmpeg.exe" `
    --ui off @cacheArgs
if ($LASTEXITCODE -ne 0) { throw "VL server exited with code $LASTEXITCODE." }
