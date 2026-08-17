# Shared CS2 gate. Dot-source from Start / Heal / Start-CS2 / Watch-Cs2Pause.
# Primary path is Start-CS2.ps1 (pause, then launch, then resume after 5 min).
# Watch-Cs2Pause is the Steam Play-button safety net.

function Test-Cs2Running {
    # Do not use Get-Process here: the PowerShell host can steal focus
    # from exclusive-fullscreen CS2 on each poll.
    $procs = [System.Diagnostics.Process]::GetProcessesByName("cs2")
    return [bool]($procs -and $procs.Length -gt 0)
}

function Get-Cs2PauseStatePath([string]$RepoRoot) {
    return (Join-Path $RepoRoot "logs\cs2-pause.json")
}

function Read-Cs2PauseState([string]$RepoRoot) {
    $path = Get-Cs2PauseStatePath $RepoRoot
    $blank = [ordered]@{
        version    = 1
        paused     = $false
        last_seen  = $null
        last_action = "none"
        at         = $null
    }
    if (-not (Test-Path -LiteralPath $path)) { return $blank }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        $obj = $raw | ConvertFrom-Json
        $blank.paused = [bool]$obj.paused
        $blank.last_seen = $obj.last_seen
        $blank.last_action = $obj.last_action
        $blank.at = $obj.at
        return $blank
    } catch {
        return $blank
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

function Get-Cs2GoneMinutes([string]$RepoRoot) {
    $st = Read-Cs2PauseState $RepoRoot
    if (-not $st.last_seen) { return $null }
    try {
        $seen = [datetime]::Parse(
            [string]$st.last_seen,
            $null,
            [System.Globalization.DateTimeStyles]::RoundtripKind
        )
        if ($seen.Kind -eq [DateTimeKind]::Local) {
            $seen = $seen.ToUniversalTime()
        }
        return [int][math]::Floor(((Get-Date).ToUniversalTime() - $seen).TotalMinutes)
    } catch {
        return $null
    }
}

function Test-GodBrainColiShouldSleep([string]$RepoRoot) {
    if (Test-Cs2Running) { return $true }
    $gone = Get-Cs2GoneMinutes $RepoRoot
    if ($null -eq $gone) { return $false }
    return ($gone -lt 5)
}

function Get-GodBrainCs2PauseTasks {
    return @("GodBrainWatch", "GodBrainLogon")
}

function Test-GodBrainTaskExists([string]$Name) {
    & schtasks.exe /Query /TN $Name 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Set-GodBrainTaskEnabled([string]$Name, [bool]$Enable) {
    if (-not (Test-GodBrainTaskExists $Name)) { return }
    $flag = if ($Enable) { "/ENABLE" } else { "/DISABLE" }
    & schtasks.exe /Change /TN $Name $flag 2>$null | Out-Null
}

function Stop-ColiServe {
    $hits = @(Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'coli["'']? serve' })
    foreach ($p in $hits) {
        Write-Host ("cs2: stopping coli pid={0}" -f $p.ProcessId)
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Stop-LlamaMouth {
    foreach ($p in @(Get-Process -Name "llama-server" -ErrorAction SilentlyContinue)) {
        Write-Host ("cs2: stopping llama-server pid={0}" -f $p.Id)
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
}

function Get-TailscaleExe {
    $fixed = "C:\Program Files\Tailscale\tailscale.exe"
    if (Test-Path -LiteralPath $fixed) { return $fixed }
    $cmd = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# Disconnect only. Never logout, --reset, or stop the Windows service.
function Set-TailscaleForCs2([bool]$Up) {
    $exe = Get-TailscaleExe
    if (-not $exe) { return }
    if ($Up) {
        Write-Host "cs2: tailscale up (existing node, no reset)"
        & $exe up --unattended 2>$null | Out-Null
    } else {
        Write-Host "cs2: tailscale down (keep Valve away from the tailnet)"
        & $exe down 2>$null | Out-Null
    }
}

function Suspend-GodBrainForCs2([string]$RepoRoot) {
    $state = Read-Cs2PauseState $RepoRoot
    $state.last_seen = (Get-Date).ToUniversalTime().ToString("o")
    Stop-ColiServe
    Stop-LlamaMouth
    Set-TailscaleForCs2 $false
    foreach ($name in Get-GodBrainCs2PauseTasks) {
        Set-GodBrainTaskEnabled $name $false
    }
    $state.paused = $true
    $state.last_action = "pause"
    Write-Cs2PauseState $RepoRoot $state
    Write-Host "cs2: GodBrain paused (mouth down, Tailscale down, Watch/Logon disabled)"
}

function Resume-GodBrainAfterCs2([string]$RepoRoot) {
    foreach ($name in Get-GodBrainCs2PauseTasks) {
        Set-GodBrainTaskEnabled $name $true
    }
    Set-TailscaleForCs2 $true
    $state = Read-Cs2PauseState $RepoRoot
    $state.paused = $false
    $state.last_action = "resume"
    Write-Cs2PauseState $RepoRoot $state
    Write-Host "cs2: tasks enabled, Tailscale up, starting GodBrain"
    $starter = Join-Path $RepoRoot "Start-GodBrain.ps1"
    if (Test-Path -LiteralPath $starter) {
        & $starter -RepoRoot $RepoRoot
    }
}
