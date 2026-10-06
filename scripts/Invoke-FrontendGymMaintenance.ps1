# One bounded gym/Qwen maintenance tick, called only by AFK Watch -WithGym.
[CmdletBinding()]
param([string]$RepoRoot = $PSScriptRoot)
$env:POWERSHELL_TELEMETRY_OPTOUT = '1'
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Resolve-GodBrainRoot.ps1")
. (Join-Path $RepoRoot "GodBrain-Cs2.ps1")

$pwsh = if (Test-Path -LiteralPath "C:\pwsh\pwsh.exe") { "C:\pwsh\pwsh.exe" } else { "pwsh.exe" }
$qwenStart = "C:\nvme\Qwen3.8-27B-16gb\paper-godbrain\Start-Qwen.ps1"
$qwenModel = "C:\nvme\Qwen3.8-27B-16gb\models\Qwen3.8-27B-EXL3-3.5bpw"
$gymDoor = Join-Path $RepoRoot "scripts\Invoke-FrontendGym.ps1"
$gymState = Join-Path $RepoRoot "godbrain_core\skill_lab\work\gym\state.json"
$runtimeDir = Join-Path $RepoRoot "godbrain_core\skill_lab\work\gym\watchdog"
$heartbeat = Join-Path $runtimeDir "heartbeat.json"
$events = Join-Path $runtimeDir "events.jsonl"
$qwenReceipt = Join-Path $runtimeDir "qwen-runtime.json"
$gymErr = Join-Path $runtimeDir "gym.err.log"
$crashLatch = Join-Path $runtimeDir "crash-latch.json"
$crashAlert = Join-Path $RepoRoot "logs\gym-watch-alert.txt"
$gymReceipt = Join-Path $runtimeDir "gym-runtime.json"
if (Test-GodBrainColiShouldSleep $RepoRoot) {
    Write-Host "afk gym: CS2 hold; no model or worker start"
    return
}

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
            throw "training-pause.json unreadable; no model or worker start: $($_.Exception.Message)"
        }
    }
    $cs2Sleep = $false
    try {
        $cs2Sleep = [bool](Test-GodBrainColiShouldSleep -RepoRoot $RepoRoot)
    } catch {
        throw "CS2 gate unreadable; no model or worker start: $($_.Exception.Message)"
    }
    [pscustomobject]@{
        cs2_sleep = $cs2Sleep
        manual_pause = $manualPause
        stop_qwen = $stopQwen
        paused = $manualPause -or $cs2Sleep
    }
}

function Write-WatchBanner {
    Write-Host "GodBrain AFK gym maintenance" -ForegroundColor Cyan
    Write-Host "qwen3.8-27b-exl3-3.5bpw :8888 10k | Creation Lab http://127.0.0.1:4177 | one GPU slot | never kill generate" -ForegroundColor DarkCyan
    Write-Host "One maintenance tick. Pause & Save keeps Qwen warm." -ForegroundColor DarkCyan
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
        (Test-Cs2ModelProcess $process $RepoRoot) -and
        $process.CommandLine -match ('(?:^|\s|")' + [regex]::Escape($qwenModel) + '(?:"|\s|$)')) {
        return $process
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
    if (-not $owned) {
        if (Test-Port 8888) { Write-WatchEvent "qwen_stop_blocked" "Port 8888 is not the identified gym Qwen; left untouched." }
        return
    }
    Stop-Cs2OwnedProcess $owned
    $deadline = (Get-Date).AddSeconds(20)
    while ((Test-Port 8888) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 400
    }
    if (Test-Port 8888) { throw "Qwen release did not free :8888 within twenty seconds." }
    Write-WatchEvent "qwen_stop" "Released identified Qwen pid=$($owned.ProcessId) after gym was idle."
    Remove-Item -LiteralPath $qwenReceipt -Force -ErrorAction SilentlyContinue
}

function Test-QwenStartHeld {
    $pause = Get-FrontendPause
    $afkHold = Join-Path $RepoRoot "logs\afk-pause.txt"
    return $pause.paused -or ((Test-Path -LiteralPath $afkHold) -and
        (Get-Content -LiteralPath $afkHold -Raw -ErrorAction Stop).Trim() -eq "on")
}

function Stop-QwenStartup($Launcher) {
    # Retain the created process handle while resolving venv redirector descendants.
    $null = $Launcher.Handle
    $born = $Launcher.StartTime
    $owned = @{ ([int]$Launcher.Id) = @{ Born = $born; Ended = $null } }
    $snapshot = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    $rootStopped = $false
    $deadline = (Get-Date).AddSeconds(20)
    do {
        do {
            $added = $false
            foreach ($process in $snapshot) {
                $parent = $owned[[int]$process.ParentProcessId]
                if ($parent -and -not $owned.ContainsKey([int]$process.ProcessId) -and
                    $process.CreationDate -ge $parent.Born -and
                    (-not $parent.Ended -or $process.CreationDate -le $parent.Ended)) {
                    $owned[[int]$process.ProcessId] = @{ Born = $process.CreationDate; Ended = $null }
                    $added = $true
                }
            }
        } while ($added)
        if (-not $rootStopped) {
            if (-not $Launcher.HasExited) { $Launcher.Kill() }
            if (-not $Launcher.WaitForExit(5000)) { throw "Qwen startup launcher did not exit." }
            $owned[[int]$Launcher.Id].Ended = Get-Date
            $rootStopped = $true
        } else {
            $models = @($snapshot | Where-Object {
                $identity = $owned[[int]$_.ProcessId]
                $identity -and $_.CreationDate -eq $identity.Born -and
                (Test-Cs2ModelProcess $_ $RepoRoot) -and
                $_.CommandLine -match ('(?:^|\s|")' + [regex]::Escape($qwenModel) + '(?:"|\s|$)')
            })
            if (-not $models.Count) { break }
            foreach ($process in $models) {
                Stop-Cs2OwnedProcess $process
                $owned[[int]$process.ProcessId].Ended = Get-Date
            }
            if ((Get-Date) -ge $deadline) { throw "Qwen startup descendants did not exit." }
            Start-Sleep -Milliseconds 100
        }
        $snapshot = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    } while ($true)
    if (Test-Path -LiteralPath $qwenReceipt) {
        $receipt = Get-Content -LiteralPath $qwenReceipt -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($owned.ContainsKey([int]$receipt.pid)) { Remove-Item -LiteralPath $qwenReceipt -Force }
    }
    Write-WatchEvent "qwen_start_cancelled" "Released only this tick's Qwen launch and descendants."
}

function Start-Qwen {
    if (Test-QwenStartHeld) { return $false }
    if ((Test-Port 8000) -or (Test-Port 8871)) {
        Write-WatchEvent "qwen_blocked" "Another mouth/image door is listening; gym Qwen was not started."
        return $false
    }
    if (Get-QwenProcess) { return $true }
    if (Test-Port 8888) {
        Write-WatchEvent "qwen_keep" "Port 8888 already listening; leaving Qwen alone."
        return $false
    }
    $pending = @(Get-CimInstance Win32_Process -ErrorAction Stop |
        Where-Object {
            (Test-Cs2ModelProcess $_ $RepoRoot) -or
            (Test-Cs2ScriptProcess $_ $qwenStart -PowerShell) -or
            (Test-Cs2ScriptProcess $_ "C:\nvme\Qwen3.8-27B-16gb\paper-godbrain\Start-PaperQwen.ps1" -PowerShell)
        })
    if ($pending.Count -gt 0) {
        Write-WatchEvent "qwen_loading" "An identified model/launcher is already present; no duplicate cold start."
        return $false
    }
    $launcher = Start-Process -FilePath $pwsh `
        -ArgumentList @(
            "-NoLogo", "-NoProfile", "-File", $qwenStart
        ) `
        -WorkingDirectory (Split-Path (Split-Path $qwenStart -Parent) -Parent) `
        -WindowStyle Normal `
        -PassThru
    $script:qwenStartup = $launcher
    try {
        $deadline = (Get-Date).AddMinutes(4)
        $process = $null
        while (-not $process -and (Get-Date) -lt $deadline) {
            if (Test-QwenStartHeld) {
                Stop-QwenStartup $launcher
                return $false
            }
            Start-Sleep -Milliseconds 500
            $process = Get-QwenListenerProcess
            if ($launcher.HasExited -and -not $process) {
                throw "Qwen launcher exited before :8888 became ready."
            }
        }
        if (-not $process) { throw "Qwen did not become ready on :8888 within four minutes." }
        if (Test-QwenStartHeld) {
            Stop-QwenStartup $launcher
            return $false
        }
        Set-QwenReceipt $process
        Write-WatchEvent "qwen_start" "Started qwen3.8-27b-exl3-3.5bpw pid=$($process.ProcessId) with the launcher's default drafting."
        return $true
    } catch {
        $failure = $_
        try { Stop-QwenStartup $launcher }
        catch { throw "Qwen startup failed ($($failure.Exception.Message)); cleanup failed: $($_.Exception.Message)" }
        throw $failure
    }
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
    $nodeExe = (Get-Command node -ErrorAction Stop).Source
    $env:GODBRAIN_GYM_STATE = $gymState
    $js = 'const fs=require("fs");const s=JSON.parse(fs.readFileSync(process.env.GODBRAIN_GYM_STATE,"utf8"));process.stdout.write(JSON.stringify({pid:s.pid||null,status:s.status||null,lastError:s.lastError?String(s.lastError):null,taskId:(s.active&&s.active.taskId)||null,attempts:(s.stats&&s.stats.attempts)||null,infrastructureErrors:(s.stats&&s.stats.infrastructureErrors)||null,updatedAt:s.updatedAt||null}));'
    $json = & $nodeExe -e $js
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
        throw "Gym state could not be read safely; no model or worker start."
    }
    return $json | ConvertFrom-Json -ErrorAction Stop
}

$script:gymLaunch = $null
$script:gymCrashStreak = 0
$script:gymCrashLatched = $false
$script:cudaUnsafe = $false
$script:qwenStartup = $null

function Save-GymCrashLatch {
    @{
        latched = [bool]$script:gymCrashLatched
        streak = [int]$script:gymCrashStreak
        cuda_unsafe = [bool]$script:cudaUnsafe
        at = (Get-Date).ToUniversalTime().ToString("o")
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $crashLatch
}

function Read-GymCrashLatch {
    if (-not (Test-Path -LiteralPath $crashLatch)) { return }
    try {
        $saved = Get-Content -LiteralPath $crashLatch -Raw | ConvertFrom-Json
        $script:gymCrashLatched = [bool]$saved.latched
        $script:gymCrashStreak = [int]$saved.streak
        $script:cudaUnsafe = [bool]$saved.cuda_unsafe
    } catch { throw "Gym crash latch unreadable: $($_.Exception.Message)" }
}

function Get-GymCrashTail {
    if (-not (Test-Path -LiteralPath $gymErr)) { return "" }
    $lines = @(Get-Content -LiteralPath $gymErr -Tail 6 -ErrorAction SilentlyContinue)
    return (($lines -join " ") -replace "\s+", " ").Trim()
}

function Send-GymCrashNotice([string]$message) {
    $dir = Split-Path $crashAlert -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    Set-Content -LiteralPath $crashAlert -Value $message
    $clip = $message
    if ($clip.Length -gt 220) { $clip = $clip.Substring(0, 220) }
    $msg = Join-Path $env:SystemRoot "System32\msg.exe"
    if (Test-Path -LiteralPath $msg) {
        Start-Process -FilePath $msg -ArgumentList @("*", "/TIME:120", $clip) -WindowStyle Hidden | Out-Null
    }
}

function Get-GymWorkerProcess([int]$processId) {
    if ($processId -le 0) { return $null }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$processId" -ErrorAction Stop
    if ($process -and $process.CommandLine -and (
        $process.CommandLine -like "*Invoke-FrontendGym.ps1*" -or
        $process.CommandLine -like "*skill_lab\gym.mjs*" -or
        $process.CommandLine -like "*skill_lab/gym.mjs*")) { return $process }
    return $null
}

function Test-GymProcessAlive([int]$processId) {
    return [bool](Get-GymWorkerProcess $processId)
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
    $glance = Read-GymGlance
    $worker = if ($glance -and $glance.pid) { Get-GymWorkerProcess ([int]$glance.pid) } else { $null }
    if ($worker) {
        if (-not $worker.CreationDate) { throw "Live gym worker creation time is unavailable." }
        if (-not $script:gymLaunch -or [int]$script:gymLaunch.Pid -ne [int]$worker.ProcessId -or
            $script:gymLaunch.At -ne [datetime]$worker.CreationDate) {
            $script:gymLaunch = @{ Pid = [int]$glance.pid; At = [datetime]$worker.CreationDate }
            $script:gymLaunch | ConvertTo-Json -Compress | Set-Content -LiteralPath $gymReceipt
        }
        if (((Get-Date) - $script:gymLaunch.At).TotalSeconds -ge 120) {
            $script:gymCrashStreak = 0
            $script:gymCrashLatched = $false
            Save-GymCrashLatch
        }
        return
    }
    if ($script:gymCrashLatched) { return }
    if ($script:gymLaunch) {
        $ageSeconds = ((Get-Date) - $script:gymLaunch.At).TotalSeconds
        $launchAlive = Test-GymProcessAlive $script:gymLaunch.Pid
        if ($launchAlive) {
            if ($ageSeconds -ge 120) {
                $script:gymCrashStreak = 0
                $script:gymCrashLatched = $false
                Save-GymCrashLatch
            }
            return
        }
        $script:gymCrashStreak++
        $script:gymLaunch = $null
        if (Test-Path -LiteralPath $gymReceipt) { Remove-Item -LiteralPath $gymReceipt -Force }
        $tail = Get-GymCrashTail
        Write-WatchEvent "gym_crash" "Observed gym worker loss; last launch $([int]$ageSeconds)s ago. Streak $($script:gymCrashStreak)/10. $tail"
        Save-GymCrashLatch
        if ($script:gymCrashStreak -ge 10) {
            $script:gymCrashLatched = $true
            Save-GymCrashLatch
            $notice = "GodBrain gym crashed 10 times in a row and will stay down. $tail"
            Write-WatchEvent "gym_crash_stop" $notice
            Send-GymCrashNotice $notice
            $script:gymLaunch = $null
            return
        }
        $script:gymLaunch = $null
    }
    Start-Dashboard
    $started = Start-Process -FilePath $pwsh `
        -ArgumentList @(
            "-NoLogo", "-NoProfile", "-File", $gymDoor,
            "-Continuous", "-NoDashboard",
            "-Endpoint", "http://127.0.0.1:8888/v1",
            "-Model", "qwen3.8-27b-exl3-3.5bpw",
            "-MaxAttempts", "4"
        ) `
        -WorkingDirectory $RepoRoot `
        -WindowStyle Normal `
        -RedirectStandardError $gymErr `
        -PassThru
    $script:gymLaunch = @{ Pid = [int]$started.Id; At = Get-Date }
    $script:gymLaunch | ConvertTo-Json -Compress | Set-Content -LiteralPath $gymReceipt
    Write-WatchEvent "gym_start" "Started the persistent frontend gym worker pid=$($started.Id)."
}

$lastPauseState = $false
$lastHostLine = ""
$quietBeats = 0
Read-GymCrashLatch
if (Test-Path -LiteralPath $gymReceipt) {
    $savedLaunch = Get-Content -LiteralPath $gymReceipt -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $script:gymLaunch = @{ Pid = [int]$savedLaunch.Pid; At = [datetime]$savedLaunch.At }
}
Write-WatchBanner
Write-WatchEvent "afk_gym_tick" "Gym maintenance under the single AFK Watch loop."

try {
    $state = Read-GymGlance

    $imaKey = ""
    if ($state -and $state.lastError -match "illegal memory access|cudaErrorIllegalAddress") {
        $imaKey = "$($state.infrastructureErrors)|$($state.updatedAt)|$($state.lastError)"
    }

    if ($imaKey -and -not $script:cudaUnsafe) {
        Write-WatchEvent "cuda_ima" "CUDA IMA recorded. Not restarting Qwen (TDR/BSOD risk). Gym will not be force-killed mid-generate."
        $script:cudaUnsafe = $true
        Save-GymCrashLatch
    }

    $pause = Get-FrontendPause
    if ($pause.cs2_sleep) {
        Write-WatchEvent "cs2_hold" "CS2 hold appeared during maintenance; no dashboard, model or worker start."
        return
    }
    if ($script:gymCrashLatched -and $state -and $state.pid -and
        (Test-GymProcessAlive ([int]$state.pid))) { Start-Gym }
    $gymBusy = $state -and @(
        'generating', 'evaluating', 'consulting_tutor', 'learning'
    ) -contains [string]$state.status
    if ($pause.paused) {
        Start-Dashboard
        $wantQwenDown = [bool]$pause.cs2_sleep -or [bool]$pause.stop_qwen
        if ($wantQwenDown -and -not $gymBusy) {
            Stop-Qwen
        } elseif ($wantQwenDown -and $gymBusy) {
            Write-WatchEvent "qwen_stop_deferred" "Qwen stop armed; waiting until gym leaves generate."
        } elseif ($pause.manual_pause -and $gymBusy) {
            Write-WatchEvent "qwen_keep" "Manual gym pause while busy; Qwen stays until the current generate ends."
        }
    } elseif (-not $script:cudaUnsafe -and -not $script:gymCrashLatched) {
        if (Start-Qwen) {
            if (Test-QwenStartHeld) {
                if ($script:qwenStartup) { Stop-QwenStartup $script:qwenStartup }
            } else { Start-Gym }
        }
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
        cudaUnsafe = [bool]$script:cudaUnsafe
        crashLatched = [bool]$script:gymCrashLatched
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
    throw
} finally {
    if ($script:qwenStartup) { $script:qwenStartup.Dispose(); $script:qwenStartup = $null }
}
