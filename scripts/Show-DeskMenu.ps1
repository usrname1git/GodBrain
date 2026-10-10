# One window for the doors already on this machine.
# Status: each service has Start and Stop. Rate and GPU are readouts.
# STT/TTS is the CPU voice door on :8001. The 27B vision tower stays off
# unless the model page checkbox is saved and that model is started.
# Model page picks 27B text, 8B vision, Qwen-Image-2.1, or Uncensored. Status starts that pick.
# Clips page runs the deadtime scan. Lyrics starts capture, waits for loopback,
# waits the preroll, then Shift+P into the running ncspot.
# Stop holds kernel and RAG against Watch (logs/*-pause.txt) until Start.
# Tailscale Start reconnects the existing node. Mouth Start does not launch Gemma.
[CmdletBinding()]
param(
    [switch]$Status,
    [switch]$ControlPanelHost,
    [switch]$StatusSnapshot,
    [object]$TokenSample,
    [object]$AskRequest,
    [object]$MonitorRequest
)

$ErrorActionPreference = "Stop"
$Kit = "C:\nvme\Qwen3.8-27B-16gb"
$Start27 = Join-Path $Kit "paper-godbrain\Start-Qwen.ps1"
$StartUncensored = Join-Path $Kit "paper-godbrain\Start-UncensoredQwen.ps1"
$StopModel = Join-Path $Kit "paper-godbrain\Stop-Qwen.ps1"
$Repo = Split-Path $PSScriptRoot -Parent
$StartVl = Join-Path $Repo "scripts\Start-QwenVL.ps1"
$StartImage = Join-Path $Repo "scripts\Start-QwenImage.ps1"
$Lyrics = Join-Path $Repo "scripts\Invoke-LyricsLoop.ps1"
$Pwsh = "C:\pwsh\pwsh.exe"
$cs2Helper = Join-Path $Repo "GodBrain-Cs2.ps1"
if (Test-Path -LiteralPath $cs2Helper) { . $cs2Helper }
$mouthHelper = Join-Path $PSScriptRoot "GodBrain-Mouth.ps1"
if (Test-Path -LiteralPath $mouthHelper) { . $mouthHelper }
. (Join-Path $PSScriptRoot "GodBrain-HostServices.ps1")
. (Join-Path $PSScriptRoot "GodBrain-DeskModel.ps1")
. (Join-Path $PSScriptRoot "GodBrain-DeskMonitor.ps1")
$script:modelPick = "27b"

function Test-Port([int]$Port) {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $ok = $c.ConnectAsync("127.0.0.1", $Port).Wait(300)
        $c.Close()
        return [bool]$ok
    } catch { return $false }
}

$script:tokSample = $TokenSample
function Get-ImageRateLine {
    try { $h = Invoke-RestMethod -TimeoutSec 2 "http://127.0.0.1:8871/health" } catch { return "image status unread" }
    if (-not $h.ready) { return "image loading" }
    $p = $h.progress
    if (-not $p) {
        if ($h.busy) { return "image busy (progress unavailable)" }
        return "image idle"
    }
    $phase = [string]$p.phase
    if ($phase -eq "idle") { return "image idle" }
    $elapsed = "{0:0}s" -f [double]$p.elapsed_seconds
    $rate = ""
    if ([double]$p.steps_per_second -ge 1) {
        $rate = ", {0:0.00} steps/s" -f [double]$p.steps_per_second
    } elseif ([double]$p.seconds_per_step -gt 0) {
        $rate = ", {0:0.0} s/step" -f [double]$p.seconds_per_step
    }
    switch ($phase) {
        "loading" { return "loading, $elapsed" }
        "preparing" { return "preparing, $elapsed" }
        "denoising" { return "$($p.completed_steps)/$($p.total_steps) steps, $elapsed$rate" }
        "decoding" { return "decoding, $elapsed$rate" }
        "saving" { return "saving, $elapsed" }
        "unloading" { return "unloading, $elapsed" }
        "done" { return "done, $elapsed$rate" }
        "failed" { return "image failed, $elapsed" }
        default { return "image progress unread" }
    }
}

function Get-TokLine {
    if ((Test-Port 8871) -and -not (Test-Port 8888)) {
        $script:tokSample = $null
        return Get-ImageRateLine
    }
    if (-not (Test-Port 8888)) { $script:tokSample = $null; return "idle" }
    try { $h = Invoke-RestMethod -TimeoutSec 1 http://127.0.0.1:8888/health } catch { return "unread" }
    $total = [int64]$h.prompt_tokens_total + [int64]$h.completion_tokens_total
    $now = [datetime]::UtcNow
    $text = "idle"
    if ($script:tokSample) {
        $dt = ($now - $script:tokSample.At).TotalSeconds
        $delta = $total - $script:tokSample.Total
        if ($dt -ge 0.8) {
            if ($delta -gt 0) { $text = "{0:N0} T/s" -f ($delta / $dt) }
            elseif ($h.busy) { $text = "busy" }
            else { $text = "idle" }
        } else { $text = [string]$script:tokSample.Text }
    }
    $script:tokSample = @{ At = $now; Total = $total; Text = $text }
    return $text
}

function Update-MicMark {
    if (-not $script:micRail) { return }
    try {
        $st = [MicDesk]::State()
        $script:micHot = ($st[1] -gt 0)
        if ($st[0] -eq 0) {
            $script:micRail.ForeColor = $fieldBg
            $script:micTip.SetToolTip($script:micRail, "No microphone")
        } elseif ($script:micHot) {
            $script:micRail.ForeColor = $teal
            $script:micTip.SetToolTip($script:micRail, "Mic hot. Click to mute.")
        } else {
            $script:micRail.ForeColor = $mute
            $script:micTip.SetToolTip($script:micRail, "Mic muted. Click to open it.")
        }
    } catch {
        $script:micRail.ForeColor = $mute
        $script:micTip.SetToolTip($script:micRail, "Mic unread")
    }
}

function Get-ModelLine {
    if (Test-Port 8871) {
        try {
            $r = Invoke-RestMethod http://127.0.0.1:8871/health -TimeoutSec 2
            $id = Split-Path -Leaf ([string]$r.weights)
            if ([string]::IsNullOrWhiteSpace($id)) { $id = "Qwen-Image-2.1" }
            return "$id  :8871"
        } catch { return "8871 up, health unread" }
    }
    if (-not (Test-Port 8888)) { return "No model: :8888 / :8871 down" }
    try {
        $r = Invoke-RestMethod http://127.0.0.1:8888/v1/models -TimeoutSec 2
        $id = $r.data[0].id
        $n = $r.data[0].max_model_len
        return "$id  ctx=$n"
    } catch { return "8888 up, models unread" }
}

function Get-WhisperLine {
    if (-not (Test-Port 8001)) { return "down" }
    try {
        $health = Invoke-RestMethod http://127.0.0.1:8001/health -TimeoutSec 2
        if ([string]$health.service -ne "voice" -or [string]$health.device -ne "cpu") { return "down (other)" }
        if ($health.components.ocr_cpu.state -eq "unready") {
            return "CPU up :8001 / OCR fail: $($health.components.ocr_cpu.detail)"
        }
        if ([string]$health.ocr -eq "qwen") { return "CPU up :8001 OCR=tower" }
        return "CPU up :8001"
    } catch { return "health unread" }
}

function Get-HttpLine {
    if (-not (Test-Port 8000)) { return "down" }
    $proc = Get-PortListener 8000
    if (-not $proc) { return "down" }
    if ([string]$proc.CommandLine -match 'http\.server') { return "up :8000" }
    $name = [IO.Path]::GetFileName([string]$proc.ExecutablePath)
    if ([string]::IsNullOrWhiteSpace($name)) { return "down (other)" }
    return "down ($name)"
}

function Get-GpuLine {
    try {
        $u = (& nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits).Trim()
        return "GPU $u MiB"
    } catch { return "GPU unread" }
}

function Get-ServiceWord([string]$Name) {
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return "missing" }
    return $svc.Status.ToString().ToLower()
}

function Get-RustDeskLine {
    $word = Get-ServiceWord "RustDesk"
    if ($word -eq "running" -and (Test-Port 21118)) { return "up :21118" }
    if ($word -eq "missing") {
        try {
            if (@(Get-GodBrainRustDeskProcesses).Count -gt 0) { return "GUI only (no service)" }
            if (Get-GodBrainRustDeskExe) { return "service missing" }
        } catch { return "app status unread" }
    }
    return $word
}

function Get-SshLine {
    $word = Get-ServiceWord "sshd"
    if ($word -eq "running" -and (Test-Port 2222)) { return "up :2222" }
    return $word
}

function Get-TailscaleLine {
    $word = Get-ServiceWord "Tailscale"
    if ($word -ne "running") { return $word }
    $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -like "100.*" } |
        Select-Object -First 1
    if ($ip) { return "up $($ip.IPAddress)" }
    return "running, no 100.x"
}

function Invoke-DeskTailscale([string[]]$Arguments) {
    $exe = Get-TailscaleExe
    if (-not $exe) { throw "Tailscale CLI is missing." }
    $info = [Diagnostics.ProcessStartInfo]::new($exe)
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw "Could not start the Tailscale CLI." }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(5000)) {
            $process.Kill()
            $null = $process.WaitForExit(3000)
            throw "Tailscale CLI timed out."
        }
        if (-not $stdout.Wait(1000) -or -not $stderr.Wait(1000)) {
            throw "Tailscale CLI output timed out."
        }
        $output = $stdout.GetAwaiter().GetResult().Trim()
        $errorText = $stderr.GetAwaiter().GetResult().Trim()
        if ($process.ExitCode -ne 0) { throw "Tailscale CLI failed (exit $($process.ExitCode)): $errorText" }
        if ($output.Length -gt 1048576) { throw "Tailscale CLI response exceeds its size limit." }
        return $output
    } finally { $process.Dispose() }
}

function Get-DeskServeMapping($Configuration) {
    if ($null -eq $Configuration) { $Configuration = [pscustomobject]@{} }
    # Parsed JSON primitives are PSObject-wrapped; check their underlying type.
    if ($Configuration.PSObject.BaseObject -isnot [System.Management.Automation.PSCustomObject]) {
        throw "Invalid Tailscale Serve configuration."
    }
    $empty = @($Configuration.PSObject.Properties).Count -eq 0
    if ($null -ne $Configuration.AllowFunnel) {
        if ($Configuration.AllowFunnel.PSObject.BaseObject -isnot [System.Management.Automation.PSCustomObject]) {
            throw "Invalid Tailscale Funnel configuration."
        }
        foreach ($entry in $Configuration.AllowFunnel.PSObject.Properties) {
            if ($entry.Value -isnot [bool] -or $entry.Value) {
                return [pscustomobject]@{ Configured = $false; Empty = $false; Url = ""; Detail = "Funnel enabled or invalid; private Phone Desk required" }
            }
        }
    }
    foreach ($site in @($Configuration.Web.PSObject.Properties)) {
        $https = $Configuration.TCP.'443'.HTTPS
        if ($site.Name -match '^[A-Za-z0-9.-]+:443$' -and
            $https -is [bool] -and $https -and
            $site.Value.Handlers.'/'.Proxy -is [string] -and
            $site.Value.Handlers.'/'.Proxy -ceq "http://127.0.0.1:8085") {
            return [pscustomobject]@{
                Configured = $true; Empty = $false
                Url = "https://$($site.Name -replace ':443$', '')/"
                Detail = "HTTPS :443 -> :8085 (background)"
            }
        }
    }
    return [pscustomobject]@{
        Configured = $false; Empty = $empty; Url = ""
        Detail = $(if ($empty) { "Phone Desk not configured" } else { "Existing Serve mapping is not persistent private Phone Desk" })
    }
}

function Read-DeskServeMapping {
    $output = Invoke-DeskTailscale @("serve", "status", "--json")
    if ([string]::IsNullOrWhiteSpace($output)) { throw "Tailscale Serve response is empty." }
    $configuration = ConvertFrom-Json -InputObject $output -ErrorAction Stop -NoEnumerate
    return Get-DeskServeMapping $configuration
}

function Get-TailscaleServeLine {
    $word = Get-ServiceWord "Tailscale"
    if ($word -ne "running") { return "service $word" }
    try {
        $mapping = Read-DeskServeMapping
        if (-not $mapping.Configured) { return $mapping.Detail }
        $node = Invoke-DeskTailscale @("status", "--json") | ConvertFrom-Json -ErrorAction Stop
        if ($node.BackendState -ne "Running" -or $node.Self.Online -isnot [bool] -or -not $node.Self.Online) {
            return "Configured / tailnet offline"
        }
        if (-not (Test-Port 8085)) { return "HTTPS :443 -> :8085 (backend down)" }
        return $mapping.Detail
    } catch { return "Serve unread: $($_.Exception.Message)" }
}

function Start-DeskPhoneServe {
    $mapping = Read-DeskServeMapping
    if ($mapping.Configured) { return }
    if (-not $mapping.Empty) { throw "$($mapping.Detail). Existing Serve configuration was left unchanged." }
    $null = Invoke-DeskTailscale @("serve", "--bg", "--https=443", "http://127.0.0.1:8085")
    $mapping = Read-DeskServeMapping
    if (-not $mapping.Configured) { throw "Private background Phone Desk Serve did not become configured." }
}

function Get-WatchLine {
    $out = & schtasks.exe /Query /TN GodBrainWatch /FO LIST 2>$null | Out-String
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($out)) { return "missing" }
    if ($out -match "Disabled") { return "disabled" }
    if ($out -match "Running") { return "running" }
    return "enabled"
}

function Set-WatchTask([string]$Action) {
    if ($Action -eq "ENABLE" -and -not (Enable-DeskAfterCs2)) { return }
    $proc = Start-Process -FilePath "$env:SystemRoot\System32\schtasks.exe" -ArgumentList @(
        "/Change", "/TN", "GodBrainWatch", "/$Action"
    ) -WindowStyle Hidden -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        [System.Windows.Forms.MessageBox]::Show("Could not $Action GodBrainWatch (exit $($proc.ExitCode)).")
        Update-Status
        return
    }
    $text = if ($Action -eq "ENABLE") { "off" } else { "on" }
    Set-Content -LiteralPath (Join-Path $Repo "logs\afk-pause.txt") -Value $text
    if ($Action -eq "ENABLE") {
        $run = Start-Process -FilePath "$env:SystemRoot\System32\schtasks.exe" -ArgumentList @(
            "/Run", "/TN", "GodBrainWatch"
        ) -WindowStyle Hidden -Wait -PassThru
        if ($run.ExitCode -ne 0) {
            [System.Windows.Forms.MessageBox]::Show("Watch enabled, but the immediate AFK tick could not start (exit $($run.ExitCode)).")
        }
    }
    Update-Status
}

function Enable-DeskAfterCs2 {
    try {
        Clear-GodBrainCs2Pause $Repo
        Enable-InstalledGodBrainLogon
        return $true
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "CS2")
        return $false
    }
}

function Start-TailscaleDesk {
    Set-HostService "Tailscale" "start"
    if ((Get-ServiceWord "Tailscale") -ne "running") { return }
    try {
        Set-TailscaleForCs2 $true
        Start-DeskPhoneServe
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Tailscale")
    }
    Update-Status
}

function Set-HostService([string]$Name, [string]$Action) {
    $hold = switch ($Name) {
        "Tailscale" { "tailscale" }
        "RustDesk" { "rustdesk" }
        "MongoDB" { "mongo" }
    }
    if ($Name -eq "RustDesk" -and $Action -eq "stop" -and
        -not (Get-Service -Name "RustDesk" -ErrorAction SilentlyContinue)) {
        try {
            Set-DeskPause "rustdesk"
            Stop-GodBrainRustDeskApp
        } catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "RustDesk")
        }
        Update-Status
        return
    }
    $wsudo = "C:\Tools\TeamM2\wsudo.exe"
    if (-not (Test-Path -LiteralPath $wsudo)) {
        [System.Windows.Forms.MessageBox]::Show("Need $wsudo to $Action $Name")
        return
    }
    if ($hold -and $Action -eq "stop") { Set-DeskPause $hold }
    $requested = [DateTimeOffset]::UtcNow
    $arguments = if ($Name -eq "RustDesk" -and $Action -eq "start") {
        $launcher = Join-Path $Repo "scripts\Start-RustDesk.ps1"
        @("-A", "-w", "C:\pwsh\pwsh.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-File", "`"$launcher`"")
    } else {
        @("-A", "-w", "sc.exe", $Action, $Name)
    }
    $proc = Start-Process -FilePath $wsudo -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        $message = "Could not $Action $Name (exit $($proc.ExitCode))."
        if ($Name -eq "RustDesk" -and $Action -eq "start") {
            $receiptPath = Join-Path $Repo "logs\last-rustdesk-start.json"
            try {
                if ((Test-Path -LiteralPath $receiptPath) -and (Get-Item -LiteralPath $receiptPath).Length -le 32768) {
                    $receipt = Get-Content -Raw -LiteralPath $receiptPath | ConvertFrom-Json
                    if ($receipt.status -eq "failed" -and [DateTimeOffset]$receipt.at -ge $requested) {
                        $message += "`n$($receipt.message)"
                    }
                }
            } catch {
                $message += "`nCould not read the RustDesk launch receipt: $($_.Exception.Message)"
            }
        }
        [System.Windows.Forms.MessageBox]::Show($message)
    } elseif ($hold -and $Action -eq "start") {
        Set-Content -LiteralPath (Join-Path $Repo "logs\$hold-pause.txt") -Value "off"
    }
    Update-Status
}

function Test-DeskPause([string]$Name) {
    $path = Join-Path $Repo "logs\$Name-pause.txt"
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    return ((Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue).Trim() -eq "on")
}

function Set-DeskPause([string]$Name) {
    $dir = Join-Path $Repo "logs"
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir | Out-Null
    }
    Set-Content -LiteralPath (Join-Path $dir "$Name-pause.txt") -Value "on" -NoNewline
}

function Confirm-Stop([string]$Text, [string]$Title) {
    $ask = [System.Windows.Forms.MessageBox]::Show(
        $Text, $Title, [System.Windows.Forms.MessageBoxButtons]::YesNo)
    return $ask -eq [System.Windows.Forms.DialogResult]::Yes
}

function Get-PortListener([int]$Port) {
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $conn) { return $null }
    return Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f [int]$conn.OwningProcess) -ErrorAction SilentlyContinue
}

function Stop-OwnedListener([int]$Port, [string]$Needle, [string]$Label) {
    $proc = Get-PortListener $Port
    if (-not $proc) {
        [System.Windows.Forms.MessageBox]::Show("$Label is already down.")
        return $false
    }
    $blob = "{0} {1}" -f $proc.ExecutablePath, $proc.CommandLine
    $underRepo = $blob -like ("*{0}*" -f $Repo)
    if ($blob -notlike ("*{0}*" -f $Needle) -or -not $underRepo) {
        [System.Windows.Forms.MessageBox]::Show(
            "$Label on :$Port is not the GodBrain process. Leaving it alone.`n$($proc.ExecutablePath)")
        return $false
    }
    Stop-Process -Id $proc.ProcessId -Force
    return $true
}

function Stop-GymDashboard {
    $stopped = $false
    $parents = @(Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like "*Invoke-FrontendGym.ps1*" -and $_.CommandLine -like ("*{0}*" -f $Repo) })
    foreach ($parent in $parents) {
        $kids = @(Get-CimInstance Win32_Process -Filter ("ParentProcessId = {0}" -f [int]$parent.ProcessId) -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like "*gym.mjs*" })
        foreach ($kid in $kids) {
            Stop-Process -Id $kid.ProcessId -Force -ErrorAction SilentlyContinue
            $stopped = $true
        }
        Stop-Process -Id $parent.ProcessId -Force -ErrorAction SilentlyContinue
        $stopped = $true
    }
    $listen = Get-PortListener 4177
    if ($listen -and $listen.CommandLine -like "*gym.mjs*" -and $listen.CommandLine -like ("*{0}*" -f $Repo)) {
        Stop-Process -Id $listen.ProcessId -Force -ErrorAction SilentlyContinue
        $stopped = $true
    }
    if (-not $stopped) {
        [System.Windows.Forms.MessageBox]::Show("Gym is already down.")
    }
    Update-Status
}

function Get-Cs2DeskLine {
    if (-not (Get-Command Test-Cs2Running -ErrorAction SilentlyContinue)) { return "unread" }
    if (Test-Cs2Running) { return "running" }
    if (Test-GodBrainColiShouldSleep $Repo) { return "paused (manual resume)" }
    return "idle"
}

function Test-GenerateBusy {
    try {
        if (Test-DeskReviewBusy) { return $true }
        $st = Invoke-RestMethod -TimeoutSec 2 -Uri "http://127.0.0.1:8083/api/status"
        if ($st.generate_busy) { return $true }
        if ($st.coli -and $st.coli.busy) { return $true }
        return $false
    } catch {
        return $null
    }
}

function ConvertTo-LyricSlug([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    $t = $Text.Trim().Replace(" ", "_")
    $t = [regex]::Replace($t, "[^\w\-]+", "_")
    return $t.Trim("_-".ToCharArray())
}

function Get-LyricsStatePath {
    $parts = @()
    foreach ($bit in @($artist.Text, $album.Text, $name.Text)) {
        $s = ConvertTo-LyricSlug $bit
        if ($s) { $parts += $s }
    }
    if ($parts.Count -eq 0) { return $null }
    $dir = "C:\nvme\stt\lyrics"
    foreach ($p in $parts) { $dir = Join-Path $dir $p }
    return (Join-Path $dir "state.json")
}

function Get-DeskStatus {
    $mouth = "mouth pause unread"
    $mf = Join-Path $Repo "logs\mouth-pause.txt"
    if (Test-Path $mf) { $mouth = "mouth pause $((Get-Content $mf -Raw).Trim())" }
    $cs2 = "CS2 $(Get-Cs2DeskLine)"
    $gym = if (Test-Port 4177) { "gym :4177 up" } else { "gym :4177 down" }
    $kernel = if (Test-Port 8083) { "kernel :8083 up" } else { "kernel :8083 down" }
    $rag = if (Test-Port 8084) { "RAG :8084 up" } else { "RAG :8084 down" }
    $mongo = if (Test-Port 27017) { "Mongo :27017 up" } else { "Mongo :27017 down" }
    @(
        (Get-ModelLine)
        ("Whisper {0}" -f (Get-WhisperLine))
        $kernel
        $rag
        $mongo
        $gym
        $cs2
        $mouth
        (Get-GpuLine)
        ("web {0}" -f (Get-HttpLine))
        ("Tailscale {0}" -f (Get-TailscaleLine))
        ("Serve {0}" -f (Get-TailscaleServeLine))
    ) -join "`r`n"
}

function Get-DeskSnapshot {
    $mouth = if (Get-Command Test-GodBrainMouthPaused -ErrorAction SilentlyContinue) {
        if (Test-GodBrainMouthPaused $Repo) { "paused" } else { "open" }
    } else { "unread" }
    $rows = [ordered]@{
        Model = Get-ModelLine
        Tok = Get-TokLine
        Kernel = $(if (Test-Port 8083) { "up" } elseif (Test-DeskPause "kernel") { "paused" } else { "down" })
        Rag = $(if (Test-Port 8084) { "up" } elseif (Test-DeskPause "rag") { "paused" } else { "down" })
        Mongo = $(if (Test-Port 27017) { "up" } else { "down" })
        Gym = $(if (Test-Port 4177) { "up" } else { "down" })
        Cs2 = Get-Cs2DeskLine
        Mouth = $mouth
        Gpu = (Get-GpuLine) -replace "^GPU ", ""
        Rust = Get-RustDeskLine
        Ssh = Get-SshLine
        Tail = Get-TailscaleLine
        Serve = Get-TailscaleServeLine
        Watch = Get-WatchLine
        Web = Get-HttpLine
        Whisper = Get-WhisperLine
    }
    $modelConfig = "Live context/MTP unavailable"
    try {
        if (Test-Port 8888) {
            $health = Invoke-RestMethod "http://127.0.0.1:8888/health" -TimeoutSec 2
            $draft = if ($health.drafting.mode -eq "none") { "off" } else { "$($health.drafting.mode)/$($health.drafting.num_draft_tokens)" }
            $modelConfig = "Live: ctx=$($health.context_length)  KV=$($health.cache_quant)  draft=$draft  vision=$($health.vision)"
        } elseif (Test-Port 8871) { $modelConfig = "Live: image diffusion; no token context/MTP" }
        else { $modelConfig = "Live: text/image model down" }
    } catch { $modelConfig = "Live context/MTP unread: $($_.Exception.Message)" }
    [pscustomobject]@{ Rows = [pscustomobject]$rows; TokenSample = $script:tokSample; ModelConfig = $modelConfig }
}

function Get-DeskJailRoots {
    @(
        $env:USERPROFILE, $env:APPDATA, $env:LOCALAPPDATA, $env:ProgramData,
        ${env:ProgramFiles}, ${env:ProgramFiles(x86)}, "C:\Tools", "C:\Temp\GitHub",
        $Repo
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}
function ConvertTo-DeskAskPath([string]$Path) {
    $p = $Path.Trim().Trim('"', "'")
    if ([string]::IsNullOrWhiteSpace($p)) { return "" }
    if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $Repo $p }
    return [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($p))
}
function Test-DeskGrantedPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $true }
    $full = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path.Trim()))
    foreach ($root in Get-DeskJailRoots) {
        $r = [IO.Path]::GetFullPath($root).TrimEnd("\")
        if ($full.Equals($r, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($full.StartsWith($r + "\", [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}
function Test-DeskPathToken([string]$Text) {
    return $Text -match '(?i)(?:[a-z]:[\\/]|%[A-Za-z0-9_()]+%\\)'
}

function Read-DeskGrantedBytes([string]$Path, [long]$Maximum, [string]$Kind) {
    if (-not ("DeskImagePath" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
public static class DeskImagePath {
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  private static extern uint GetFinalPathNameByHandle(SafeFileHandle handle, StringBuilder path, uint size, uint flags);
  public static string Resolve(SafeFileHandle handle) {
    var path = new StringBuilder(32768);
    uint size = GetFinalPathNameByHandle(handle, path, (uint)path.Capacity, 0);
    if (size == 0 || size >= path.Capacity) throw new Win32Exception(Marshal.GetLastWin32Error());
    string result = path.ToString();
    return result.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase) ? @"\\" + result.Substring(8)
      : result.StartsWith(@"\\?\", StringComparison.Ordinal) ? result.Substring(4) : result;
  }
}
"@
    }
    $stream = [IO.File]::OpenRead($Path)
    try {
        $finalPath = [DeskImagePath]::Resolve($stream.SafeFileHandle)
        if (-not (Test-DeskGrantedPath $finalPath)) { throw "$Kind resolves outside the kernel file jail." }
        if ($stream.Length -lt 1 -or $stream.Length -gt $Maximum) { throw "$Kind input must be between 1 byte and $Maximum bytes." }
        $memory = [IO.MemoryStream]::new()
        try {
            $buffer = [byte[]]::new(81920)
            while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                if ($memory.Length + $read -gt $Maximum) { throw "$Kind input exceeds $Maximum bytes." }
                $memory.Write($buffer, 0, $read)
            }
            return ,$memory.ToArray()
        } finally { $memory.Dispose() }
    } finally { $stream.Dispose() }
}

function Get-DeskImagePayload([string]$Path) {
    return [Convert]::ToBase64String((Read-DeskGrantedBytes $Path 10MB "Image"))
}

function Wait-DeskImageResult([string]$RequestId) {
    $deadline = [datetime]::UtcNow.AddHours(2)
    $failures = 0
    while ([datetime]::UtcNow -lt $deadline) {
        try {
            $job = Invoke-RestMethod "http://127.0.0.1:8871/v1/images/jobs/$RequestId" -TimeoutSec 15
            $failures = 0
        } catch {
            $failures++
            if ($failures -ge 6) {
                throw "Cannot read image request $RequestId after six attempts. It may still be generating; it was not resubmitted. $($_.Exception.Message)"
            }
            Start-Sleep -Seconds 2
            continue
        }
        if ($job.request_id -cne $RequestId) { throw "Image server returned a different request ID." }
        switch ([string]$job.status) {
            "done" {
                if (-not $job.result.path) { throw "Completed image request has no saved path." }
                if ($job.cleanup_error) {
                    $job.result | Add-Member -NotePropertyName cleanup_error -NotePropertyValue $job.cleanup_error -Force
                }
                return $job.result
            }
            "failed" { throw "Image generation failed: $($job.error)" }
            "running" { Start-Sleep -Seconds 2 }
            default { throw "Image server returned an invalid request state." }
        }
    }
    throw "Image request $RequestId exceeded the two-hour wait. It was not cancelled or resubmitted; outputs are saved under C:\nvme\godbrain-sites\qwen-image."
}

function Test-DeskWriteSlash([string]$Text) {
    $trimmed = $Text.Trim()
    if ($trimmed -match '^(?i)/(?:verify|reject)\b') { return $true }
    if ($trimmed -match '^(?i)/yolo\s+(\S+)') {
        return $Matches[1] -notmatch '^(?i)(?:status|\?)$'
    }
    return $false
}

function Test-DeskNeedsCompleteReview([string]$Path, [string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (Test-DeskVisionImage $Path) { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if ((Get-Item -LiteralPath $Path).Length -le 128KB) { return $false }
    return $Text -notmatch '(?i)(?:^|\s)/edit\b|\b(?:fix|patch|rewrite|implement)\b'
}

function Test-DeskVisionImage([string]$Path) {
    return $Path -match '\.(?i:jpg|jpeg|png|webp|gif|bmp)$'
}

function Invoke-DeskVisionAsk([string]$Path, [string]$Text) {
    if (-not (Test-Port 8888)) {
        throw "The vision tower is down. On the model page, check Vision tower for the 27B, then press Status Start."
    }
    $health = Invoke-RestMethod "http://127.0.0.1:8888/health" -TimeoutSec 3
    if (-not $health.vision) {
        throw "The model on :8888 is text-only. Stop it, check Vision tower, and start it again."
    }
    if ($health.busy) { throw "The model is already generating. Wait." }
    $models = Invoke-RestMethod "http://127.0.0.1:8888/v1/models" -TimeoutSec 3
    $model = [string]$models.data[0].id
    if ([string]::IsNullOrWhiteSpace($Text)) { $Text = "Describe this image." }
    $mime = switch ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        ".png" { "image/png" }
        ".webp" { "image/webp" }
        ".gif" { "image/gif" }
        default { "image/jpeg" }
    }
    $encoded = Get-DeskImagePayload $Path
    $body = @{
        model = $model
        temperature = 0
        max_tokens = 2048
        chat_template_kwargs = @{ enable_thinking = $false }
        messages = @(@{
            role = "user"
            content = @(
                @{ type = "text"; text = $Text }
                @{ type = "image_url"; image_url = @{ url = "data:${mime};base64,$encoded" } }
            )
        })
    } | ConvertTo-Json -Depth 8 -Compress
    $res = Invoke-RestMethod "http://127.0.0.1:8888/v1/chat/completions" -Method Post `
        -Body $body -ContentType "application/json; charset=utf-8" -TimeoutSec 180
    $choice = $res.choices[0].message
    $answer = [string]$choice.content
    if ([string]::IsNullOrWhiteSpace($answer)) { $answer = [string]$choice.reasoning_content }
    if ([string]::IsNullOrWhiteSpace($answer)) { throw "The vision tower returned no text." }
    return $answer.Trim()
}

function Invoke-DeskAsk($Request) {
    $text = [string]$Request.Message
    $yoloOrJudge = $text.Trim() -match '^(?i)/(?:yolo|verify|reject)\b'
    $path = ConvertTo-DeskAskPath ([string]$Request.Path)
    if ($path -and -not (Test-DeskGrantedPath $path)) { throw "That path is outside the kernel file jail ($path)." }
    if (-not $yoloOrJudge -and $path -and -not $Request.ImageModel -and -not (Test-Port 8871) -and (Test-DeskVisionImage $path)) {
        return (Invoke-DeskVisionAsk $path $text)
    }
    $completeReview = -not $yoloOrJudge -and -not $Request.ImageModel -and (
        [bool]$Request.ReviewFile -or (Test-DeskNeedsCompleteReview $path $text))
    if ($completeReview -and ($Request.ImageModel -or (Test-Port 8871))) {
        throw "Complete-source review requires a text model, not image diffusion."
    }
    if ($Request.ImageModel -or (Test-Port 8871)) {
        if ([string]::IsNullOrWhiteSpace($text)) { throw "Enter an image generation or edit prompt." }
        if (-not (Test-Port 8871)) { throw "Qwen-Image-2.1 is down on :8871. Start it from Status Model first." }
        if (Test-Port 8888) { throw "Both image and text models are listening. Stop the other model first (one GPU slot)." }
        $health = Invoke-RestMethod "http://127.0.0.1:8871/health" -TimeoutSec 3
        if (-not $health.ready) { throw "Qwen-Image-2.1 is not ready." }
        if ($health.busy) { throw "Qwen-Image-2.1 is already generating. Wait." }
        $requestId = [guid]::NewGuid().ToString("N")
        $payload = @{ prompt = $text; async = $true; request_id = $requestId }
        if ($path) { $payload.image_base64 = Get-DeskImagePayload $path }
        $body = $payload | ConvertTo-Json -Compress
        try {
            $res = Invoke-RestMethod "http://127.0.0.1:8871/v1/images/generations" -Method Post `
                -Body $body -ContentType "application/json; charset=utf-8" -TimeoutSec 15
        } catch {
            $submissionError = $_.Exception.Message
            try { $accepted = Invoke-RestMethod "http://127.0.0.1:8871/v1/images/jobs/$requestId" -TimeoutSec 15 }
            catch { throw "Image submission failed; it was not retried. $submissionError" }
            if ($accepted.request_id -cne $requestId) { throw "Image submission returned a different request ID." }
            $res = @{ request_id = $requestId; status = "running" }
        }
        if ($res.error) { throw ([string]$res.error) }
        if ($res.request_id) {
            if ($res.request_id -cne $requestId) { throw "Image submission returned a different request ID." }
            $res = Wait-DeskImageResult $requestId
        }
        if (-not $res.path) { throw "Image server returned no saved image path." }
        $answer = "Image saved:`r`n$($res.path)`r`n$($res.width)x$($res.height), $($res.steps) steps, seed $($res.seed)"
        if ($res.cleanup_error) { $answer += "`r`nWarning: model memory cleanup failed: $($res.cleanup_error)" }
        return $answer
    }
    if (-not $yoloOrJudge) {
        $busy = Test-GenerateBusy
        if ($null -eq $busy) { throw "Kernel status is down, so Ask cannot tell if the GPU slot is free." }
        if ($busy) { throw "A generate is already running (one GPU slot). Wait." }
    }
    if ($completeReview) { return (Invoke-DeskCodeReview $path $text) }
    $writeSlash = Test-DeskWriteSlash $text
    if ($yoloOrJudge) {
        $text = $text.Trim()
    } elseif ($path) {
        if ([string]::IsNullOrWhiteSpace($text)) { $text = "Read this path and say what the file or folder is." }
        $text = "Path: $path`n`n$text"
    } elseif (-not (Test-DeskPathToken $text)) {
        if ($text -notmatch '^(?i)no tools\b') { $text = "No tools. `n" + $text }
    }
    $body = @{ message = $text } | ConvertTo-Json -Compress
    $chat = @{
        Uri = "http://127.0.0.1:8083/api/chat"
        Method = "Post"
        Body = $body
        ContentType = "application/json; charset=utf-8"
        TimeoutSec = 180
    }
    if ($writeSlash -and -not [string]::IsNullOrWhiteSpace($env:GODBRAIN_API_TOKEN)) {
        $chat.Headers = @{ Authorization = "Bearer " + $env:GODBRAIN_API_TOKEN }
    }
    $res = Invoke-RestMethod @chat
    if ($res.response) { return [string]$res.response }
    if ($res.error) { throw ([string]$res.error) }
    throw "Kernel returned no chat response."
}

if ($MonitorRequest) {
    Invoke-DeskMonitor -Control $MonitorRequest.Control -Value $MonitorRequest.Value -RepoRoot $Repo
    return
}

if ($AskRequest) {
    Invoke-DeskAsk $AskRequest
    return
}

if ($StatusSnapshot) {
    Get-DeskSnapshot
    return
}

if ($Status) {
    Write-Output (Get-DeskStatus)
    exit 0
}

if (-not $ControlPanelHost) {
    Start-Process -FilePath $Pwsh -ArgumentList @(
        "-NoProfile", "-Sta", "-File", $PSCommandPath, "-ControlPanelHost"
    ) -WindowStyle Hidden | Out-Null
    return
}

if ([Threading.Thread]::CurrentThread.ApartmentState -ne "STA") {
    throw "The Desk control-panel host requires an STA PowerShell process."
}

if (-not ("NcIn" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class NcIn {
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool FreeConsole();
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AttachConsole(uint pid);
  [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool WriteConsoleInput(IntPtr h, INPUT_RECORD[] r, uint n, out uint written);
  [StructLayout(LayoutKind.Explicit, Size=20)]
  public struct INPUT_RECORD {
    [FieldOffset(0)] public ushort EventType;
    [FieldOffset(4)] public uint KeyDown;
    [FieldOffset(8)] public ushort Repeat;
    [FieldOffset(10)] public ushort Vk;
    [FieldOffset(12)] public ushort Scan;
    [FieldOffset(14)] public ushort Char;
    [FieldOffset(16)] public uint Control;
  }
  public static bool ShiftP(uint pid) {
    FreeConsole();
    if (!AttachConsole(pid)) return false;
    var h = GetStdHandle(-10);
    var rec = new INPUT_RECORD[2];
    rec[0].EventType = 1; rec[0].KeyDown = 1; rec[0].Repeat = 1; rec[0].Vk = 0x50; rec[0].Char = 80; rec[0].Control = 0x10;
    rec[1].EventType = 1; rec[1].KeyDown = 0; rec[1].Repeat = 1; rec[1].Vk = 0x50; rec[1].Char = 80; rec[1].Control = 0x10;
    uint w;
    bool ok = WriteConsoleInput(h, rec, 2, out w);
    FreeConsole();
    return ok && w == 2;
  }
}
"@
}

function Start-Door([string]$File, [string[]]$Options = @()) {
    Start-Process -FilePath $Pwsh -ArgumentList (@("-NoProfile", "-File", ('"' + $File + '"')) + $Options) -WindowStyle Normal | Out-Null
}

function Stop-Door {
    $busy = Test-GenerateBusy
    if ($busy) {
        $ask = [System.Windows.Forms.MessageBox]::Show(
            "A generate is in flight on this GPU slot. Stop the model anyway?",
            "Stop",
            [System.Windows.Forms.MessageBoxButtons]::YesNo)
        if ($ask -ne [System.Windows.Forms.DialogResult]::Yes) { return $false }
    }
    & $Pwsh -NoProfile -File $StopModel
    $image = Get-PortListener 8871
    if ($image -and $image.CommandLine -like "*qwen_image_server.py*" -and $image.CommandLine -like "*$Repo*") {
        $parentId = [int]$image.ParentProcessId
        Stop-Process -Id $image.ProcessId -Force -ErrorAction SilentlyContinue
        $parent = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $parentId) -ErrorAction SilentlyContinue
        if ($parent -and $parent.CommandLine -like "*Start-QwenImage.ps1*") {
            Stop-Process -Id $parent.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    return $true
}

function Test-GymStarting {
    $hits = Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like "*Invoke-FrontendGym.ps1*" }
    return [bool]$hits
}

function Start-GymDashboard {
    if (-not (Enable-DeskAfterCs2)) { return }
    $gym = Join-Path $Repo "scripts\Invoke-FrontendGym.ps1"
    if (-not (Test-Path -LiteralPath $gym)) {
        [System.Windows.Forms.MessageBox]::Show("Missing $gym")
        return
    }
    if (Test-Port 4177) {
        Start-Process "http://127.0.0.1:4177/"
        return
    }
    if (Test-GymStarting) {
        [System.Windows.Forms.MessageBox]::Show("Gym is already starting. The dashboard comes up on :4177.")
        return
    }
    if (Test-GenerateBusy) {
        [System.Windows.Forms.MessageBox]::Show("A generate is already running. Wait, then start the gym.")
        return
    }
    $modelId = ""
    try { $modelId = [string](Invoke-RestMethod http://127.0.0.1:8888/v1/models -TimeoutSec 2).data[0].id } catch {}
    if ($modelId -eq "qwen3-vl-8b-exl3") {
        $ask = [System.Windows.Forms.MessageBox]::Show(
            "8B vision is on :8888. The gym uses that one slot. Start anyway?",
            "Start gym",
            [System.Windows.Forms.MessageBoxButtons]::YesNo)
        if ($ask -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }
    Start-Process -FilePath $Pwsh -ArgumentList @(
        "-NoProfile", "-File", $gym, "-Continuous", "-RepoRoot", $Repo
    ) -WindowStyle Normal | Out-Null
    $note = "Gym window started. Dashboard: http://127.0.0.1:4177/"
    if (-not (Test-Port 8888)) {
        $note += "`n:8888 is down. Start 27B text and the gym will use it."
    }
    [System.Windows.Forms.MessageBox]::Show($note, "Start gym")
}

function Start-ClipScan {
    $scan = Join-Path $Repo "scripts\Scan-Cs2Deadtime.ps1"
    if (-not (Test-Path -LiteralPath $scan)) {
        [System.Windows.Forms.MessageBox]::Show("Missing $scan")
        return
    }
    $already = Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like "*Scan-Cs2Deadtime.ps1*" }
    if ($already) {
        [System.Windows.Forms.MessageBox]::Show("A clip scan is already running.")
        return
    }
    $modelId = ""
    try { $modelId = [string](Invoke-RestMethod http://127.0.0.1:8888/v1/models -TimeoutSec 2).data[0].id } catch {}
    if ($modelId -ne "qwen3-vl-8b-exl3") {
        $ask = [System.Windows.Forms.MessageBox]::Show(
            "8B vision is not the model on :8888. Stop that model and start Qwen-VL, then scan new clips?",
            "Scan clips",
            [System.Windows.Forms.MessageBoxButtons]::YesNo)
        if ($ask -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        if (-not (Stop-Door)) { return }
        Start-Door $StartVl
    }
    Start-Process -FilePath $Pwsh -ArgumentList @(
        "-NoProfile", "-File", $scan, "-Limit", "0", "-NativeVideo"
    ) -WorkingDirectory $Repo -WindowStyle Normal | Out-Null
    [System.Windows.Forms.MessageBox]::Show(
        "Scanning new clips only. Files already in the deadtime index are skipped. Qwen-VL has to stay on :8888.",
        "Scan clips")
}

function Start-HiddenPwsh([string[]]$ArgumentList) {
    $hidden = Join-Path $Repo "godbrain_core\cpp_tools\run_hidden.exe"
    if (Test-Path -LiteralPath $hidden) {
        Start-Process -FilePath $hidden -ArgumentList (@($Pwsh) + $ArgumentList) -WindowStyle Hidden | Out-Null
        return
    }
    Start-Process -FilePath $Pwsh -ArgumentList $ArgumentList -WindowStyle Hidden | Out-Null
}

function Start-DeskListener([string]$Only) {
    $starter = Join-Path $Repo "Start-GodBrain.ps1"
    if (-not (Test-Path -LiteralPath $starter)) {
        [System.Windows.Forms.MessageBox]::Show("Missing $starter")
        return
    }
    Start-HiddenPwsh @(
        "-NoProfile", "-File", $starter,
        "-RepoRoot", $Repo, "-Only", $Only, "-MongoWaitSeconds", "5"
    )
}

function Get-ModelPickFile {
    switch ($script:modelPick) {
        "vl" { return $StartVl }
        "image" { return $StartImage }
        "uncensored" { return $StartUncensored }
        default { return $Start27 }
    }
}

function Stop-ActiveModel {
    if (Test-Port 8871) {
        Stop-ImageDoor
        return
    }
    if (-not (Test-Port 8888)) {
        [System.Windows.Forms.MessageBox]::Show("The model on :8888 is already down.")
        return
    }
    $busy = Test-GenerateBusy
    $ask = if ($busy) {
        "A generate is in flight on this GPU slot. Stop the model on :8888 anyway?"
    } else {
        "Stop the model on :8888?"
    }
    if (-not (Confirm-Stop $ask "Model")) { return }
    & $Pwsh -NoProfile -File $StopModel
    Update-Status
}

function Start-ImageDoor {
    if (Test-Port 8871) {
        [System.Windows.Forms.MessageBox]::Show("Qwen-Image-2.1 is already up on :8871.")
        return
    }
    if (Test-Port 8000) {
        $holder = Get-PortListener 8000
        $blob = if ($holder) { [string]$holder.CommandLine } else { "" }
        if ($blob -notmatch 'http\.server') {
            [System.Windows.Forms.MessageBox]::Show(":8000 is in use. Qwen-Image-2.1 stays down until that listener is gone. One GPU slot.")
            return
        }
    }
    if (Test-Port 8888) {
        if (-not (Confirm-Stop "Stop the model on :8888 so Qwen-Image-2.1 can take the GPU slot?" "Model")) { return }
        & $Pwsh -NoProfile -File $StopModel
        $deadline = (Get-Date).AddSeconds(20)
        while ((Test-Port 8888) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 400 }
        if (Test-Port 8888) {
            [System.Windows.Forms.MessageBox]::Show(":8888 is still up. Qwen-Image-2.1 was not started.")
            Update-Status
            return
        }
    }
    Start-Door $StartImage
    Update-Status
}

function Stop-ImageDoor {
    $image = Get-PortListener 8871
    if (-not $image) {
        [System.Windows.Forms.MessageBox]::Show("Qwen-Image-2.1 is already down.")
        return
    }
    $blob = "{0} {1}" -f $image.ExecutablePath, $image.CommandLine
    if ($blob -notlike "*qwen_image_server.py*" -or $blob -notlike "*$Repo*") {
        [System.Windows.Forms.MessageBox]::Show("Something else is on :8871. Leaving it alone.`n$($image.ExecutablePath)")
        return
    }
    if (-not (Confirm-Stop "Stop Qwen-Image-2.1 on :8871?" "Model")) { return }
    $parentId = [int]$image.ParentProcessId
    Stop-Process -Id $image.ProcessId -Force -ErrorAction SilentlyContinue
    $parent = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $parentId) -ErrorAction SilentlyContinue
    if ($parent -and $parent.CommandLine -like "*Start-QwenImage.ps1*") {
        Stop-Process -Id $parent.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Update-Status
}

function Start-SelectedModel {
    if ($script:modelPick -eq "image") {
        if (-not (Enable-DeskAfterCs2)) { return }
        Start-ImageDoor
        return
    }
    try {
        Save-DeskModelControls
        $options = Get-DeskModelLaunchOptions $script:modelPick $script:modelProfiles[$script:modelPick]
        Test-DeskModelLauncher (Get-ModelPickFile) $options
        $profile = $script:modelProfiles[$script:modelPick]
        $context = [int]$profile.Context
        if ($script:modelPick -eq "27b" -and $profile.Vision) {
            if (-not (Confirm-Stop "Load the 27B vision tower on this start? It uses about 0.3 GB plus image prefill on the same GPU. The speech door still does OCR on the CPU when the tower is off or this box is unchecked." "Vision tower")) { return }
        }
        if (($script:modelPick -eq "27b" -and
            ($context -gt 40960 -or ($context -gt 10240 -and $profile.CacheQuant -ne "4"))) -or
            ($script:modelPick -eq "uncensored" -and ($context -gt 10240 -or $profile.Mtp))) {
            if (-not (Confirm-Stop "Restart with ctx=$($profile.Context), KV=$($profile.CacheQuant), MTP=$($profile.Mtp), GPU budget=$($profile.Budget) GiB? Large-context fit depends on all these settings; an out-of-memory failure is possible even after another configuration passed. Stop the current model and apply this profile?" "Large context restart")) { return }
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Model was not stopped: $($_.Exception.Message)")
        return
    }
    if (-not (Enable-DeskAfterCs2)) { return }
    if (-not (Stop-Door)) { return }
    Start-Door (Get-ModelPickFile) $options
    Update-Status
}

function Start-VoiceDoor {
    $line = Get-WhisperLine
    if ($line -like "CPU up*") {
        [System.Windows.Forms.MessageBox]::Show("STT/TTS is already up on :8001.")
        return
    }
    if (Test-Port 8001) {
        [System.Windows.Forms.MessageBox]::Show("Port 8001 is held by $line. STT/TTS stays down.")
        return
    }
    $py = (Get-Command python, python.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    $script = Join-Path $Repo "scripts\voice_door.py"
    if (-not $py -or -not (Test-Path -LiteralPath $script)) {
        [System.Windows.Forms.MessageBox]::Show("python or scripts\voice_door.py is missing.")
        return
    }
    $info = [Diagnostics.ProcessStartInfo]::new($py)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.WorkingDirectory = $Repo
    foreach ($value in @($script, "--port", "8001", "--repo", $Repo)) {
        $info.ArgumentList.Add($value)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw "The speech process did not start." }
    } catch {
        [System.Windows.Forms.MessageBox]::Show("STT/TTS could not start: $($_.Exception.Message)")
        return
    } finally { $process.Dispose() }
    Update-Status
}

function Stop-VoiceDoor {
    $proc = Get-PortListener 8001
    if (-not $proc -or [string]$proc.CommandLine -notlike "*voice_door.py*") {
        [System.Windows.Forms.MessageBox]::Show("STT/TTS is already down.")
        return
    }
    if (-not (Confirm-Stop "Stop STT/TTS on :8001? Whisper and Piper unload. The model on :8888 stays up." "STT/TTS")) { return }
    Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
    Update-Status
}

function Start-WebDoor {
    if ((Get-HttpLine) -eq "up :8000") {
        [System.Windows.Forms.MessageBox]::Show("Web is already up on :8000.")
        return
    }
    if (Test-Port 8000) {
        [System.Windows.Forms.MessageBox]::Show("Port 8000 is held by $(Get-HttpLine). Web stays down.")
        return
    }
    $py = (Get-Command python, python.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $py) {
        [System.Windows.Forms.MessageBox]::Show("python is not on PATH.")
        return
    }
    $hidden = Join-Path $Repo "godbrain_core\cpp_tools\run_hidden.exe"
    $arg = @("-m", "http.server", "8000", "--bind", "127.0.0.1")
    if (Test-Path -LiteralPath $hidden) {
        Start-Process -FilePath $hidden -ArgumentList (@($py) + $arg) -WorkingDirectory $Repo -WindowStyle Hidden | Out-Null
    } else {
        Start-Process -FilePath $py -ArgumentList $arg -WorkingDirectory $Repo -WindowStyle Hidden | Out-Null
    }
    Update-Status
}

function Stop-WebDoor {
    $proc = Get-PortListener 8000
    if (-not $proc -or [string]$proc.CommandLine -notmatch 'http\.server') {
        [System.Windows.Forms.MessageBox]::Show("Web is already down.")
        return
    }
    if (-not (Confirm-Stop "Stop python http.server on :8000?" "Web")) { return }
    Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
    Update-Status
}

function Start-Cs2Desk {
    $file = Join-Path $Repo "Start-CS2.ps1"
    if (-not (Test-Path -LiteralPath $file)) {
        [System.Windows.Forms.MessageBox]::Show("Missing $file")
        return
    }
    if (-not (Confirm-Stop "Start CS2? Stops EXL3/image/legacy models, pauses gym training and disables Watch/Logon/CS2 backup. Tailscale disconnects (service stays running). Nothing restarts after the game; use the desk controls." "CS2")) { return }
    Start-Process -FilePath $Pwsh -ArgumentList @("-NoProfile", "-File", $file, "-RepoRoot", $Repo) -WindowStyle Normal | Out-Null
}

function Stop-Cs2Desk {
    if (-not (Confirm-Stop "Stop CS2? The game closes." "CS2")) { return }
    $procs = [System.Diagnostics.Process]::GetProcessesByName("cs2")
    if (-not $procs -or $procs.Length -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("CS2 is already down.")
        return
    }
    foreach ($p in $procs) {
        try { $p.Kill() } catch {}
        $p.Dispose()
    }
    Update-Status
}

function Stop-MouthHold {
    if (-not (Confirm-Stop "Pause the mouth? Gemma stays off. The model on :8888 keeps running." "Mouth")) { return }
    if (Get-Command Set-GodBrainMouthPaused -ErrorAction SilentlyContinue) {
        Set-GodBrainMouthPaused -RepoRoot $Repo -On $true
    } else {
        Set-DeskPause "mouth"
    }
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='llama-server.exe'" -ErrorAction Stop)) {
        if ($process.Name -eq "llama-server.exe" -and
            $process.CommandLine -match '(?:^|\s)--port(?:\s+|=)8000(?:\s|$)') {
            Stop-Cs2OwnedProcess $process
        }
    }
    Update-Status
}

function Start-MouthHold {
    [System.Windows.Forms.MessageBox]::Show(
        "The desk mouth is the model on :8888. Gemma stays off on this machine, so this does not start llama-server. Use Model start for the selected model.",
        "Mouth")
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies @(
    [Windows.Forms.NativeWindow].Assembly.Location,
    [Windows.Forms.Message].Assembly.Location,
    (Join-Path $PSHOME "System.Runtime.dll")
) -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public sealed class DeskMonitorHotkey : NativeWindow, IDisposable {
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint key);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool UnregisterHotKey(IntPtr window, int id);
    readonly uint key;
    bool disposed;
    public bool Registered { get; private set; }
    public int RegistrationError { get; private set; }
    public event EventHandler Pressed;
    public DeskMonitorHotkey(uint key) {
        this.key = key;
        CreateHandle(new CreateParams {
            Caption = "GodBrain Monitor Hotkey", Parent = new IntPtr(-3)
        });
    }
    public bool Register() {
        if (disposed) throw new ObjectDisposedException("DeskMonitorHotkey");
        if (Registered) return true;
        Registered = RegisterHotKey(Handle, 1, 0x4000, key); // MOD_NOREPEAT
        RegistrationError = Registered ? 0 : Marshal.GetLastWin32Error();
        return Registered;
    }
    protected override void WndProc(ref Message message) {
        if (Registered && message.Msg == 0x312 && message.WParam.ToInt64() == 1)
            Pressed?.Invoke(this, EventArgs.Empty);
        base.WndProc(ref message);
    }
    public void Dispose() {
        if (disposed) return;
        disposed = true;
        try {
            if (Registered && !UnregisterHotKey(Handle, 1))
                throw new InvalidOperationException("Release monitor hotkey failed (Windows error " +
                    Marshal.GetLastWin32Error() + ")");
        } finally {
            Registered = false;
            DestroyHandle();
        }
    }
}
"@
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
[Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IAudioEndpointVolume {
    int RegisterControlChangeNotify(IntPtr pNotify);
    int UnregisterControlChangeNotify(IntPtr pNotify);
    int GetChannelCount(out int pnChannelCount);
    int SetMasterVolumeLevel(float fLevelDB, ref Guid ctx);
    int SetMasterVolumeLevelScalar(float fLevel, ref Guid ctx);
    int GetMasterVolumeLevel(out float pfLevelDB);
    int GetMasterVolumeLevelScalar(out float pfLevel);
    int SetChannelVolumeLevel(uint nChannel, float fLevelDB, ref Guid ctx);
    int SetChannelVolumeLevelScalar(uint nChannel, float fLevel, ref Guid ctx);
    int GetChannelVolumeLevel(uint nChannel, out float pfLevelDB);
    int GetChannelVolumeLevelScalar(uint nChannel, out float pfLevel);
    int SetMute([MarshalAs(UnmanagedType.Bool)] bool bMute, ref Guid ctx);
    int GetMute([MarshalAs(UnmanagedType.Bool)] out bool pbMute);
}
[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDevice {
    int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
    int OpenPropertyStore(int stgmAccess, out IntPtr ppProperties);
    int GetId([MarshalAs(UnmanagedType.LPWStr)] out string ppstrId);
    int GetState(out int pdwState);
}
[Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDeviceCollection {
    int GetCount(out int pcDevices);
    int Item(int nDevice, out IMMDevice ppDevice);
}
[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDeviceEnumerator {
    int EnumAudioEndpoints(int dataFlow, int dwStateMask, out IMMDeviceCollection ppDevices);
    int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice ppEndpoint);
}
public static class MicDesk {
    static Guid Ctx = Guid.Empty;
    static IMMDeviceEnumerator En() {
        var t = Type.GetTypeFromCLSID(new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E"));
        return (IMMDeviceEnumerator)Activator.CreateInstance(t);
    }
    static IAudioEndpointVolume Vol(IMMDevice dev) {
        var iid = new Guid("5CDF2C82-841E-4546-9722-0CF74078229A");
        object obj;
        dev.Activate(ref iid, 23, IntPtr.Zero, out obj);
        return (IAudioEndpointVolume)obj;
    }
    public static int[] State() {
        IMMDeviceCollection col;
        En().EnumAudioEndpoints(1, 1, out col);
        int count; col.GetCount(out count);
        int hot = 0, muted = 0;
        for (int i = 0; i < count; i++) {
            IMMDevice dev; col.Item(i, out dev);
            bool mute; Vol(dev).GetMute(out mute);
            if (mute) muted++; else hot++;
        }
        return new int[] { count, hot, muted };
    }
    public static void SetAll(bool mute) {
        IMMDeviceCollection col;
        En().EnumAudioEndpoints(1, 1, out col);
        int count; col.GetCount(out count);
        for (int i = 0; i < count; i++) {
            IMMDevice dev; col.Item(i, out dev);
            Vol(dev).SetMute(mute, ref Ctx);
        }
    }
    public static void UnmuteDefault() {
        IMMDevice dev;
        En().GetDefaultAudioEndpoint(1, 1, out dev);
        Vol(dev).SetMute(false, ref Ctx);
    }
}
"@

# Uncle Sam, same palette as ncspot and the terminal: navy field, old-glory red, steel text.
$bg = [System.Drawing.Color]::FromArgb(10, 17, 28)
$card = [System.Drawing.Color]::FromArgb(18, 32, 51)
$ink = [System.Drawing.Color]::FromArgb(244, 246, 248)
$mute = [System.Drawing.Color]::FromArgb(143, 164, 196)
$teal = [System.Drawing.Color]::FromArgb(191, 10, 48)
$fieldBg = [System.Drawing.Color]::FromArgb(7, 13, 22)
$pill = [System.Drawing.Color]::FromArgb(191, 10, 48)

function New-GodBrainIcon {
    $bmp = New-Object System.Drawing.Bitmap 64, 64
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    $edge = [System.Drawing.Color]::FromArgb(255, 10, 17, 28)
    $crossBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 244, 246, 248))
    $crossPen = New-Object System.Drawing.Pen $edge, 2
    $g.FillRectangle($crossBrush, 26, 2, 12, 60)
    $g.DrawRectangle($crossPen, 26, 2, 12, 60)
    $g.FillRectangle($crossBrush, 6, 10, 52, 12)
    $g.DrawRectangle($crossPen, 6, 10, 52, 12)
    $brain = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 0, 40, 104))
    $brainPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 10, 17, 28)), 2
    $g.FillEllipse($brain, 12, 28, 22, 26)
    $g.FillEllipse($brain, 30, 28, 22, 26)
    $g.FillEllipse($brain, 18, 44, 28, 14)
    $g.DrawEllipse($brainPen, 12, 28, 22, 26)
    $g.DrawEllipse($brainPen, 30, 28, 22, 26)
    $g.DrawEllipse($brainPen, 18, 44, 28, 14)
    $fold = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 10, 17, 28)), 1.6
    $g.DrawLine($fold, 32, 32, 32, 52)
    $gyrus = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 244, 246, 248)), 1.4
    $g.DrawArc($gyrus, 15, 32, 14, 12, 200, 140)
    $g.DrawArc($gyrus, 35, 32, 14, 12, 200, 140)
    $g.Dispose()
    $png = New-Object System.IO.MemoryStream
    $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
    $bytes = $png.ToArray()
    $bmp.Dispose()
    $crossBrush.Dispose()
    $crossPen.Dispose()
    $brain.Dispose()
    $brainPen.Dispose()
    $fold.Dispose()
    $gyrus.Dispose()
    $png.Dispose()
    $ico = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter $ico
    $bw.Write([uint16]0)
    $bw.Write([uint16]1)
    $bw.Write([uint16]1)
    $bw.Write([byte]64)
    $bw.Write([byte]64)
    $bw.Write([byte]0)
    $bw.Write([byte]0)
    $bw.Write([uint16]1)
    $bw.Write([uint16]32)
    $bw.Write([uint32]$bytes.Length)
    $bw.Write([uint32]22)
    $bw.Write($bytes)
    $bw.Flush()
    $ico.Position = 0
    $script:iconStream = $ico
    return New-Object System.Drawing.Icon $ico
}

$railBg = [System.Drawing.Color]::FromArgb(7, 13, 22)
$deskIcon = New-GodBrainIcon
$f = New-Object System.Windows.Forms.Form
$f.Text = "Desk"
$f.FormBorderStyle = "Sizable"
$f.MaximizeBox = $true
# Wide enough for the longest model id, a gap, then Start and Stop.
$script:pageW = 596
$f.ClientSize = New-Object System.Drawing.Size((52 + $script:pageW), 640)
$f.StartPosition = "CenterScreen"
$f.BackColor = $bg
$f.ForeColor = $ink
$f.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$f.Icon = $deskIcon
$f.MinimumSize = $f.Size

$rail = New-Object System.Windows.Forms.Panel
$rail.Location = New-Object System.Drawing.Point(0, 0)
$rail.Size = New-Object System.Drawing.Size(52, 612)
$rail.Anchor = "Top, Bottom, Left"
$rail.BackColor = $railBg
$f.Controls.Add($rail)

$pages = @{}
function New-Page {
    $p = New-Object System.Windows.Forms.Panel
    $p.Location = New-Object System.Drawing.Point(52, 0)
    $p.Size = New-Object System.Drawing.Size($script:pageW, 612)
    $p.Anchor = "Top, Bottom, Left, Right"
    $p.BackColor = $bg
    $p.Visible = $false
    $f.Controls.Add($p)
    return $p
}
$pageStatus = New-Page
$pageModel = New-Page
$pageAsk = New-Page
$pageLyrics = New-Page
$pageClips = New-Page
$pageMonitor = New-Page
$pages.Status = $pageStatus
$pages.Model = $pageModel
$pages.Ask = $pageAsk
$pages.Lyrics = $pageLyrics
$pages.Clips = $pageClips
$pages.Monitor = $pageMonitor

$script:railMarks = @()
$script:railTip = New-Object System.Windows.Forms.ToolTip
function Add-Rail([string]$name, [string]$glyph, [int]$y) {
    $mark = New-Object System.Windows.Forms.Panel
    $mark.Location = New-Object System.Drawing.Point(0, $y)
    $mark.Size = New-Object System.Drawing.Size(3, 36)
    $mark.BackColor = $teal
    $mark.Visible = $false
    $rail.Controls.Add($mark)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $glyph
    $b.Font = New-Object System.Drawing.Font("Segoe MDL2 Assets", 15)
    $b.FlatStyle = "Flat"
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $railBg
    $b.ForeColor = $mute
    $b.Location = New-Object System.Drawing.Point(6, $y)
    $b.Size = New-Object System.Drawing.Size(40, 36)
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.Tag = $name
    $b.Add_Click({
        param($sender, $e)
        Show-Page $sender.Tag
    })
    $rail.Controls.Add($b)
    $script:railTip.SetToolTip($b, $name)
    $script:railMarks += [pscustomobject]@{ Name = $name; Mark = $mark; Button = $b }
}

function Show-Page([string]$name) {
    foreach ($key in @($pages.Keys)) { $pages[$key].Visible = ($key -eq $name) }
    foreach ($item in $script:railMarks) {
        $on = $item.Name -eq $name
        $item.Mark.Visible = $on
        $item.Button.ForeColor = $(if ($on) { $ink } else { $mute })
    }
    if ($name -eq "Monitor" -and -not $script:monitorSnapshot -and -not $script:monitorJob) {
        Start-MonitorOperation "read"
    }
}

# Gauge, sun, chat, music, video. Same rail idea as the sky strip.
Add-Rail "Status" ([char]0xE9D9) 16
Add-Rail "Model" ([char]0xE706) 64
Add-Rail "Ask" ([char]0xE8BD) 112
Add-Rail "Lyrics" ([char]0xE189) 160
Add-Rail "Clips" ([char]0xE714) 208
Add-Rail "Monitor" ([char]0xE7F4) 296

$script:micRail = New-Object System.Windows.Forms.Button
$script:micRail.Text = [char]0xE720
$script:micRail.Font = New-Object System.Drawing.Font("Segoe MDL2 Assets", 14)
$script:micRail.FlatStyle = "Flat"
$script:micRail.FlatAppearance.BorderSize = 0
$script:micRail.BackColor = $railBg
$script:micRail.ForeColor = $mute
$script:micRail.Location = New-Object System.Drawing.Point(6, 344)
$script:micRail.Size = New-Object System.Drawing.Size(40, 36)
$script:micRail.Cursor = [System.Windows.Forms.Cursors]::Hand
$script:micRail.Add_Click({
    try {
        if ($script:micHot) { [MicDesk]::SetAll($true) }
        else { [MicDesk]::UnmuteDefault() }
    } catch {}
    Update-MicMark
})
$rail.Controls.Add($script:micRail)
$script:micTip = New-Object System.Windows.Forms.ToolTip

$exitRail = New-Object System.Windows.Forms.Button
$exitRail.Text = [char]0xE7E8
$exitRail.Font = New-Object System.Drawing.Font("Segoe MDL2 Assets", 14)
$exitRail.FlatStyle = "Flat"
$exitRail.FlatAppearance.BorderSize = 0
$exitRail.BackColor = $railBg
$exitRail.ForeColor = $mute
$exitRail.Location = New-Object System.Drawing.Point(6, 420)
$exitRail.Size = New-Object System.Drawing.Size(40, 36)
$exitRail.Cursor = [System.Windows.Forms.Cursors]::Hand
$exitRail.Add_Click({
    $script:quit = $true
    if ($script:ni) { $script:ni.Visible = $false; $script:ni.Dispose() }
    $f.Close()
})
$rail.Controls.Add($exitRail)
$exitTip = New-Object System.Windows.Forms.ToolTip
$exitTip.SetToolTip($exitRail, "Exit")

function Add-Head([System.Windows.Forms.Control]$parent, [string]$text, [int]$y) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.ForeColor = $ink
    $l.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 13)
    $l.Location = New-Object System.Drawing.Point(20, $y)
    $l.AutoSize = $true
    $parent.Controls.Add($l)
}

function Add-Row([System.Windows.Forms.Control]$parent, [string]$name, [int]$y) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $name
    $l.ForeColor = $mute
    $l.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $l.Location = New-Object System.Drawing.Point(12, $y)
    $l.Size = New-Object System.Drawing.Size(84, 22)
    $v = New-Object System.Windows.Forms.Label
    $v.Text = "..."
    $v.ForeColor = $ink
    $v.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $v.TextAlign = "MiddleRight"
    $v.AutoEllipsis = $true
    $v.Location = New-Object System.Drawing.Point(96, $y)
    $v.Size = New-Object System.Drawing.Size(312, 22)
    $parent.Controls.Add($l)
    $parent.Controls.Add($v)
    return $v
}

function Add-Pair([System.Windows.Forms.Control]$parent, [string]$name, [int]$y, [scriptblock]$start, [scriptblock]$stop) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $name
    $l.ForeColor = $mute
    $l.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $l.Location = New-Object System.Drawing.Point(12, $y)
    $l.Size = New-Object System.Drawing.Size(78, 22)
    $v = New-Object System.Windows.Forms.Label
    $v.Text = "..."
    $v.ForeColor = $ink
    $v.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $v.TextAlign = "MiddleRight"
    $v.AutoEllipsis = $true
    $v.Location = New-Object System.Drawing.Point(96, $y)
    $v.Size = New-Object System.Drawing.Size(312, 22)
    $parent.Controls.Add($l)
    $parent.Controls.Add($v)
    $small = New-Object System.Drawing.Font("Segoe UI", 8)
    foreach ($pair in @(
            @{ Text = "Start"; X = 432; Primary = $true; Click = $start },
            @{ Text = "Stop"; X = 510; Primary = $false; Click = $stop }
        )) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $pair.Text
        $b.Font = $small
        $b.Location = New-Object System.Drawing.Point([int]$pair.X, ($y - 2))
        $b.Size = New-Object System.Drawing.Size(70, 24)
        Paint-Button $b ([bool]$pair.Primary)
        $b.Add_Click($pair.Click)
        $parent.Controls.Add($b)
    }
    return $v
}

function Paint-Button([System.Windows.Forms.Button]$b, [bool]$primary) {
    $b.FlatStyle = "Flat"
    $b.FlatAppearance.BorderSize = 0
    $b.ForeColor = $(if ($primary) { [System.Drawing.Color]::White } else { $ink })
    $b.BackColor = $(if ($primary) { $pill } else { $card })
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
}

function Add-Button([System.Windows.Forms.Control]$parent, [string]$text, [int]$x, [int]$y, [int]$w, [scriptblock]$click, [bool]$primary) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size($w, 34)
    Paint-Button $b $primary
    $b.Add_Click($click)
    $parent.Controls.Add($b)
}

function Style-Box([System.Windows.Forms.TextBox]$t) {
    $t.BorderStyle = "FixedSingle"
    $t.BackColor = $fieldBg
    $t.ForeColor = $ink
}

Add-Head $pageStatus "Status" 16
Add-Button $pageStatus "Galaxy" ($script:pageW - 100) 8 84 { Start-Process "http://127.0.0.1:8083/" } $false
$rowModel = Add-Pair $pageStatus "Model" 48 { Start-SelectedModel } { Stop-ActiveModel }
$rowGpu = Add-Row $pageStatus "GPU" 80
$rowTok = Add-Row $pageStatus "Rate" 112
$rowKernel = Add-Pair $pageStatus "Kernel" 144 { Start-DeskListener "kernel" } {
    if (-not (Confirm-Stop "Stop the kernel on :8083 so the exe can be rebuilt? Watch leaves it down until you press Start." "Kernel")) { return }
    if (Stop-OwnedListener 8083 "godbrain-kernel.exe" "Kernel") {
        Set-DeskPause "kernel"
        Update-Status
    }
}
$rowRag = Add-Pair $pageStatus "RAG" 176 { Start-DeskListener "rag" } {
    if (-not (Confirm-Stop "Stop rag-service on :8084 so the exe can be rebuilt? Watch leaves it down until you press Start." "RAG")) { return }
    if (Stop-OwnedListener 8084 "rag-service.exe" "RAG") {
        Set-DeskPause "rag"
        Update-Status
    }
}
$rowMongo = Add-Pair $pageStatus "Mongo" 208 { Set-HostService "MongoDB" "start" } {
    if (-not (Confirm-Stop "Stop the MongoDB service? RAG and the kernel lose the database until you start it again." "Mongo")) { return }
    Set-HostService "MongoDB" "stop"
}
$rowGym = Add-Pair $pageStatus "Gym" 240 { Start-GymDashboard } {
    if (-not (Confirm-Stop "Stop the gym on :4177? The practice loop and the dashboard both go down." "Gym")) { return }
    Stop-GymDashboard
}
$rowCs2 = Add-Pair $pageStatus "CS2" 272 { Start-Cs2Desk } { Stop-Cs2Desk }
$rowMouth = Add-Pair $pageStatus "Mouth" 304 { Start-MouthHold } { Stop-MouthHold }
$rowRust = Add-Pair $pageStatus "RustDesk" 336 { Set-HostService "RustDesk" "start" } {
    if (-not (Confirm-Stop "Stop RustDesk (service or installed app)? Remote desktop will drop; AFK recovery leaves it paused until Start." "RustDesk")) { return }
    Set-HostService "RustDesk" "stop"
}
$rowSsh = Add-Pair $pageStatus "SSH" 368 { Set-HostService "sshd" "start" } {
    if (-not (Confirm-Stop "Stop sshd? Remote shells on :2222 drop." "SSH")) { return }
    Set-HostService "sshd" "stop"
}
$rowTail = Add-Pair $pageStatus "Tailscale" 400 { Start-TailscaleDesk } {
    if (-not (Confirm-Stop "Stop the Tailscale service? This machine leaves the tailnet until you start the service again. This does not log out or reset Tailscale." "Tailscale")) { return }
    Set-HostService "Tailscale" "stop"
}
$rowServe = Add-Row $pageStatus "Serve" 432
$rowWatch = Add-Pair $pageStatus "AFK Watch" 464 { Set-WatchTask "ENABLE" } {
    if (-not (Confirm-Stop "Stop AFK Watch? Automatic host/gym recovery stays off until you enable it again. A Heal already running may finish; running services/models are left alone." "Watch")) { return }
    Set-WatchTask "DISABLE"
}
$rowWeb = Add-Pair $pageStatus "Web" 496 { Start-WebDoor } { Stop-WebDoor }
$rowWhisper = Add-Pair $pageStatus "STT/TTS" 528 { Start-VoiceDoor } { Stop-VoiceDoor }
$afkGym = New-Object System.Windows.Forms.CheckBox
$afkGym.Text = "Recover Qwen + gym while AFK (opt-in)"
$afkGym.Location = New-Object System.Drawing.Point(16, 564)
$afkGym.Size = New-Object System.Drawing.Size(($script:pageW - 32), 24)
$afkGym.ForeColor = $ink
$afkGym.BackColor = $bg
$afkGymFile = Join-Path $Repo "logs\afk-gym.txt"
$afkGym.Checked = (Test-Path -LiteralPath $afkGymFile) -and
    (Get-Content -LiteralPath $afkGymFile -Raw).Trim() -eq "on"
$afkGym.Add_CheckedChanged({
    New-Item -ItemType Directory -Path (Join-Path $Repo "logs") -Force | Out-Null
    Set-Content -LiteralPath $afkGymFile -Value $(if ($afkGym.Checked) { "on" } else { "off" })
})
$pageStatus.Controls.Add($afkGym)

$script:statusTip = New-Object System.Windows.Forms.ToolTip
$script:statusRows = [ordered]@{
    Model = $rowModel; Tok = $rowTok; Kernel = $rowKernel; Rag = $rowRag
    Mongo = $rowMongo; Gym = $rowGym; Cs2 = $rowCs2; Mouth = $rowMouth
    Gpu = $rowGpu; Rust = $rowRust; Ssh = $rowSsh; Tail = $rowTail
    Serve = $rowServe; Watch = $rowWatch; Web = $rowWeb; Whisper = $rowWhisper
}
$script:statusWorker = [PowerShell]::Create()
$script:statusJob = $null
$script:statusNextRefresh = [datetime]::MinValue
$script:statusRefreshRequested = $false
function Update-Status([switch]$Poll) {
    if (-not $Poll) { $script:statusRefreshRequested = $true }
    if ($script:statusJob) {
        if (-not $script:statusJob.IsCompleted) { return }
        try {
            $result = @($script:statusWorker.EndInvoke($script:statusJob))
            if ($result.Count -ne 1 -or -not $result[0].Rows) { throw "Invalid Desk status snapshot." }
            $snapshot = $result[0]
            foreach ($entry in $script:statusRows.GetEnumerator()) {
                $entry.Value.Text = [string]$snapshot.Rows.($entry.Key)
                $script:statusTip.SetToolTip($entry.Value, $entry.Value.Text)
            }
            $script:tokSample = $snapshot.TokenSample
            if ($script:modelLive) { $script:modelLive.Text = [string]$snapshot.ModelConfig }
            Update-MicMark
        } catch {
            foreach ($label in $script:statusRows.Values) {
                $label.Text = "unread"
                $script:statusTip.SetToolTip($label, "Status refresh failed: $($_.Exception.Message)")
            }
            $rowModel.Text = "Status refresh failed"
        } finally {
            $script:statusJob = $null
            $script:statusNextRefresh = [datetime]::UtcNow.AddSeconds(4)
        }
    }
    if ($script:statusRefreshRequested -or [datetime]::UtcNow -ge $script:statusNextRefresh) {
        $script:statusWorker.Commands.Clear()
        $script:statusWorker.Streams.Error.Clear()
        [void]$script:statusWorker.AddCommand($PSCommandPath).AddParameter("StatusSnapshot").AddParameter("TokenSample", $script:tokSample)
        $script:statusJob = $script:statusWorker.BeginInvoke()
        $script:statusRefreshRequested = $false
    }
}
Update-Status
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 100
$timer.Add_Tick({ Update-Status -Poll; Update-Ask; Update-Monitor })
$timer.Start()

Add-Head $pageModel "Model" 16
$modelHint = New-Object System.Windows.Forms.Label
$modelHint.Text = "Pick one. Status starts and stops it. One GPU slot."
$modelHint.ForeColor = $mute
$modelHint.Location = New-Object System.Drawing.Point(20, 48)
$modelHint.Size = New-Object System.Drawing.Size(($script:pageW - 40), 22)
$pageModel.Controls.Add($modelHint)
$script:modelButtons = @{}
function Set-ModelPick([string]$Name) {
    if ($script:modelContext -and $script:modelPick -ne "image" -and -not $script:modelSettingsError) {
        Save-DeskModelControls -MemoryOnly
    }
    $script:modelPick = $Name
    foreach ($key in @($script:modelButtons.Keys)) {
        Paint-Button $script:modelButtons[$key] ($key -eq $Name)
    }
    if ($script:modelContext) { Show-DeskModelControls }
}
function Add-ModelPick([string]$key, [string]$text, [int]$x, [int]$y, [int]$w) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Tag = $key
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size($w, 34)
    $b.Add_Click({
        param($sender, $e)
        try { Set-ModelPick ([string]$sender.Tag) }
        catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message) }
    })
    $pageModel.Controls.Add($b)
    $script:modelButtons[$key] = $b
}
Add-ModelPick "27b" "27B text" 20 80 112
Add-ModelPick "vl" "8B vision" 140 80 112
Add-ModelPick "image" "Qwen-Image-2.1" 260 80 184
Add-ModelPick "uncensored" "Qwen3.8-27B-Uncensored" 20 124 ($script:pageW - 40)
Set-ModelPick "27b"

$script:modelSettingsPath = Join-Path $Repo "logs\desk-model-settings.json"
$script:modelSettingsError = ""
try { $script:modelProfiles = Read-DeskModelProfiles $script:modelSettingsPath }
catch { $script:modelProfiles = @{}; $script:modelSettingsError = $_.Exception.Message }
function Add-ModelLabel([string]$Text, [int]$Y) {
    $label = [System.Windows.Forms.Label]::new()
    $label.Text = $Text
    $label.ForeColor = $mute
    $label.Location = [Drawing.Point]::new(20, $Y)
    $label.Size = [Drawing.Size]::new(556, 22)
    $pageModel.Controls.Add($label)
}
Add-ModelLabel "Context tokens (prompt + thinking/output; multiple of 256)" 180
$script:modelContext = [System.Windows.Forms.TextBox]::new()
$script:modelContext.Location = [Drawing.Point]::new(20, 204)
$script:modelContext.Size = [Drawing.Size]::new(168, 26)
Style-Box $script:modelContext
$pageModel.Controls.Add($script:modelContext)
Add-ModelLabel "KV cache precision (not model weight precision)" 242
$script:modelCache = [System.Windows.Forms.ComboBox]::new()
$script:modelCache.DropDownStyle = "DropDownList"
$script:modelCache.Items.AddRange(@("4", "8", "8,4", "fp16"))
$script:modelCache.Location = [Drawing.Point]::new(20, 266)
$script:modelCache.Size = [Drawing.Size]::new(168, 26)
$pageModel.Controls.Add($script:modelCache)
$script:modelMtp = [System.Windows.Forms.CheckBox]::new()
$script:modelMtp.Text = "MTP enabled (draft window 4)"
$script:modelMtp.ForeColor = $ink
$script:modelMtp.Location = [Drawing.Point]::new(208, 266)
$script:modelMtp.Size = [Drawing.Size]::new(348, 26)
$pageModel.Controls.Add($script:modelMtp)
$script:modelVision = [System.Windows.Forms.CheckBox]::new()
$script:modelVision.Text = "Vision tower on next 27B start (off by default)"
$script:modelVision.ForeColor = $ink
$script:modelVision.Location = [Drawing.Point]::new(208, 204)
$script:modelVision.Size = [Drawing.Size]::new(360, 26)
$pageModel.Controls.Add($script:modelVision)
Add-ModelLabel "GPU budget GiB" 304
$pageModel.Controls[$pageModel.Controls.Count - 1].Size = [Drawing.Size]::new(168, 22)
$script:modelBudget = [System.Windows.Forms.TextBox]::new()
$script:modelBudget.Location = [Drawing.Point]::new(20, 328)
$script:modelBudget.Size = [Drawing.Size]::new(168, 26)
Style-Box $script:modelBudget
$pageModel.Controls.Add($script:modelBudget)
Add-ModelLabel "RAM prefix cache GiB (reuse only)" 304
$pageModel.Controls[$pageModel.Controls.Count - 1].Location = [Drawing.Point]::new(208, 304)
$pageModel.Controls[$pageModel.Controls.Count - 1].Size = [Drawing.Size]::new(368, 22)
$script:modelCpuCache = [System.Windows.Forms.TextBox]::new()
$script:modelCpuCache.Location = [Drawing.Point]::new(208, 328)
$script:modelCpuCache.Size = [Drawing.Size]::new(168, 26)
Style-Box $script:modelCpuCache
$pageModel.Controls.Add($script:modelCpuCache)
$script:modelSettingsHint = [System.Windows.Forms.Label]::new()
$script:modelSettingsHint.Font = [Drawing.Font]::new("Segoe UI", 9)
$script:modelSettingsHint.ForeColor = $mute
$script:modelSettingsHint.Location = [Drawing.Point]::new(20, 410)
$script:modelSettingsHint.Size = [Drawing.Size]::new(556, 140)
$pageModel.Controls.Add($script:modelSettingsHint)
$script:modelLive = [System.Windows.Forms.Label]::new()
$script:modelLive.Font = [Drawing.Font]::new("Segoe UI", 9)
$script:modelLive.ForeColor = $ink
$script:modelLive.Location = [Drawing.Point]::new(20, 558)
$script:modelLive.Size = [Drawing.Size]::new(556, 48)
$script:modelLive.Text = "Live settings pending status refresh..."
$pageModel.Controls.Add($script:modelLive)
function Save-DeskModelControls([switch]$MemoryOnly) {
    if ($script:modelSettingsError) { throw $script:modelSettingsError }
    if ($script:modelPick -eq "image") { return }
    $profile = @{ Context = $script:modelContext.Text; CacheQuant = [string]$script:modelCache.SelectedItem
        Mtp = [bool]$script:modelMtp.Checked; Budget = $script:modelBudget.Text; CpuCache = $script:modelCpuCache.Text }
    if ($script:modelPick -eq "27b") { $profile.Vision = [bool]$script:modelVision.Checked }
    [void](Get-DeskModelLaunchOptions $script:modelPick $profile)
    $script:modelProfiles[$script:modelPick] = $profile
    if (-not $MemoryOnly) {
        Write-DeskModelProfiles $script:modelSettingsPath $script:modelProfiles
        $script:modelSettingsHint.Text = "Saved for the next explicit Start from Status. The running model is unchanged."
    }
}
function Show-DeskModelControls {
    $enabled = $script:modelPick -ne "image" -and -not $script:modelSettingsError
    foreach ($control in @($script:modelContext, $script:modelCache, $script:modelMtp, $script:modelBudget, $script:modelCpuCache, $script:modelVision)) {
        $control.Enabled = $enabled
    }
    $script:modelMtp.Enabled = $enabled -and $script:modelPick -ne "vl"
    $script:modelVision.Enabled = $enabled -and $script:modelPick -eq "27b"
    $script:modelBudget.Enabled = $enabled -and $script:modelPick -ne "vl"
    foreach ($button in $pageModel.Controls) {
        if ($button.Text -eq "Large text (~70k)") { $button.Enabled = $enabled -and $script:modelPick -ne "vl" }
        if ($button.Text -eq "Max context (kit)") { $button.Enabled = $enabled -and $script:modelPick -eq "27b" }
        if ($button.Text -eq "Save") { $button.Enabled = $enabled }
    }
    if ($enabled) {
        $profile = if ($script:modelProfiles.ContainsKey($script:modelPick)) {
            $script:modelProfiles[$script:modelPick]
        } else { Get-DeskModelDefaults $script:modelPick }
        $script:modelContext.Text = [string]$profile.Context
        $script:modelCache.SelectedItem = [string]$profile.CacheQuant
        $script:modelMtp.Checked = [bool]$profile.Mtp
        $script:modelBudget.Text = [string]$profile.Budget
        $script:modelCpuCache.Text = if ($profile.ContainsKey("CpuCache")) { [string]$profile.CpuCache } else { "0" }
        $script:modelVision.Checked = $script:modelPick -eq "27b" -and $profile.ContainsKey("Vision") -and [bool]$profile.Vision
    } else { $script:modelVision.Checked = $false }
    $script:modelSettingsHint.Text = if ($script:modelSettingsError) { $script:modelSettingsError } elseif (-not $enabled) {
        "Image diffusion does not have token context or MTP controls."
    } else {
        "~70k: int4 KV, MTP/vision off; unchanged weights.`r`nRAM cache reuses prefixes, not extra live context. No dense CPU/SSD weight spill.`r`nThe vision checkbox loads the 27B tower on the next Start and lets :8001 try it for OCR. STT and TTS stay on the CPU.`r`nSave is passive; Status Start applies. Max is a kit plan."
    }
}
Add-Button $pageModel "Large text (~70k)" 20 370 168 {
    if ($script:modelPick -notin @("27b", "uncensored") -or $script:modelSettingsError) { return }
    $script:modelContext.Text = "71680"
    $script:modelCache.SelectedItem = "4"
    $script:modelMtp.Checked = $false
    $script:modelVision.Checked = $false
    $script:modelBudget.Text = "14.7"
    $script:modelCpuCache.Text = "4"
} $false
Add-Button $pageModel "Max context (kit)" 200 370 180 {
    if ($script:modelPick -ne "27b" -or $script:modelSettingsError) {
        [System.Windows.Forms.MessageBox]::Show("The kit's measured planner applies only to the standard 27B checkpoint.")
        return
    }
    try {
        $memory = @(& nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits)
        if ($LASTEXITCODE -ne 0 -or $memory.Count -ne 1) { throw "Expected one detected GPU." }
        $plan = Invoke-DeskReviewPlanner @{ op = "profile"; kit = $Kit; vram_gib = [double]$memory[0] / 1024 }
        if ($plan.context -lt 256) { throw "The planner offers no supported context on this card." }
        $script:modelContext.Text = [string]$plan.context
        $script:modelCache.SelectedItem = "4"
        $script:modelMtp.Checked = $false
        $script:modelVision.Checked = $false
        $script:modelBudget.Text = [string]$plan.budget
        $script:modelCpuCache.Text = "4"
        $script:modelSettingsHint.Text = "Kit plan: $($plan.context) tokens, text-only, int4 KV, MTP off for headroom. Weight precision unchanged. The planner is not a new host benchmark; explicit Start confirms a large-context restart."
    } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message) }
} $false
Add-Button $pageModel "Save" 392 370 164 {
    try { Save-DeskModelControls } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message) }
} $true
Show-DeskModelControls

Add-Head $pageAsk "Ask" 16
$fileLabel = New-Object System.Windows.Forms.Label
$fileLabel.Text = "Path (file/folder, review source, or image input)"
$fileLabel.ForeColor = $mute
$fileLabel.Location = New-Object System.Drawing.Point(20, 44)
$fileLabel.AutoSize = $true
$pageAsk.Controls.Add($fileLabel)
$askPath = New-Object System.Windows.Forms.TextBox
$askPath.Location = New-Object System.Drawing.Point(20, 66)
$askPath.Size = New-Object System.Drawing.Size(($script:pageW - 40), 26)
Style-Box $askPath
$pageAsk.Controls.Add($askPath)
$prompt = New-Object System.Windows.Forms.TextBox
$prompt.Multiline = $true
$prompt.ScrollBars = "Vertical"
$prompt.Location = New-Object System.Drawing.Point(20, 100)
$prompt.Size = New-Object System.Drawing.Size(($script:pageW - 152), 52)
Style-Box $prompt
$pageAsk.Controls.Add($prompt)
$script:askWorker = [PowerShell]::Create()
$script:askJob = $null
$send = New-Object System.Windows.Forms.Button
$send.Text = "Send"
$send.Location = New-Object System.Drawing.Point(($script:pageW - 124), 100)
$send.Size = New-Object System.Drawing.Size(104, 34)
Paint-Button $send $true
$send.Add_Click({
    if ($script:askJob) { return }
    $request = [pscustomobject]@{
        Message = [string]$prompt.Text
        Path = [string]$askPath.Text
        ImageModel = ($script:modelPick -eq "image")
        ReviewFile = [bool]$reviewFile.Checked
    }
    $reply.Text = "working..."
    $send.Enabled = $false
    $script:askWorker.Commands.Clear()
    $script:askWorker.Streams.Error.Clear()
    [void]$script:askWorker.AddCommand($PSCommandPath).AddParameter("AskRequest", $request)
    $script:askJob = $script:askWorker.BeginInvoke()
})
$pageAsk.Controls.Add($send)
$reviewFile = [System.Windows.Forms.CheckBox]::new()
$reviewFile.Text = "Review complete file (read-only; auto above 128 KiB)"
$reviewFile.ForeColor = $ink
$reviewFile.Location = [Drawing.Point]::new(20, 156)
$reviewFile.Size = [Drawing.Size]::new(($script:pageW - 40), 24)
$pageAsk.Controls.Add($reviewFile)
function Update-Ask {
    if (-not $script:askJob -or -not $script:askJob.IsCompleted) { return }
    try {
        $result = @($script:askWorker.EndInvoke($script:askJob))
        if ($result.Count -ne 1) { throw "Invalid Ask response." }
        $reply.Text = ([string]$result[0]) -replace "\r?\n", "`r`n"
    } catch {
        $reply.Text = "Error: $($_.Exception.Message)"
        if ($_.ErrorDetails.Message) { $reply.Text += "`r`n$($_.ErrorDetails.Message)" }
    } finally {
        $script:askJob = $null
        $send.Enabled = $true
    }
}
$reply = New-Object System.Windows.Forms.TextBox
$reply.Multiline = $true
$reply.ScrollBars = "Vertical"
$reply.Location = New-Object System.Drawing.Point(20, 188)
$reply.Size = New-Object System.Drawing.Size(($script:pageW - 40), 306)
$reply.MaxLength = 0
Style-Box $reply
$pageAsk.Controls.Add($reply)
$cwdLabel = New-Object System.Windows.Forms.Label
$cwdLabel.Text = "Grok folder"
$cwdLabel.ForeColor = $mute
$cwdLabel.Location = New-Object System.Drawing.Point(20, 508)
$cwdLabel.AutoSize = $true
$pageAsk.Controls.Add($cwdLabel)
$cwd = New-Object System.Windows.Forms.TextBox
$cwd.Text = $Repo
$cwd.Location = New-Object System.Drawing.Point(20, 530)
$cwd.Size = New-Object System.Drawing.Size(($script:pageW - 164), 26)
Style-Box $cwd
$pageAsk.Controls.Add($cwd)
Add-Button $pageAsk "Open Grok" ($script:pageW - 132) 526 112 {
    $dir = $cwd.Text
    if (-not (Test-Path -LiteralPath $dir)) { [System.Windows.Forms.MessageBox]::Show("No such folder: $dir"); return }
    $grok = (Get-Command grok -ErrorAction SilentlyContinue).Source
    if (-not $grok) { [System.Windows.Forms.MessageBox]::Show("grok is not on PATH"); return }
    Start-Process -FilePath $grok -WorkingDirectory $dir | Out-Null
} $false

foreach ($control in @($askPath, $prompt, $reviewFile)) { $control.Anchor = "Top, Left, Right" }
$send.Anchor = "Top, Right"
$reply.Anchor = "Top, Bottom, Left, Right"
$cwdLabel.Anchor = "Bottom, Left"
$cwd.Anchor = "Bottom, Left, Right"
($pageAsk.Controls | Where-Object { $_ -is [Windows.Forms.Button] -and $_.Text -eq "Open Grok" }).Anchor = "Bottom, Right"

Add-Head $pageLyrics "Lyrics" 16
function Add-Field([string]$label, [string]$value, [int]$x, [int]$y, [int]$w) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $label
    $l.ForeColor = $mute
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.AutoSize = $true
    $pageLyrics.Controls.Add($l)
    $t = New-Object System.Windows.Forms.TextBox
    $t.Text = $value
    $t.Location = New-Object System.Drawing.Point($x, ($y + 18))
    $t.Size = New-Object System.Drawing.Size($w, 24)
    Style-Box $t
    $pageLyrics.Controls.Add($t)
    return $t
}
$artist = Add-Field "Artist" "Gravel_N_Bones" 20 56 170
$album = Add-Field "Album" "" 204 56 180
$name = Add-Field "Track" "" 20 108 170
$song = Add-Field "Length" "4:00" 204 108 80
$pre = Add-Field "Preroll" "1" 296 108 88

$hint = New-Object System.Windows.Forms.Label
$hint.Text = "Record needs ncspot paused. Whisper again redoes drafts. Lock in crowns the draft."
$hint.ForeColor = $mute
$hint.Location = New-Object System.Drawing.Point(20, 160)
$hint.Size = New-Object System.Drawing.Size(($script:pageW - 40), 48)
$pageLyrics.Controls.Add($hint)

$go = New-Object System.Windows.Forms.Button
$go.Text = "Record and play"
$go.Location = New-Object System.Drawing.Point(20, 220)
$go.Size = New-Object System.Drawing.Size(180, 34)
Paint-Button $go $true
$go.Add_Click({
    $nc = Get-Process -Name ncspot -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $nc) { [System.Windows.Forms.MessageBox]::Show("ncspot is not running"); return }
    if (-not $name.Text -or -not $song.Text) { [System.Windows.Forms.MessageBox]::Show("Track and length are required"); return }
    $force = @()
    $st = Get-LyricsStatePath
    if ($st -and (Test-Path -LiteralPath $st)) {
        $locked = 0
        try {
            $state = Get-Content -LiteralPath $st -Raw | ConvertFrom-Json
            $locked = @($state.segments | Where-Object { $_.locked }).Count
        } catch {
            $locked = -1
        }
        if ($locked -ne 0) {
            $n = if ($locked -lt 0) { "an unreadable" } else { "$locked locked" }
            $ask = [System.Windows.Forms.MessageBox]::Show(
                "This track has $n take. Recording again overwrites the mix and does not keep the old locked lines. Continue?",
                "Record",
                [System.Windows.Forms.MessageBoxButtons]::YesNo)
            if ($ask -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            $force = @("-Force")
        }
    }
    $log = Join-Path $env:TEMP "desk-lyrics.log"
    $err = Join-Path $env:TEMP "desk-lyrics.err.log"
    Remove-Item $log, $err -ErrorAction SilentlyContinue
    $args = @(
        "-NoProfile", "-File", $Lyrics,
        "-Name", $name.Text,
        "-RecordSeconds", $song.Text,
        "-Song", $song.Text
    )
    if ($artist.Text) { $args += @("-Artist", $artist.Text) }
    if ($album.Text) { $args += @("-Album", $album.Text) }
    if ($force.Count -gt 0) { $args += $force }
    Start-Process -FilePath $Pwsh -ArgumentList $args -RedirectStandardOutput $log -RedirectStandardError $err -WindowStyle Normal | Out-Null
    $deadline = (Get-Date).AddSeconds(45)
    $saw = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
        $hit = $false
        foreach ($file in @($log, $err)) {
            if ((Test-Path $file) -and (Select-String -Path $file -Pattern "record loopback" -Quiet)) { $hit = $true }
        }
        if ($hit) { $saw = $true; break }
    }
    if (-not $saw) { [System.Windows.Forms.MessageBox]::Show("Capture did not print record loopback. ncspot was not touched. See $log"); return }
    $sec = 1.0
    [void][double]::TryParse($pre.Text, [ref]$sec)
    if ($sec -lt 0) { $sec = 0 }
    Start-Sleep -Seconds $sec
    $ok = [NcIn]::ShiftP([uint32]$nc.Id)
    if (-not $ok) { [System.Windows.Forms.MessageBox]::Show("Capture is running. Shift+P did not reach ncspot.") }
})
$pageLyrics.Controls.Add($go)
Add-Button $pageLyrics "Whisper again" 210 220 174 {
    if (-not $name.Text) { [System.Windows.Forms.MessageBox]::Show("Track is required"); return }
    $log = Join-Path $env:TEMP "desk-lyrics-recheck.log"
    $err = Join-Path $env:TEMP "desk-lyrics-recheck.err.log"
    Remove-Item $log, $err -ErrorAction SilentlyContinue
    $args = @(
        "-NoProfile", "-File", $Lyrics,
        "-Name", $name.Text,
        "-Recheck"
    )
    if ($artist.Text) { $args += @("-Artist", $artist.Text) }
    if ($album.Text) { $args += @("-Album", $album.Text) }
    Start-Process -FilePath $Pwsh -ArgumentList $args -RedirectStandardOutput $log -RedirectStandardError $err -WindowStyle Normal | Out-Null
    [System.Windows.Forms.MessageBox]::Show("Whisper again started for this track. Draft lines get a new pass. If every line is locked, DRAFT only gets notes like: line 4 should be at 0:32 not 0:38. Locked words stay. Log: $log")
} $false
Add-Button $pageLyrics "Lock in" 20 262 180 {
    if (-not $name.Text) { [System.Windows.Forms.MessageBox]::Show("Track is required"); return }
    $ask = [System.Windows.Forms.MessageBox]::Show(
        "Lock every draft line for $($name.Text)? A later Whisper pass will not change those words.",
        "Lock in",
        [System.Windows.Forms.MessageBoxButtons]::YesNo)
    if ($ask -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $log = Join-Path $env:TEMP "desk-lyrics-lock.log"
    $err = Join-Path $env:TEMP "desk-lyrics-lock.err.log"
    Remove-Item $log, $err -ErrorAction SilentlyContinue
    $args = @(
        "-NoProfile", "-File", $Lyrics,
        "-Name", $name.Text,
        "-AcceptDraft"
    )
    if ($artist.Text) { $args += @("-Artist", $artist.Text) }
    if ($album.Text) { $args += @("-Album", $album.Text) }
    $proc = Start-Process -FilePath $Pwsh -ArgumentList $args -RedirectStandardOutput $log -RedirectStandardError $err -WindowStyle Hidden -Wait -PassThru
    $msg = ""
    if (Test-Path $log) { $msg = (Get-Content -LiteralPath $log -Raw) }
    if ($proc.ExitCode -ne 0 -and (Test-Path $err)) { $msg = (Get-Content -LiteralPath $err -Raw) }
    if (-not $msg) { $msg = "Lock in finished." }
    [System.Windows.Forms.MessageBox]::Show($msg.Trim())
} $true

Add-Head $pageClips "Clips" 16
$clipHint = New-Object System.Windows.Forms.Label
$clipHint.Text = "Scans new CS2 clips with 8B vision on :8888. Files already in the deadtime index are skipped. One GPU slot."
$clipHint.ForeColor = $mute
$clipHint.Location = New-Object System.Drawing.Point(20, 56)
$clipHint.Size = New-Object System.Drawing.Size(($script:pageW - 40), 48)
$pageClips.Controls.Add($clipHint)
Add-Button $pageClips "Scan clips" 20 116 176 { Start-ClipScan } $true

Add-Head $pageMonitor "Monitor" 16
$monitorHint = [Windows.Forms.Label]::new()
$monitorHint.Text = "Dell S2522HG hardware controls. Apply uses readback; Cycle advances Dark Stabilizer without a current-level readout."
$monitorHint.ForeColor = $mute
$monitorHint.Location = [Drawing.Point]::new(20, 52)
$monitorHint.Size = [Drawing.Size]::new(($script:pageW - 40), 44)
$pageMonitor.Controls.Add($monitorHint)
$script:monitorMessage = [Windows.Forms.Label]::new()
$script:monitorMessage.Text = "Open this page to read the monitor."
$script:monitorMessage.ForeColor = $mute
$script:monitorMessage.Location = [Drawing.Point]::new(20, 436)
$script:monitorMessage.Size = [Drawing.Size]::new(($script:pageW - 40), 92)
$pageMonitor.Controls.Add($script:monitorMessage)
$script:monitorWorker = [PowerShell]::Create()
$script:monitorJob = $null
$script:monitorSnapshot = $null
$script:monitorOperation = $null
$script:monitorControls = @{}
$script:monitorApply = @{}
$script:monitorNames = @{}
foreach ($spec in @(
    @{ Id = "brightness"; Name = "Brightness"; Y = 112 },
    @{ Id = "contrast"; Name = "Contrast"; Y = 176 },
    @{ Id = "preset"; Name = "Color preset"; Y = 240 },
    @{ Id = "dark_stabilizer"; Name = "Dark Stabilizer"; Y = 304 }
)) {
    $label = [Windows.Forms.Label]::new()
    $label.Text = $spec.Name
    $label.ForeColor = $ink
    $label.Location = [Drawing.Point]::new(20, $spec.Y)
    $label.Size = [Drawing.Size]::new(144, 28)
    $pageMonitor.Controls.Add($label)
    $script:monitorNames[$spec.Id] = $spec.Name
    if ($spec.Id -eq "dark_stabilizer") {
        $script:monitorDarkLevels = [Windows.Forms.Label]::new()
        $script:monitorDarkLevels.Text = "Disabled / Enabled level 1-3"
        $script:monitorDarkLevels.ForeColor = $ink
        $script:monitorDarkLevels.Location = [Drawing.Point]::new(168, $spec.Y)
        $script:monitorDarkLevels.Size = [Drawing.Size]::new(268, 30)
        $pageMonitor.Controls.Add($script:monitorDarkLevels)
        continue
    }
    if ($spec.Id -in @("brightness", "contrast")) {
        $control = [Windows.Forms.NumericUpDown]::new()
        $control.Maximum = 100
        $control.Minimum = 0
        $control.DecimalPlaces = 0
    } else {
        $control = [Windows.Forms.ComboBox]::new()
        $control.DropDownStyle = "DropDownList"
    }
    $control.Location = [Drawing.Point]::new(168, $spec.Y)
    $control.Size = [Drawing.Size]::new(268, 30)
    $control.BackColor = $fieldBg
    $control.ForeColor = $ink
    $control.Enabled = $false
    $pageMonitor.Controls.Add($control)
    $script:monitorControls[$spec.Id] = $control
    $apply = [Windows.Forms.Button]::new()
    $apply.Text = "Apply"
    $apply.Tag = $spec.Id
    $apply.Location = [Drawing.Point]::new(456, ($spec.Y - 2))
    $apply.Size = [Drawing.Size]::new(112, 34)
    Paint-Button $apply $true
    $apply.Enabled = $false
    $apply.Add_Click({
        param($sender, $event)
        $id = [string]$sender.Tag
        $inputControl = $script:monitorControls[$id]
        $value = if ($id -eq "preset") {
            if ($inputControl.SelectedIndex -lt 0) { return }
            [string]$script:monitorSnapshot.presets[$inputControl.SelectedIndex].id
        } else { [string][int]$inputControl.Value }
        Start-MonitorOperation $id $value
    })
    $pageMonitor.Controls.Add($apply)
    $script:monitorApply[$spec.Id] = $apply
}
$script:monitorRefresh = [Windows.Forms.Button]::new()
$script:monitorRefresh.Text = "Refresh"
$script:monitorRefresh.Location = [Drawing.Point]::new(20, 352)
$script:monitorRefresh.Size = [Drawing.Size]::new(112, 34)
Paint-Button $script:monitorRefresh $false
$script:monitorRefresh.Add_Click({ Start-MonitorOperation "read" })
$pageMonitor.Controls.Add($script:monitorRefresh)
$script:monitorCycle = [Windows.Forms.Button]::new()
$script:monitorCycle.Text = "Cycle (F9)"
$script:monitorCycle.Location = [Drawing.Point]::new(456, 302)
$script:monitorCycle.Size = [Drawing.Size]::new(112, 34)
$script:monitorCycle.Enabled = $false
Paint-Button $script:monitorCycle $true
$script:monitorCycle.Add_Click({ Start-MonitorOperation "dark_stabilizer_cycle" })
$pageMonitor.Controls.Add($script:monitorCycle)
$script:monitorHotkey = [DeskMonitorHotkey]::new(0x78)
$script:monitorHotkey.Add_Pressed({ Start-MonitorOperation "dark_stabilizer_cycle" })
$script:monitorHotkeyHint = [Windows.Forms.Label]::new()
$script:monitorHotkeyHint.Text = "F9 registration pending."
$script:monitorHotkeyHint.ForeColor = $mute
$script:monitorHotkeyHint.Location = [Drawing.Point]::new(20, 392)
$script:monitorHotkeyHint.Size = [Drawing.Size]::new(($script:pageW - 40), 40)
$pageMonitor.Controls.Add($script:monitorHotkeyHint)
$script:monitorClaimHotkey = [Windows.Forms.Button]::new()
$script:monitorClaimHotkey.Text = "Claim F9"
$script:monitorClaimHotkey.Location = [Drawing.Point]::new(456, 352)
$script:monitorClaimHotkey.Size = [Drawing.Size]::new(112, 34)
Paint-Button $script:monitorClaimHotkey $false
$script:monitorClaimHotkey.Add_Click({ Register-MonitorHotkey })
$pageMonitor.Controls.Add($script:monitorClaimHotkey)
$monitorNote = [Windows.Forms.Label]::new()
$monitorNote.Text = "DDM is not required. F9 stays active while Desk is hidden; quit releases it. No mouse hooks, automatic cycle retries or background monitor polling."
$monitorNote.ForeColor = $mute
$monitorNote.Location = [Drawing.Point]::new(20, 536)
$monitorNote.Size = [Drawing.Size]::new(($script:pageW - 40), 60)
$pageMonitor.Controls.Add($monitorNote)

function Set-MonitorEnabled {
    foreach ($id in $script:monitorControls.Keys) {
        $enabled = -not $script:monitorJob -and $script:monitorSnapshot -and
            $script:monitorSnapshot.$id.supported
        $script:monitorControls[$id].Enabled = [bool]$enabled
        $script:monitorApply[$id].Enabled = [bool]$enabled
        if ($id -eq "preset" -and $script:monitorControls[$id].SelectedIndex -lt 0) {
            $script:monitorApply[$id].Enabled = $false
        }
        Paint-Button $script:monitorApply[$id] $script:monitorApply[$id].Enabled
    }
    $script:monitorRefresh.Enabled = -not $script:monitorJob
    $script:monitorCycle.Enabled = -not $script:monitorJob -and $script:monitorSnapshot -and
        $script:monitorSnapshot.dark_stabilizer_cycle.supported
    Paint-Button $script:monitorCycle $script:monitorCycle.Enabled
}
function Show-MonitorNotice([string]$Text, [bool]$Failed = $false) {
    $script:monitorMessage.Text = $Text
    if ($script:ni -and ($Failed -or -not $pageMonitor.Visible)) {
        $icon = if ($Failed) { [Windows.Forms.ToolTipIcon]::Warning } else { [Windows.Forms.ToolTipIcon]::Info }
        $script:ni.ShowBalloonTip(3000, "Dark Stabilizer", $Text, $icon)
    }
}
function Register-MonitorHotkey {
    if ($script:monitorHotkey.Register()) {
        $script:monitorHotkeyHint.Text = "F9 ready, including while Desk is hidden. Each press advances one step; current level is unavailable."
        if ($script:monitorMessage.Text -like "F9 unavailable*") {
            Show-MonitorNotice "F9 registered. Each press sends one cycle command; current level is unavailable."
        }
    } else {
        $script:monitorHotkeyHint.Text = "F9 unavailable (Windows error $($script:monitorHotkey.RegistrationError)). Exit DDM/other F9 owner, then Claim F9."
        Show-MonitorNotice $script:monitorHotkeyHint.Text $true
    }
    $script:monitorClaimHotkey.Enabled = -not $script:monitorHotkey.Registered
}
function Start-MonitorOperation([string]$Control, [string]$Value) {
    if ($script:monitorJob) {
        if ($Control -eq "dark_stabilizer_cycle") {
            Show-MonitorNotice "Monitor busy. This cycle press was not sent or queued; wait for the current operation." $true
        }
        return
    }
    if ($Control -eq "dark_stabilizer_cycle" -and $script:monitorSnapshot -and
            -not $script:monitorSnapshot.dark_stabilizer_cycle.supported) {
        Show-MonitorNotice "Dark Stabilizer cycling is not advertised by this monitor; no command sent." $true
        return
    }
    $script:monitorMessage.Text = if ($Control -eq "read") {
        "Reading Dell S2522HG... DDC/CI discovery can take several seconds."
    } elseif ($Control -eq "dark_stabilizer_cycle") {
        "Sending one Dark Stabilizer cycle command. Current level is unavailable."
    } else { "Applying $Control and checking the monitor's readback..." }
    $script:monitorOperation = $Control
    try {
        $script:monitorWorker.Commands.Clear()
        $script:monitorWorker.Streams.Error.Clear()
        $request = [pscustomobject]@{ Control = $Control; Value = $Value }
        [void]$script:monitorWorker.AddCommand($PSCommandPath).AddParameter("MonitorRequest", $request)
        $script:monitorJob = $script:monitorWorker.BeginInvoke()
    } catch {
        Show-MonitorNotice "Monitor operation could not start: $($_.Exception.Message)" $true
        $script:monitorOperation = $null
    }
    Set-MonitorEnabled
}
function Update-Monitor {
    if (-not $script:monitorJob -or -not $script:monitorJob.IsCompleted) { return }
    try {
        $result = @($script:monitorWorker.EndInvoke($script:monitorJob))
        if ($script:monitorWorker.HadErrors) {
            throw ($script:monitorWorker.Streams.Error | Out-String).Trim()
        }
        if ($result.Count -ne 1 -or $result[0].ok -ne $true) { throw "Invalid monitor snapshot." }
        $script:monitorSnapshot = $result[0]
        $warnings = @()
        foreach ($id in $script:monitorControls.Keys) {
            $state = $script:monitorSnapshot.$id
            if (-not $state.supported) {
                $warnings += "$($script:monitorNames[$id]): $($state.error)"
                continue
            }
            if ($id -in @("brightness", "contrast")) { $script:monitorControls[$id].Value = $state.current }
        }
        if (-not $script:monitorSnapshot.dark_stabilizer.supported) {
            $warnings += "Dark Stabilizer: $($script:monitorSnapshot.dark_stabilizer.error)"
        }
        $presetsBox = $script:monitorControls.preset
        $presetsBox.Items.Clear()
        foreach ($preset in $script:monitorSnapshot.presets) { [void]$presetsBox.Items.Add([string]$preset.name) }
        $presetsBox.SelectedIndex = -1
        for ($i = 0; $i -lt $script:monitorSnapshot.presets.Count; $i++) {
            if ($script:monitorSnapshot.presets[$i].id -eq $script:monitorSnapshot.preset.id) {
                $presetsBox.SelectedIndex = $i
            }
        }
        $script:monitorMessage.Text = "$($script:monitorSnapshot.model) on $($script:monitorSnapshot.display)`r`n"
        $script:monitorMessage.Text += if ($script:monitorSnapshot.action) {
            "Cycle command accepted. Current level unavailable; observe the picture."
        } elseif ($script:monitorSnapshot.changed) {
            "Applied $($script:monitorNames[$script:monitorSnapshot.changed.control]): $($script:monitorSnapshot.changed.requested). Hardware readback confirmed."
        } else { "Current settings read from the monitor." }
        if ($warnings.Count) { $script:monitorMessage.Text += "`r`n" + ($warnings -join "`r`n") }
        if (-not $script:monitorSnapshot.dark_stabilizer_cycle.supported) {
            $script:monitorMessage.Text += "`r`nCycle: $($script:monitorSnapshot.dark_stabilizer_cycle.error)"
        }
        if ($script:monitorSnapshot.action) {
            Show-MonitorNotice $script:monitorMessage.Text
        }
    } catch {
        $script:monitorSnapshot = $null
        $script:monitorControls.preset.SelectedIndex = -1
        Show-MonitorNotice "Monitor error: $($_.Exception.Message)" ($script:monitorOperation -eq "dark_stabilizer_cycle")
    } finally {
        $script:monitorJob = $null
        $script:monitorOperation = $null
        Set-MonitorEnabled
    }
}
$script:monitorControls.preset.Add_SelectedIndexChanged({ Set-MonitorEnabled })
Show-Page "Status"

$script:quit = $false
function Show-DeskFromTray {
    $p = [System.Windows.Forms.Cursor]::Position
    $wa = [System.Windows.Forms.Screen]::FromPoint($p).WorkingArea
    $x = $p.X - [int]($f.Width / 2)
    $y = $p.Y - $f.Height - 8
    if ($x + $f.Width -gt $wa.Right) { $x = $wa.Right - $f.Width }
    if ($x -lt $wa.Left) { $x = $wa.Left }
    if ($y -lt $wa.Top) { $y = [Math]::Min($p.Y + 8, $wa.Bottom - $f.Height) }
    $f.Location = New-Object System.Drawing.Point($x, $y)
    $f.ShowInTaskbar = $true
    $f.WindowState = "Normal"
    $f.Show()
    $f.Activate()
}
$script:ni = New-Object System.Windows.Forms.NotifyIcon
$script:ni.Icon = $deskIcon
$script:ni.Text = "GodBrain"
$script:ni.Visible = $true
$script:ni.Add_MouseUp({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left -or
        $e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
        Show-DeskFromTray
    }
})
$f.Add_FormClosing({
    if (-not $script:quit) {
        $_.Cancel = $true
        $f.ShowInTaskbar = $false
        $f.Hide()
    }
})

$f.Show()
try {
    Register-MonitorHotkey
    [System.Windows.Forms.Application]::Run($f)
} finally {
    try { $script:monitorHotkey.Dispose() }
    catch { Write-Error "Monitor hotkey cleanup failed: $($_.Exception.Message)" -ErrorAction Continue }
    $timer.Stop()
    $timer.Dispose()
    $script:statusWorker.Stop()
    $script:statusWorker.Dispose()
    $script:askWorker.Stop()
    $script:askWorker.Dispose()
    $script:monitorWorker.Stop()
    $script:monitorWorker.Dispose()
    if ($script:ni) {
        $script:ni.Visible = $false
        $script:ni.Dispose()
    }
}
