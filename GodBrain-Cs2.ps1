# Shared CS2 gate. Dot-source from Start / Heal / Start-CS2 / Watch-Cs2Pause.
# Start-CS2 pauses and launches only. Explicit desk actions release the hold;
# neither game exit nor a timer may restart models, tasks or Tailscale.

function Test-Cs2Running {
    # Do not use Get-Process here: the PowerShell host can steal focus
    # from exclusive-fullscreen CS2 on each poll.
    $procs = [System.Diagnostics.Process]::GetProcessesByName("cs2")
    return [bool]($procs -and $procs.Length -gt 0)
}

function Get-Cs2PauseStatePath([string]$RepoRoot) {
    return (Join-Path $RepoRoot "logs\cs2-pause.json")
}

function Read-Cs2PauseState([string]$RepoRoot, [switch]$ForShutdown) {
    $path = Get-Cs2PauseStatePath $RepoRoot
    $blank = [ordered]@{
        version    = 2
        paused     = $false
        suspended  = $false
        last_error = $null
        last_seen  = $null
        last_action = "none"
        at         = $null
    }
    if (-not (Test-Path -LiteralPath $path)) { return $blank }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        $obj = $raw | ConvertFrom-Json
        if ($obj.paused -isnot [bool] -or
            ($null -ne $obj.suspended -and $obj.suspended -isnot [bool])) {
            throw "Pause/completion flags must be booleans."
        }
        $blank.paused = $obj.paused
        if ($null -ne $obj.suspended) { $blank.suspended = $obj.suspended }
        $blank.last_error = $obj.last_error
        $blank.last_seen = $obj.last_seen
        $blank.last_action = $obj.last_action
        $blank.at = $obj.at
        return $blank
    } catch {
        if ($ForShutdown) {
            Write-Warning "CS2 pause state is invalid; replacing it with a shutdown hold: $($_.Exception.Message)"
            return $blank
        }
        throw "CS2 pause state is invalid: $($_.Exception.Message)"
    }
}

function Write-Cs2PauseState([string]$RepoRoot, $State) {
    $dir = Join-Path $RepoRoot "logs"
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir | Out-Null
    }
    $path = Get-Cs2PauseStatePath $RepoRoot
    $State.at = (Get-Date).ToUniversalTime().ToString("o")
    $tmp = $path + ".tmp"
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($tmp, ($State | ConvertTo-Json), $utf8)
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Test-GodBrainColiShouldSleep([string]$RepoRoot) {
    if (Test-Cs2Running) { return $true }
    $st = Read-Cs2PauseState $RepoRoot
    return [bool]$st.paused
}

function Get-GodBrainCs2PauseTasks {
    return @("GodBrainWatch", "GodBrainLogon", "GodBrainCs2Pause",
        "GodBrainGymWatch", "GodBrainGymWorker", "GodBrainQwen38", "GodBrainCreationLab")
}

function Test-GodBrainTaskExists([string]$Name) {
    & schtasks.exe /Query /TN $Name 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Set-GodBrainTaskEnabled([string]$Name, [bool]$Enable) {
    if (-not (Test-GodBrainTaskExists $Name)) {
        Write-Host "cs2: task $Name is not installed; skipped"
        return
    }
    $flag = if ($Enable) { "/ENABLE" } else { "/DISABLE" }
    $out = & schtasks.exe /Change /TN $Name $flag 2>&1
    if ($LASTEXITCODE -ne 0) { throw "cs2: task $Name $flag failed: $($out -join ' ')" }
}

function Enable-InstalledGodBrainLogon {
    Set-GodBrainTaskEnabled "GodBrainLogon" $true
}

function Test-Cs2ScriptProcess($Process, [string]$Path, [switch]$PowerShell) {
    $escaped = [regex]::Escape($Path)
    if ($PowerShell) {
        return ($Process.Name -match '^(?:pwsh|powershell)\.exe$' -and
            $Process.CommandLine -match "(?:^|\s)-File\s+(?:`"$escaped`"|$escaped)(?:\s|$)")
    }
    return ($Process.Name -match '^python(?:w)?\.exe$' -and
        $Process.CommandLine -match "(?:^|\s)(?:`"$escaped`"|$escaped)(?:\s|$)")
}

function Test-Cs2ModelProcess($Process, [string]$RepoRoot) {
    if (Test-Cs2ScriptProcess $Process "C:\nvme\Qwen3.8-27B-16gb\tools\serve_openai.py") { return $true }
    $kitPython = "C:\nvme\Qwen3.8-27B-16gb\.venv\Scripts\python.exe"
    if ($Process.Name -match '^python(?:w)?\.exe$' -and
        ($Process.ExecutablePath -eq $kitPython -or
         $Process.CommandLine -match ('^(?:"{0}"|{0})(?:\s|$)' -f [regex]::Escape($kitPython))) -and
        $Process.CommandLine -match '(?:^|\s)(?:"tools\\serve_openai\.py"|tools\\serve_openai\.py)(?:\s|$)') {
        return $true
    }
    if (Test-Cs2ScriptProcess $Process (Join-Path $RepoRoot "scripts\qwen_image_server.py")) { return $true }
    if ($Process.Name -eq "llama-server.exe" -and
        $Process.CommandLine -match '(?:^|\s)--port(?:\s+|=)8000(?:\s|$)') { return $true }
    $coliPaths = @(
        (Join-Path $RepoRoot "LLM\colibri_LLM\c\coli"),
        (Join-Path (Split-Path $RepoRoot -Parent) "colibri\c\coli")
    )
    if ($env:GODBRAIN_COLIBRI_DIR) { $coliPaths += Join-Path $env:GODBRAIN_COLIBRI_DIR "coli" }
    foreach ($path in $coliPaths) {
        foreach ($file in @($path, "$path.exe")) {
            if ((Test-Cs2ScriptProcess $Process $file) -and $Process.CommandLine -match '\sserve(?:\s|$)') {
                return $true
            }
            if ($Process.Name -eq "coli.exe" -and $Process.ExecutablePath -eq $file -and
                $Process.CommandLine -match '\sserve(?:\s|$)') { return $true }
        }
    }
    return $false
}

function Test-Cs2CpuWebProcess($Process) {
    return ($Process -and $Process.Name -match '^python(?:w)?\.exe$' -and
        $Process.CommandLine -match '^\s*(?:"[^"]+"|\S+)\s+(?:-(?:u|B|E|I|s|S)\s+)*-m\s+http\.server(?:\s|$)')
}

function Stop-Cs2OwnedProcess($Process) {
    $current = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f [int]$Process.ProcessId) -ErrorAction Stop
    if (-not $current) { return }
    if ($current.CreationDate -ne $Process.CreationDate -or $current.CommandLine -cne $Process.CommandLine) {
        throw "cs2: pid $($Process.ProcessId) changed identity; left untouched."
    }
    Write-Host ("cs2: stopping {0} pid={1}" -f $current.Name, $current.ProcessId)
    Stop-Process -Id $current.ProcessId -Force -ErrorAction Stop
}

function Stop-Cs2GpuRuntimes([string]$RepoRoot) {
    $launcherPaths = @(
        (Join-Path $RepoRoot "Start-GodBrain.ps1"),
        (Join-Path $RepoRoot "Watch-GodBrain.ps1"),
        (Join-Path $RepoRoot "Heal-GodBrain.ps1"),
        (Join-Path $RepoRoot "Watch-Cs2Pause.ps1"),
        (Join-Path $RepoRoot "scripts\Watch-FrontendGymOvernight.ps1"),
        (Join-Path $RepoRoot "scripts\Invoke-FrontendGymMaintenance.ps1"),
        (Join-Path $RepoRoot "scripts\Start-QwenVL.ps1"),
        (Join-Path $RepoRoot "scripts\Start-QwenImage.ps1"),
        (Join-Path $RepoRoot "scripts\Start-LlamaServer.ps1"),
        "C:\nvme\Qwen3.8-27B-16gb\paper-godbrain\Start-PaperQwen.ps1",
        "C:\nvme\Qwen3.8-27B-16gb\paper-godbrain\Start-Qwen.ps1",
        "C:\nvme\Qwen3.8-27B-16gb\paper-godbrain\Start-UncensoredQwen.ps1"
    )
    $deadline = (Get-Date).AddSeconds(20)
    do {
        $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop)
        foreach ($process in $processes) {
            if ([int]$process.ProcessId -eq $PID) { continue }
            foreach ($path in $launcherPaths) {
                if (Test-Cs2ScriptProcess $process $path -PowerShell) {
                    Stop-Cs2OwnedProcess $process
                    break
                }
            }
        }
        # Repeat both censuses: a stopped maintenance parent can leave a late launcher.
        foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction Stop)) {
            if (Test-Cs2ModelProcess $process $RepoRoot) { Stop-Cs2OwnedProcess $process }
        }
        $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop)
        $remaining = @($processes | Where-Object {
            $candidate = $_
            if (Test-Cs2ModelProcess $candidate $RepoRoot) { return $true }
            if ([int]$candidate.ProcessId -eq $PID) { return $false }
            return @($launcherPaths | Where-Object {
                Test-Cs2ScriptProcess $candidate $_ -PowerShell
            }).Count -gt 0
        })
        $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction Stop |
            Where-Object {
                if ($_.LocalPort -notin @(8888, 8871, 8000)) { return $false }
                if ($_.LocalPort -ne 8000) { return $true }
                $ownerId = $_.OwningProcess
                $owner = $processes | Where-Object ProcessId -eq $ownerId | Select-Object -First 1
                return -not (Test-Cs2CpuWebProcess $owner)
            })
        if ($remaining.Count -eq 0 -and $listeners.Count -eq 0) { return }
        Start-Sleep -Milliseconds 400
    } while ((Get-Date) -lt $deadline)
    throw "cs2: a model process or :8888/:8871/:8000 listener remains. Steam was not launched; unknown listeners are never killed."
}

function Suspend-Cs2GymTraining([string]$RepoRoot) {
    $dir = Join-Path $RepoRoot "godbrain_core\skill_lab\work\gym"
    if (-not (Test-Path -LiteralPath $dir)) { return }
    $path = Join-Path $dir "training-pause.json"
    $control = [ordered]@{ paused = $true; stopQwen = $false; autoplay = $true }
    if (Test-Path -LiteralPath $path) {
        $saved = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        foreach ($property in $saved.PSObject.Properties) { $control[$property.Name] = $property.Value }
    }
    $control.paused = $true
    $control.stopQwen = $false
    $control.updatedAt = (Get-Date).ToUniversalTime().ToString("o")
    $control.reason = "cs2_manual_pause"
    $tmp = "$path.cs2.tmp"
    [System.IO.File]::WriteAllText($tmp, ($control | ConvertTo-Json), (New-Object System.Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Get-TailscaleExe {
    $fixed = "C:\Program Files\Tailscale\tailscale.exe"
    if (Test-Path -LiteralPath $fixed) { return $fixed }
    $cmd = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# Disconnect only. Never logout, --reset, or stop the Windows service.
# Native stderr ("Tailscale was already stopped.") must not abort Start-CS2
# ($ErrorActionPreference Stop): 2>$null is not enough in Windows PowerShell.
function Invoke-TailscaleCs2([string]$Exe, [string[]]$TsArgs) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & $Exe @TsArgs 2>&1
        $code = $LASTEXITCODE
        $text = (($out | ForEach-Object { "$_" }) -join " ").Trim()
        if ($code -eq 0) { return }
        if ($text -match 'already stopped') {
            Write-Host "cs2: tailscale already down"
            return
        }
        if ($text -match 'already running') { return }
        throw ("cs2: tailscale {0} exit={1} {2}" -f ($TsArgs -join " "), $code, $text)
    } finally {
        $ErrorActionPreference = $old
    }
}

function Set-TailscaleForCs2([bool]$Up) {
    $exe = Get-TailscaleExe
    if (-not $exe) { return }
    if ($Up) {
        Write-Host "cs2: tailscale up (existing node, no reset)"
        Invoke-TailscaleCs2 $exe @("up", "--unattended")
    } else {
        $service = Get-Service -Name "Tailscale" -ErrorAction SilentlyContinue
        if ($service -and $service.Status -eq "Stopped") {
            Write-Host "cs2: Tailscale service is already stopped"
            return
        }
        Write-Host "cs2: tailscale down (keep Valve away from the tailnet)"
        Invoke-TailscaleCs2 $exe @("down")
    }
}

function Suspend-GodBrainForCs2([string]$RepoRoot) {
    $state = Read-Cs2PauseState $RepoRoot -ForShutdown
    $state.last_seen = (Get-Date).ToUniversalTime().ToString("o")
    $state.paused = $true
    $state.suspended = $false
    $state.last_error = $null
    $state.last_action = "pause-manual"
    Write-Cs2PauseState $RepoRoot $state
    . (Join-Path $RepoRoot "scripts\GodBrain-Mouth.ps1")
    Set-GodBrainMouthPaused -RepoRoot $RepoRoot -On $true
    $failures = [System.Collections.Generic.List[string]]::new()
    try { Suspend-Cs2GymTraining $RepoRoot } catch { $failures.Add("gym pause: $($_.Exception.Message)") }
    foreach ($name in (Get-GodBrainCs2PauseTasks | Where-Object { $_ -ne "GodBrainCs2Pause" })) {
        try { Set-GodBrainTaskEnabled $name $false } catch { $failures.Add($_.Exception.Message) }
    }
    try { Stop-Cs2GpuRuntimes $RepoRoot } catch { $failures.Add("GPU shutdown: $($_.Exception.Message)") }
    try { Set-TailscaleForCs2 $false } catch { $failures.Add("Tailscale shutdown: $($_.Exception.Message)") }
    if ($failures.Count -eq 0) {
        $state.suspended = $true
        Write-Cs2PauseState $RepoRoot $state
        try { Set-GodBrainTaskEnabled "GodBrainCs2Pause" $false } catch { $failures.Add($_.Exception.Message) }
    }
    if ($failures.Count) {
        $state.suspended = $false
        $state.last_error = $failures -join "; "
        Write-Cs2PauseState $RepoRoot $state
        throw "cs2: suspension incomplete; backup remains retryable: $($state.last_error)"
    }
    Write-Host "cs2: models stopped; gym training and Watch/Logon/CS2 backup held for manual resume; Tailscale down"
}

function Clear-GodBrainCs2Pause([string]$RepoRoot) {
    if (Test-Cs2Running) { throw "CS2 is running. Close the game before starting models or Watch." }
    $state = Read-Cs2PauseState $RepoRoot
    if (-not $state.paused) { return }
    $state.paused = $false
    $state.suspended = $false
    $state.last_error = $null
    $state.last_action = "resume-now"
    Write-Cs2PauseState $RepoRoot $state
}
