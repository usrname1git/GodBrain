# Keep paper Qwen :8888 and the frontend gym worker alive overnight.
# One GPU slot. Does not start llama-server. Honors CS2 / gym pause.
# Copy of the Copilot session watchdog, owned by this repo.
$env:POWERSHELL_TELEMETRY_OPTOUT = '1'
$ErrorActionPreference = "Stop"
$RepoRoot = $PSScriptRoot
. (Join-Path $PSScriptRoot "Resolve-GodBrainRoot.ps1")
. (Join-Path $RepoRoot "GodBrain-Cs2.ps1")

$pwsh = if (Test-Path -LiteralPath "C:\pwsh\pwsh.exe") { "C:\pwsh\pwsh.exe" } else { "pwsh.exe" }
$qwenStart = "C:\Temp\GitHub\Qwen3.8-27B-16gb\paper-godbrain\Start-PaperQwen.ps1"
$qwenModel = "C:\Temp\GitHub\Qwen3.8-27B-16gb\models\Qwen3.8-27B-EXL3-3.5bpw"
$gymDoor = Join-Path $RepoRoot "scripts\Invoke-FrontendGym.ps1"
$pauseProbe = Join-Path $RepoRoot "scripts\Get-FrontendGymPause.ps1"
$gymState = Join-Path $RepoRoot "godbrain_core\skill_lab\work\gym\state.json"
$runtimeDir = Join-Path $RepoRoot "godbrain_core\skill_lab\work\gym\watchdog"
$heartbeat = Join-Path $runtimeDir "heartbeat.json"
$events = Join-Path $runtimeDir "events.jsonl"
$qwenReceipt = Join-Path $runtimeDir "qwen-runtime.json"
$qwenOut = Join-Path $runtimeDir "qwen.out.log"
$qwenErr = Join-Path $runtimeDir "qwen.err.log"
$gymOut = Join-Path $runtimeDir "gym.out.log"
$gymErr = Join-Path $runtimeDir "gym.err.log"

New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null

function Write-WatchEvent([string]$kind, [string]$message) {
    $entry = [ordered]@{
        at = (Get-Date).ToUniversalTime().ToString("o")
        kind = $kind
        message = $message
    }
    Add-Content -LiteralPath $events -Value ($entry | ConvertTo-Json -Compress)
    $stamp = Get-Date -Format "HH:mm:ss"
    Write-Host ("[{0}] {1,-18} {2}" -f $stamp, $kind, $message)
}

function Get-FrontendPause {
    $manualPause = $false
    $stopQwen = $false
    $pauseFile = Join-Path $RepoRoot "godbrain_core\skill_lab\work\gym\training-pause.json"
    if (Test-Path -LiteralPath $pauseFile) {
        try {
            $control = Get-Content -LiteralPath $pauseFile -Raw -ErrorAction Stop | ConvertFrom-Json
            $manualPause = [bool]$control.paused
            $stopQwen = $manualPause -and [bool]$control.stopQwen
        } catch {
            Write-WatchEvent "pause_read" "training-pause.json unreadable; treating as not paused."
        }
    }
    $cs2Sleep = $false
    try {
        $cs2Sleep = [bool](Test-GodBrainColiShouldSleep -RepoRoot $RepoRoot)
    } catch {
        Write-WatchEvent "cs2_probe" $_.Exception.Message
    }
    [pscustomobject]@{
        cs2_sleep = $cs2Sleep
        manual_pause = $manualPause
        stop_qwen = $stopQwen
        paused = $manualPause -or $cs2Sleep
    }
}

function Write-WatchBanner {
    try { $Host.UI.RawUI.WindowTitle = "GodBrainGymWatch" } catch {}
    Write-Host "GodBrain gym watchdog" -ForegroundColor Cyan
    Write-Host "qwen3.8-27b-exl3-3.5bpw :8888 10k | Creation Lab http://127.0.0.1:4177 | one GPU slot | never kill generate" -ForegroundColor DarkCyan
    Write-Host "Dashboard runs hidden under this watchdog. Pause & Save keeps Qwen warm." -ForegroundColor DarkCyan
    Write-Host ("host PS {0} {1} | log {2}" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition, $events) -ForegroundColor DarkGray
    Write-Host ""
}

function Test-Port([int]$port) {
    return Test-LoopbackPort $port
}

function Get-QwenListenerProcess {
    $listener = Get-NetTCPConnection -LocalPort 8888 -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $listener) { return $null }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($listener.OwningProcess)" -ErrorAction SilentlyContinue
    if ($process -and
        $process.Name -eq "python.exe" -and
        $process.CommandLine -like "*serve_openai.py*" -and
        $process.CommandLine -like "*Qwen3.8-27B-EXL3-3.5bpw*") {
        return [pscustomobject]@{
            ProcessId = [int]$process.ProcessId
            Name = $process.Name
            CommandLine = $process.CommandLine
        }
    }
    return $null
}

function Set-QwenReceipt($process) {
    $started = (Get-Date).ToUniversalTime().ToString("o")
    if (Test-Path -LiteralPath $qwenReceipt) {
        try {
            $previous = Get-Content -LiteralPath $qwenReceipt -Raw | ConvertFrom-Json
            if ([int]$previous.pid -eq [int]$process.ProcessId -and $previous.started_at) {
                $started = [string]$previous.started_at
            }
        } catch {}
    }
    @{
        pid = $process.ProcessId
        port = 8888
        model = $qwenModel
        started_at = $started
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $qwenReceipt
}

function Get-QwenProcess {
    $listener = Get-QwenListenerProcess
    if ($listener) { Set-QwenReceipt $listener }
    return $listener
}

function Stop-Qwen {
    $owned = Get-QwenProcess
    $listener = Get-QwenListenerProcess
    $ids = @()
    if ($owned) { $ids += [int]$owned.ProcessId }
    if ($listener) { $ids += [int]$listener.ProcessId }
    foreach ($processId in ($ids | Select-Object -Unique)) {
        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
        Write-WatchEvent "qwen_stop" "Stopped Qwen pid=$processId after gym was idle."
    }
    $deadline = (Get-Date).AddSeconds(20)
    while ((Test-Port 8888) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 400
    }
    Remove-Item -LiteralPath $qwenReceipt -Force -ErrorAction SilentlyContinue
}

function Start-Qwen {
    if (Test-Port 8000) {
        Write-WatchEvent "qwen_blocked" "Port 8000 owns the single GPU slot; gym Qwen was not started."
        return
    }
    if (Get-QwenProcess) { return }
    if (Test-Port 8888) {
        Write-WatchEvent "qwen_keep" "Port 8888 already listening; leaving Qwen alone."
        return
    }
    $launcher = Start-Process -FilePath $pwsh `
        -ArgumentList @(
            "-NoLogo", "-NoProfile", "-File", $qwenStart
        ) `
        -WorkingDirectory (Split-Path (Split-Path $qwenStart -Parent) -Parent) `
        -WindowStyle Normal `
        -PassThru
    $deadline = (Get-Date).AddMinutes(4)
    $process = $null
    while (-not $process -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $process = Get-QwenListenerProcess
        if ($launcher.HasExited -and -not $process) {
            throw "Qwen launcher exited before :8888 became ready."
        }
    }
    if (-not $process) { throw "Qwen did not become ready on :8888 within four minutes." }
    Set-QwenReceipt $process
    Write-WatchEvent "qwen_start" "Started qwen3.8-27b-exl3-3.5bpw pid=$($process.ProcessId) at 10K with MTP off."
}

function Test-LoopbackPort([int]$Port) {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $ok = $client.ConnectAsync("127.0.0.1", $Port).Wait(400)
        $client.Close()
        return [bool]$ok
    } catch {
        return $false
    }
}

function Read-GymGlance {
    # Windows PowerShell 5.1 ConvertFrom-Json of gym state.json stack-overflows
    # (0xc00000fd / -1073741571). Node parses the 189-lesson graph; this host
    # only ConvertFrom-Json the tiny glance.
    if (-not (Test-Path -LiteralPath $gymState)) { return $null }
    $nodeExe = $null
    try { $nodeExe = (Get-Command node -ErrorAction Stop).Source } catch { $nodeExe = $null }
    if ($nodeExe) {
        $env:GODBRAIN_GYM_STATE = $gymState
        $js = 'const fs=require("fs");const s=JSON.parse(fs.readFileSync(process.env.GODBRAIN_GYM_STATE,"utf8"));process.stdout.write(JSON.stringify({pid:s.pid||null,status:s.status||null,lastError:s.lastError?String(s.lastError):null,taskId:(s.active&&s.active.taskId)||null,attempts:(s.stats&&s.stats.attempts)||null,infrastructureErrors:(s.stats&&s.stats.infrastructureErrors)||null,updatedAt:s.updatedAt||null}));'
        try {
            $json = & $nodeExe -e $js
            if (-not [string]::IsNullOrWhiteSpace($json)) { return $json | ConvertFrom-Json }
        } catch {}
    }
    $head = @(Get-Content -LiteralPath $gymState -TotalCount 16 -ErrorAction SilentlyContinue)
    $tail = @(Get-Content -LiteralPath $gymState -Tail 40 -ErrorAction SilentlyContinue)
    $status = $null
    $gymPid = $null
    foreach ($line in $head) {
        if ($line -match '^\s*"status"\s*:\s*"([^"]+)"') { $status = $Matches[1]; break }
    }
    foreach ($line in $tail) {
        if ($line -match '^\s*"pid"\s*:\s*(\d+)') { $gymPid = [int]$Matches[1]; break }
    }
    return [pscustomobject]@{
        pid = $gymPid
        status = $status
        lastError = $null
        taskId = $null
        attempts = $null
        infrastructureErrors = $null
        updatedAt = $null
    }
}

function Start-Dashboard {
    if (Test-LoopbackPort 4177) { return }
    $proc = Start-Process -FilePath $pwsh `
        -ArgumentList @(
            "-NoLogo", "-NoProfile", "-WindowStyle", "Hidden",
            "-File", $gymDoor, "-Command", "dashboard"
        ) `
        -WorkingDirectory $RepoRoot `
        -WindowStyle Hidden `
        -PassThru
    if ($proc) {
        Set-Content -LiteralPath (Join-Path $runtimeDir "dashboard-runtime.json") (
            (@{ pid = $proc.Id; at = (Get-Date).ToUniversalTime().ToString("o") } | ConvertTo-Json -Compress)
        )
    }
    Write-WatchEvent "dashboard_start" "Creation Lab http://127.0.0.1:4177 pid=$($proc.Id) (hidden; this Watch window is the console)."
}

function Start-Gym {
    $alive = $false
    $glance = Read-GymGlance
    if ($glance -and $glance.pid) {
        $process = Get-Process -Id ([int]$glance.pid) -ErrorAction SilentlyContinue
        $alive = $null -ne $process
    }
    if ($alive) { return }
    Start-Dashboard
    Start-Process -FilePath $pwsh `
        -ArgumentList @(
            "-NoLogo", "-NoProfile", "-NoExit", "-Command",
            "`$Host.UI.RawUI.WindowTitle='GodBrainGymWorker'; & `"$gymDoor`" -Continuous -NoDashboard -Endpoint http://127.0.0.1:8888/v1 -Model qwen3.8-27b-exl3-3.5bpw -MaxAttempts 4"
        ) `
        -WorkingDirectory $RepoRoot `
        -WindowStyle Normal | Out-Null
    Write-WatchEvent "gym_start" "Started the persistent frontend gym worker."
}

$lastHandledIma = ""
$lastRestartAt = [datetime]::MinValue
$lastPauseState = $false
$cudaUnsafe = $false
$lastHostLine = ""
$quietBeats = 0
Write-WatchBanner
Write-WatchEvent "watchdog_start" "Overnight frontend gym watchdog started from scripts\Watch-FrontendGymOvernight.ps1."

while ($true) {
    try {
        $state = Read-GymGlance

        $imaKey = ""
        if ($state -and $state.lastError -match "illegal memory access|cudaErrorIllegalAddress") {
            $imaKey = "$($state.infrastructureErrors)|$($state.updatedAt)|$($state.lastError)"
        }

        if ($imaKey -and $imaKey -ne $lastHandledIma) {
            Write-WatchEvent "cuda_ima" "CUDA IMA recorded. Not restarting Qwen (TDR/BSOD risk). Gym will not be force-killed mid-generate."
            $lastHandledIma = $imaKey
            $lastRestartAt = Get-Date
            $cudaUnsafe = $true
        }

        $pause = Get-FrontendPause
        $gymBusy = $state -and @(
            'generating', 'evaluating', 'consulting_tutor', 'learning'
        ) -contains [string]$state.status
        if ($pause.paused) {
            Start-Gym
            $wantQwenDown = [bool]$pause.cs2_sleep -or [bool]$pause.stop_qwen
            if ($wantQwenDown -and -not $gymBusy) {
                Stop-Qwen
            } elseif ($wantQwenDown -and $gymBusy) {
                Write-WatchEvent "qwen_stop_deferred" "Qwen stop armed; waiting until gym leaves generate."
            } elseif ($pause.manual_pause -and $gymBusy) {
                Write-WatchEvent "qwen_keep" "Manual gym pause while busy; Qwen stays until the current generate ends."
            }
        } elseif (-not $cudaUnsafe) {
            Start-Qwen
            Start-Gym
        }
        if ([bool]$pause.paused -ne $lastPauseState) {
            $pauseMessage = if ($pause.paused) {
                "Frontend training paused."
            } else {
                "Frontend training resumed."
            }
            Write-WatchEvent "training_pause" $pauseMessage
            $lastPauseState = [bool]$pause.paused
        }

        $beat = [ordered]@{
            at = (Get-Date).ToUniversalTime().ToString("o")
            qwenListening = [bool](((Get-QwenProcess) -or (Get-QwenListenerProcess)) -and (Test-Port 8888))
            paused = [bool]$pause.paused
            manualPause = [bool]$pause.manual_pause
            cs2Sleep = [bool]$pause.cs2_sleep
            gymStatus = if ($state) { $state.status } else { "unknown" }
            attempts = if ($state) { $state.attempts } else { $null }
            infrastructureErrors = if ($state) { $state.infrastructureErrors } else { $null }
        }
        Set-Content -LiteralPath $heartbeat -Value ($beat | ConvertTo-Json -Compress)
        $task = if ($state -and $state.taskId) { $state.taskId } else { "-" }
        $dashPid = $null
        $dashReceipt = Join-Path $runtimeDir "dashboard-runtime.json"
        if (Test-Path -LiteralPath $dashReceipt) {
            try { $dashPid = (Get-Content -LiteralPath $dashReceipt -Raw | ConvertFrom-Json).pid } catch {}
        }
        $dash = if (Test-LoopbackPort 4177) {
            if ($dashPid) { "4177/pid=$dashPid" } else { "4177" }
        } else { "down" }
        $hostLine = "  gym={0,-12} qwen={1} dash={2} pause={3} task={4}" -f `
            $beat.gymStatus, `
            $(if ($beat.qwenListening) { "up" } else { "down" }), `
            $dash, `
            $(if ($beat.paused) { "on" } else { "off" }), `
            $task
        if ($hostLine -ne $lastHostLine) {
            Write-Host $hostLine
            $lastHostLine = $hostLine
            $quietBeats = 0
        } else {
            $quietBeats++
            if ($quietBeats -ge 8) {
                Write-Host $hostLine
                $quietBeats = 0
            }
        }
    } catch {
        Write-WatchEvent "watchdog_error" $_.Exception.Message
    }
    Start-Sleep -Seconds 15
}
