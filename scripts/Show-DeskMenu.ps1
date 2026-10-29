# One window for the doors already on this machine.
# Status: each service has Start and Stop. Rate and GPU are readouts.
# STT/TTS is the CPU voice door on :8001. The 27B vision tower stays off
# unless the model page checkbox is saved and that model is started.
# Model page selects the Qwen EXL3 models or Qwen-Image-2.1. Status starts that pick.
# Clips page runs the deadtime scan. Lyrics starts capture, waits for loopback,
# waits the preroll, then Shift+P into the running ncspot.
# Stop holds kernel and RAG against Watch (logs/*-pause.txt) until Start.
# Tailscale Start reconnects the existing node. Legacy llama hold does not control Qwen.
[CmdletBinding()]
param(
    [switch]$Status,
    [switch]$ControlPanelHost,
    [switch]$StatusSnapshot,
    [object]$TokenSample,
    [object]$AskRequest,
    [object]$MonitorRequest,
    [object]$DisplayRequest,
    [ValidateSet('Start', 'Stop', 'Open')]
    [string]$AirPlayRequest,
    [ValidateSet('Start', 'Stop', 'Inbox', 'Library', 'Copy', 'Login')]
    [string]$ClipShareRequest
)

$ErrorActionPreference = "Stop"
$Kit = "C:\nvme\Qwen3.8-27B-16gb"
$Start27 = Join-Path $Kit "paper-godbrain\Start-Qwen.ps1"
$StartUncensored = Join-Path $Kit "paper-godbrain\Start-UncensoredQwen.ps1"
$StopModel = Join-Path $Kit "paper-godbrain\Stop-Qwen.ps1"
$Repo = Split-Path $PSScriptRoot -Parent
$StartVl = Join-Path $Repo "scripts\Start-QwenVL.ps1"
$StartImage = Join-Path $Repo "scripts\Start-QwenImage.ps1"
$StartQfn = Join-Path $Repo "scripts\Start-QwenFlashNext.ps1"
$Lyrics = Join-Path $Repo "scripts\Invoke-LyricsLoop.ps1"
$Pwsh = "C:\pwsh\pwsh.exe"
$cs2Helper = Join-Path $Repo "GodBrain-Cs2.ps1"
if (Test-Path -LiteralPath $cs2Helper) { . $cs2Helper }
$mouthHelper = Join-Path $PSScriptRoot "GodBrain-Mouth.ps1"
if (Test-Path -LiteralPath $mouthHelper) { . $mouthHelper }
. (Join-Path $PSScriptRoot "GodBrain-HostServices.ps1")
. (Join-Path $PSScriptRoot "GodBrain-DeskModel.ps1")
. (Join-Path $PSScriptRoot "GodBrain-DeskMonitor.ps1")
. (Join-Path $PSScriptRoot "GodBrain-DisplayProfiles.ps1")
. (Join-Path $PSScriptRoot "GodBrain-AirPlay.ps1")
. (Join-Path $PSScriptRoot "GodBrain-ClipShare.ps1")
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

function Open-DeskListenerProcess([uint32]$ProcessId) {
    Initialize-GodBrainAirPlayWindow
    return [GodBrain.AirPlayProcessHandle]::Open($ProcessId)
}

function Stop-OwnedListener([int]$Port, [string]$Needle, [string]$Label) {
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $conn) {
        $null = [System.Windows.Forms.MessageBox]::Show("$Label is already down.")
        return $false
    }
    $handle = $null
    try {
        $handle = Open-DeskListenerProcess ([uint32]$conn.OwningProcess)
        $image = [IO.Path]::GetFullPath($handle.ExecutablePath)
        $root = [IO.Path]::GetFullPath($Repo).TrimEnd('\') + '\'
        if ([IO.Path]::GetFileName($image) -ine $Needle -or
            -not $image.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
            $null = [System.Windows.Forms.MessageBox]::Show(
                "$Label on :$Port is not the GodBrain process. Leaving it alone.`n$image")
            return $false
        }
        Set-DeskPause ($Label.ToLowerInvariant())
        Stop-Process -Id ([int]$conn.OwningProcess) -Force -ErrorAction Stop
        if (-not $handle.WaitForExit(3000)) { throw "$Label did not exit within three seconds." }
        return $true
    } catch {
        $failure = $_.Exception.GetBaseException()
        $detail = $failure.Message
        if ($failure -is [ComponentModel.Win32Exception] -and $failure.NativeErrorCode -eq 5) {
            $detail = "Windows denied process access. The listener may be elevated; use a Desk at matching privilege to stop it."
        }
        $null = [System.Windows.Forms.MessageBox]::Show(
            "$Label stop failed for PID $($conn.OwningProcess) on :${Port}: $detail`nNo other process was targeted.")
        return $false
    } finally {
        if ($handle) { $handle.Dispose() }
    }
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
    $mouth = "legacy llama :8000 hold unread"
    $mf = Join-Path $Repo "logs\mouth-pause.txt"
    if (Test-Path $mf) { $mouth = "legacy llama :8000 hold $((Get-Content $mf -Raw).Trim())" }
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
        ("AirPlay {0}" -f (Get-GodBrainAirPlayLine))
        ("ClipShare {0}" -f (Get-GodBrainClipShareLine))
    ) -join "`r`n"
}

function Get-DeskSnapshot {
    $mouth = if (Get-Command Test-GodBrainMouthPaused -ErrorAction SilentlyContinue) {
        if (Test-GodBrainMouthPaused $Repo) { "hold on" } else { "hold off" }
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
        AirPlay = Get-GodBrainAirPlayLine
        ClipShare = Get-GodBrainClipShareLine
    }
    $modelConfig = "Live context/MTP unavailable"
    try {
        if (Test-Port 8888) {
            $health = Invoke-RestMethod "http://127.0.0.1:8888/health" -TimeoutSec 2
            $draft = if ($health.drafting.mode -eq "none") { "off" } else { "$($health.drafting.mode)/$($health.drafting.num_draft_tokens)" }
            $modelConfig = "Live: ctx=$($health.context_length)  KV=$($health.cache_quant)  draft=$draft  vision=$($health.vision)"
        } elseif (Test-Port 8871) { $modelConfig = "Live: image diffusion; no token context/MTP" }
        else {
            $modelConfig = "Live: text/image model down"
            $launch = Read-DeskQfnLaunchStatus
            if ($launch) {
                $modelConfig = "Last QFN launch ($($launch.state)): $($launch.message)"
                if ($launch.state -eq "failed") { $rows.Model = "Qwen3.8-Flash-Next failed (see Model)" }
                elseif ($launch.state -in @("checking", "loading")) { $rows.Model = "Qwen3.8-Flash-Next $($launch.state)" }
            }
        }
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

function Get-DeskAttachmentPaths([object[]]$Paths) {
    $result = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($value in $Paths) {
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) { throw "Each attachment needs a file path." }
        $path = ConvertTo-DeskAskPath $value
        if (-not (Test-DeskGrantedPath $path)) { throw "Attachment is outside the kernel file jail: $path" }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Attachment is not a readable file: $path" }
        if ($seen.Add($path)) { $result.Add($path) }
    }
    if ($result.Count -gt 8) { throw "Attach at most eight files per analysis." }
    return ,$result.ToArray()
}

function Invoke-DeskVisionAsk([string]$Path, [string]$Text,
    [ValidateSet("answer", "research", "fix")][string]$Mode = "answer") {
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
    $operatorText = $Text
    $memory = $null
    if ($Mode -ne "answer" -and $Text -notmatch '^\s*(?i)no tools\b') {
        $memory = Get-GodBrainSharedContext -Query $Text -ThreadId "desk"
        $Text = Add-GodBrainSharedContext $Text $memory
    }
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
        tool_choice = "none"
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
    if ($res.error -or @($res.choices).Count -ne 1 -or $res.choices[0].finish_reason -cne "stop") {
        throw "The vision tower did not return one complete answer."
    }
    $choice = $res.choices[0].message
    $answer = $choice.content
    if ($choice.tool_calls -or $answer -isnot [string] -or [string]::IsNullOrWhiteSpace($answer)) {
        throw "The vision tower returned no plain-text answer."
    }
    if ($null -ne $memory) {
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
            [Convert]::FromBase64String($encoded))).ToLowerInvariant()
        $null = Save-GodBrainWorkingTurn -Prompt $operatorText -Response $answer -ThreadId "desk" `
            -Sources @("$Path [vision_payload_sha256=$hash; source bytes not archived]")
    }
    return $answer.Trim()
}

function Invoke-DeskAsk($Request) {
    $text = [string]$Request.Message
    $mode = "research"
    if ($Request.PSObject.Properties["Mode"]) { $mode = ([string]$Request.Mode).ToLowerInvariant() }
    if ($mode -notin @("answer", "research", "fix")) { throw "Select Answer, Research or Fix mode." }
    if ($text -match '^\s*(?i)no tools\b') { $mode = "answer" }
    if ($text.Trim() -match '^(?i)/?index$' -and -not $Request.Path -and -not $Request.Attachments) {
        return (Update-GodBrainContextIndex).response
    }
    $yoloOrJudge = $text.Trim() -match '^(?i)/(?:yolo|verify|reject)\b'
    $path = ConvertTo-DeskAskPath ([string]$Request.Path)
    if ($path -and -not (Test-DeskGrantedPath $path)) { throw "That path is outside the kernel file jail ($path)." }
    if ($Request.Attachments) {
        if ($Request.Attachments -isnot [array]) { throw "Attachments must be a list of file paths." }
        if ($yoloOrJudge -or $text.Trim().StartsWith("/")) { throw "Remove attachments before sending a slash command." }
        if ($mode -eq "fix") { throw "Attachment analysis is read-only. Select Answer or Research; remove attachments for Fix." }
        if ($Request.ImageModel -or (Test-Port 8871)) { throw "Attachment analysis requires a text model, not Qwen-Image generation." }
        $paths = @($Request.Attachments)
        if ($path) {
            if (Test-Path -LiteralPath $path -PathType Leaf) { $paths = @($path) + $paths }
            elseif (-not (Test-Path -LiteralPath $path -PathType Container)) { throw "The optional scope path does not exist: $path" }
        }
        $paths = Get-DeskAttachmentPaths $paths
        $busy = Test-GenerateBusy
        if ($null -eq $busy) { throw "Kernel status is down, so Ask cannot tell if the GPU slot is free." }
        if ($busy) { throw "A generate is already running (one GPU slot). Wait." }
        return (Invoke-DeskAttachmentAnalysis $paths $text $mode)
    }
    if (-not $yoloOrJudge -and $path -and -not $Request.ImageModel -and -not (Test-Port 8871) -and (Test-DeskVisionImage $path)) {
        return (Invoke-DeskVisionAsk $path $text $mode)
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
    if ($completeReview) { return (Invoke-DeskCodeReview $path $text $mode) }
    $writeSlash = Test-DeskWriteSlash $text
    if ($yoloOrJudge) {
        $text = $text.Trim()
    } elseif ($path) {
        if ([string]::IsNullOrWhiteSpace($text)) { $text = "Read this path and say what the file or folder is." }
        $text = "Path: $path`n`n$text"
    }
    $body = @{ message = $text; tool_mode = $mode } | ConvertTo-Json -Compress
    $chat = @{
        Uri = "http://127.0.0.1:8083/api/chat"
        Method = "Post"
        Body = $body
        ContentType = "application/json; charset=utf-8"
        TimeoutSec = 600
    }
    if (-not [string]::IsNullOrWhiteSpace($env:GODBRAIN_API_TOKEN)) {
        $chat.Headers = @{ Authorization = "Bearer " + $env:GODBRAIN_API_TOKEN }
    }
    $res = Invoke-RestMethod @chat
    if ($res.response) {
        if ($res.request_receipt) {
            $receipt = $res.request_receipt
            $attempts = @($receipt.tool_attempts)
            $callCount = [int](($attempts | Measure-Object -Property requested_calls -Sum).Sum)
            $failedCount = @($attempts | Where-Object { $_.executor_ok -eq $false }).Count
            $names = @($attempts | ForEach-Object { $_.requested_tool_names } | Sort-Object -Unique)
            $notice = "Mode: $($receipt.tool_mode); model tool attempts: $callCount"
            if ($names.Count) { $notice += " ($($names -join ', '))" }
            if ($failedCount) { $notice += "; $failedCount failed attempt(s), evidence incomplete" }
            if ($receipt.answer_retry) { $notice += "; answer retry: thinking off (saved preference unchanged)" }
            return "[$notice]`r`n`r`n$($res.response)"
        }
        return [string]$res.response
    }
    if ($res.error) { throw ([string]$res.error) }
    throw "Kernel returned no chat response."
}

if ($ClipShareRequest) {
    Invoke-GodBrainClipShare -Action $ClipShareRequest
    return
}

if ($AirPlayRequest) {
    Invoke-GodBrainAirPlay -Action $AirPlayRequest
    return
}

if ($DisplayRequest) {
    Invoke-DisplayProfiles -Operation $DisplayRequest.Operation -Name $DisplayRequest.Name `
        -Hotkey $DisplayRequest.Hotkey -Overwrite:$DisplayRequest.Overwrite -RepoRoot $Repo
    return
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
    [void](Stop-DeskQfnLauncher)
    & $Pwsh -NoProfile -File $StopModel
    if ($LASTEXITCODE -ne 0) { throw "The model stop failed; the replacement was not started." }
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
        "qfn" { return $StartQfn }
        default { return $Start27 }
    }
}

function Stop-ActiveModel {
    if (Test-Port 8871) {
        Stop-ImageDoor
        return
    }
    $qfnLoading = @(Get-DeskQfnLaunchers).Count -gt 0
    if (-not (Test-Port 8888) -and -not $qfnLoading) {
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
    if (Stop-DeskQfnLauncher) { Update-Status; return }
    & $Pwsh -NoProfile -File $StopModel
    Update-Status
}

function Start-ImageDoor {
    if (Test-Port 8871) {
        [System.Windows.Forms.MessageBox]::Show("Qwen-Image-2.1 is already up on :8871.")
        return
    }
    if (-not (Test-Port 8888) -and @(Get-DeskQfnLaunchers).Count) {
        if (-not (Confirm-Stop "Stop the loading Flash Next model so Qwen-Image-2.1 can take the GPU slot?" "Model")) { return }
        [void](Stop-DeskQfnLauncher)
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
        [void](Stop-DeskQfnLauncher)
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
        if ($script:modelPick -eq "qfn") {
            Test-DeskQfnPrerequisites $profile
            if (@(Get-DeskQfnLaunchers).Count) { throw "Flash Next is already loading/running. Use Stop before starting it again." }
        }
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
    try {
        if (-not (Stop-Door)) { return }
        if ($script:modelPick -eq "qfn") {
            Start-HiddenPwsh (@("-NoProfile", "-File", ('"' + (Get-ModelPickFile) + '"'), "-DeskLaunch") + $options)
        } else { Start-Door (Get-ModelPickFile) $options }
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Model was not started: $($_.Exception.Message)")
    }
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

function Start-AirPlayOperation([string]$Action) {
    if ($script:airPlayJob) { return }
    if ($Action -eq 'Stop' -and -not (Confirm-Stop 'Stop the AirPlay receiver? Playback from connected devices will end.' 'AirPlay')) { return }
    $script:airPlayWorker.Commands.Clear()
    $script:airPlayWorker.Streams.Error.Clear()
    [void]$script:airPlayWorker.AddCommand($PSCommandPath).AddParameter('AirPlayRequest', $Action)
    $script:airPlayJob = $script:airPlayWorker.BeginInvoke()
    foreach ($button in $script:airPlayButtons.Values) { $button.Enabled = $false }
    $rowAirPlay.Text = "$Action in progress..."
}

function Update-AirPlayOperation {
    if (-not $script:airPlayJob -or -not $script:airPlayJob.IsCompleted) { return }
    $job = $script:airPlayJob
    $script:airPlayJob = $null
    try {
        $result = @($script:airPlayWorker.EndInvoke($job))
        if ($script:airPlayWorker.HadErrors -or $result.Count -ne 1) { throw 'AirPlay operation returned no valid result.' }
        $rowAirPlay.Text = [string]$result[0]
    } catch {
        $rowAirPlay.Text = 'AirPlay operation failed'
        [System.Windows.Forms.MessageBox]::Show($_.Exception.GetBaseException().Message, 'AirPlay')
    } finally {
        foreach ($button in $script:airPlayButtons.Values) { $button.Enabled = $true }
        Update-Status
    }
}

function Start-ClipShareOperation([string]$Action) {
    if ($script:clipShareJob) { return }
    if ($Action -eq 'Stop' -and -not (Confirm-Stop 'Stop ClipShare? Active playback ends and an in-progress conversion is cancelled; originals remain untouched.' 'ClipShare')) { return }
    $script:clipShareWorker.Commands.Clear()
    $script:clipShareWorker.Streams.Error.Clear()
    [void]$script:clipShareWorker.AddCommand($PSCommandPath).AddParameter('ClipShareRequest', $Action)
    $script:clipShareJob = $script:clipShareWorker.BeginInvoke()
    foreach ($button in $script:clipShareButtons) { $button.Enabled = $false }
    $rowClipShare.Text = "$Action in progress..."
    $script:clipShareMessage.Text = "$Action in progress..."
}

function Update-ClipShareOperation {
    if (-not $script:clipShareJob -or -not $script:clipShareJob.IsCompleted) { return }
    $job = $script:clipShareJob
    $script:clipShareJob = $null
    try {
        $result = @($script:clipShareWorker.EndInvoke($job))
        if ($script:clipShareWorker.HadErrors -or $result.Count -ne 1) {
            $details = ($script:clipShareWorker.Streams.Error | Out-String).Trim()
            throw "ClipShare returned no valid operation receipt. $details"
        }
        $script:clipShareMessage.Text = [string]$result[0]
    } catch {
        $script:clipShareMessage.Text = $_.Exception.Message
        [System.Windows.Forms.MessageBox]::Show($_.Exception.GetBaseException().Message, 'ClipShare')
    } finally {
        foreach ($button in $script:clipShareButtons) { $button.Enabled = $true }
        Update-Status
    }
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
    if (-not (Confirm-Stop "Hold legacy llama-server startup and stop its :8000 process? Qwen (:8888) and Qwen-Image (:8871) are unchanged." "Legacy llama :8000")) { return }
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

function Show-MouthHoldInfo {
    [System.Windows.Forms.MessageBox]::Show(
        "Choose a text Qwen profile on the Model page, then use Status > Model > Start for AI answers on :8888. Qwen-Image (:8871) is image-only.`r`n`r`nThis row is only the legacy llama-server :8000 startup hold. Info starts nothing. Hold does not stop the selected desk model.",
        "Legacy llama :8000")
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
    readonly uint modifiers;
    bool disposed;
    public bool Registered { get; private set; }
    public int RegistrationError { get; private set; }
    public event EventHandler Pressed;
    public DeskMonitorHotkey(uint key) : this(key, 0) {}
    public DeskMonitorHotkey(uint key, uint modifiers) {
        this.key = key;
        this.modifiers = modifiers;
        CreateHandle(new CreateParams {
            Caption = "GodBrain Monitor Hotkey", Parent = new IntPtr(-3)
        });
    }
    public bool Register() {
        if (disposed) throw new ObjectDisposedException("DeskMonitorHotkey");
        if (Registered) return true;
        Registered = RegisterHotKey(Handle, 1, modifiers | 0x4000, key); // MOD_NOREPEAT
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
$f.ClientSize = New-Object System.Drawing.Size((52 + $script:pageW), 672)
$f.StartPosition = "CenterScreen"
$f.BackColor = $bg
$f.ForeColor = $ink
$f.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$f.Icon = $deskIcon
$f.MinimumSize = $f.Size

$rail = New-Object System.Windows.Forms.Panel
$rail.Location = New-Object System.Drawing.Point(0, 0)
$rail.Size = New-Object System.Drawing.Size(52, 644)
$rail.Anchor = "Top, Bottom, Left"
$rail.BackColor = $railBg
$f.Controls.Add($rail)

$pages = @{}
function New-Page {
    $p = New-Object System.Windows.Forms.Panel
    $p.Location = New-Object System.Drawing.Point(52, 0)
    $p.Size = New-Object System.Drawing.Size($script:pageW, 644)
    $p.Anchor = "Top, Bottom, Left, Right"
    $p.BackColor = $bg
    $p.Visible = $false
    $f.Controls.Add($p)
    return $p
}
$pageStatus = New-Page
$pageModel = New-Page
$pageAsk = New-Page
$pageAsk.Height = $f.ClientSize.Height
$pageLyrics = New-Page
$pageClips = New-Page
$pageMonitor = New-Page
$pageDisplayLayouts = New-Page
$pageShare = New-Page
$pages.Status = $pageStatus
$pages.Model = $pageModel
$pages.Ask = $pageAsk
$pages.Lyrics = $pageLyrics
$pages.Clips = $pageClips
$pages.Monitor = $pageMonitor
$pages.Layouts = $pageDisplayLayouts
$pages.Share = $pageShare

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
        $on = $item.Name -eq $name -or ($item.Name -eq "Monitor" -and $name -eq "Layouts")
        $item.Mark.Visible = $on
        $item.Button.ForeColor = $(if ($on) { $ink } else { $mute })
    }
    if ($name -eq "Model" -and $script:modelReasoning) { Show-DeskReasoningPreference }
    if ($name -eq "Monitor" -and -not $script:monitorSnapshot -and -not $script:monitorJob) {
        Start-MonitorOperation "read"
    }
    if ($name -eq "Layouts" -and -not $script:displaySnapshot -and -not $script:displayJob) {
        Start-DisplayOperation "list"
    }
}

# Gauge, sun, chat, music, video. Same rail idea as the sky strip.
Add-Rail "Status" ([char]0xE9D9) 16
Add-Rail "Model" ([char]0xE706) 64
Add-Rail "Ask" ([char]0xE8BD) 112
Add-Rail "Lyrics" ([char]0xE189) 160
Add-Rail "Clips" ([char]0xE714) 208
Add-Rail "Share" ([char]0xE72D) 248
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
    $v.Anchor = "Top, Left, Right"
    $parent.Controls.Add($l)
    $parent.Controls.Add($v)
    return $v
}

function Add-Pair([System.Windows.Forms.Control]$parent, [string]$name, [int]$y, [scriptblock]$start, [scriptblock]$stop, [string]$startText = "Start", [string]$stopText = "Stop") {
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
    $v.Anchor = "Top, Left, Right"
    $parent.Controls.Add($l)
    $parent.Controls.Add($v)
    $small = New-Object System.Drawing.Font("Segoe UI", 8)
    foreach ($pair in @(
            @{ Text = $startText; X = 432; Primary = $true; Click = $start },
            @{ Text = $stopText; X = 510; Primary = $false; Click = $stop }
        )) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $pair.Text
        $b.Font = $small
        $b.Location = New-Object System.Drawing.Point([int]$pair.X, ($y - 2))
        $b.Size = New-Object System.Drawing.Size(70, 24)
        $b.Anchor = "Top, Right"
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
($pageStatus.Controls | Where-Object { $_ -is [Windows.Forms.Button] -and $_.Text -eq "Galaxy" }).Anchor = "Top, Right"
$rowModel = Add-Pair $pageStatus "Model" 48 { Start-SelectedModel } { Stop-ActiveModel }
$rowGpu = Add-Row $pageStatus "GPU" 80
$rowTok = Add-Row $pageStatus "Rate" 112
$rowKernel = Add-Pair $pageStatus "Kernel" 144 { Start-DeskListener "kernel" } {
    if (-not (Confirm-Stop "Stop the kernel on :8083 so the exe can be rebuilt? Watch leaves it down until you press Start." "Kernel")) { return }
    if (Stop-OwnedListener 8083 "godbrain-kernel.exe" "Kernel") {
        Update-Status
    }
}
$rowRag = Add-Pair $pageStatus "RAG" 176 { Start-DeskListener "rag" } {
    if (-not (Confirm-Stop "Stop rag-service on :8084 so the exe can be rebuilt? Watch leaves it down until you press Start." "RAG")) { return }
    if (Stop-OwnedListener 8084 "rag-service.exe" "RAG") {
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
$rowMouth = Add-Pair $pageStatus "Llama :8000" 304 { Show-MouthHoldInfo } { Stop-MouthHold } -startText "Info" -stopText "Hold"
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
$rowWhisper = Add-Pair $pageStatus "Speech/OCR" 528 { Start-VoiceDoor } { Stop-VoiceDoor }
$script:airPlayWorker = [PowerShell]::Create()
$script:airPlayJob = $null
$script:airPlayButtons = [ordered]@{}
$rowAirPlay = Add-Pair $pageStatus "AirPlay" 560 { Start-AirPlayOperation 'Start' } { Start-AirPlayOperation 'Stop' }
$rowAirPlay.Width = 246
foreach ($button in @($pageStatus.Controls | Where-Object { $_ -is [Windows.Forms.Button] -and $_.Top -eq 558 })) {
    $script:airPlayButtons[$button.Text] = $button
}
$airPlayOpen = New-Object System.Windows.Forms.Button
$airPlayOpen.Text = 'Open'
$airPlayOpen.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$airPlayOpen.Location = [Drawing.Point]::new(354, 558)
$airPlayOpen.Size = [Drawing.Size]::new(70, 24)
$airPlayOpen.Anchor = "Top, Right"
Paint-Button $airPlayOpen $false
$airPlayOpen.Add_Click({ Start-AirPlayOperation 'Open' })
$pageStatus.Controls.Add($airPlayOpen)
$script:airPlayButtons.Open = $airPlayOpen
$script:clipShareWorker = [PowerShell]::Create()
$script:clipShareJob = $null
$script:clipShareButtons = @()
$rowClipShare = Add-Pair $pageStatus "ClipShare" 592 { Start-ClipShareOperation 'Start' } { Start-ClipShareOperation 'Stop' }
foreach ($button in @($pageStatus.Controls | Where-Object { $_ -is [Windows.Forms.Button] -and $_.Top -eq 590 })) {
    $script:clipShareButtons += $button
}
$afkGym = New-Object System.Windows.Forms.CheckBox
$afkGym.Text = "Recover Qwen + gym while AFK (opt-in)"
$afkGym.Location = New-Object System.Drawing.Point(16, 616)
$afkGym.Size = New-Object System.Drawing.Size(($script:pageW - 32), 24)
$afkGym.Anchor = "Top, Left, Right"
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
    Serve = $rowServe; Watch = $rowWatch; Web = $rowWeb; Whisper = $rowWhisper; AirPlay = $rowAirPlay; ClipShare = $rowClipShare
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
                if ($entry.Key -eq 'AirPlay' -and $script:airPlayJob) { continue }
                if ($entry.Key -eq 'ClipShare' -and $script:clipShareJob) { continue }
                $entry.Value.Text = [string]$snapshot.Rows.($entry.Key)
                $script:statusTip.SetToolTip($entry.Value, $entry.Value.Text)
                if ($entry.Key -eq 'ClipShare') { $script:clipShareStatus.Text = $entry.Value.Text }
            }
            $script:tokSample = $snapshot.TokenSample
            if ($script:modelLive) {
                $script:modelLive.Text = [string]$snapshot.ModelConfig
                $script:statusTip.SetToolTip($script:modelLive, $script:modelLive.Text)
            }
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
$timer.Add_Tick({ Update-Status -Poll; Update-Ask; Update-Monitor; Update-DisplayOperation; Update-AirPlayOperation; Update-ClipShareOperation })
$timer.Start()

Add-Head $pageShare "ClipShare" 16
$script:clipShareStatus = New-Object System.Windows.Forms.Label
$script:clipShareStatus.Location = [Drawing.Point]::new(20, 54)
$script:clipShareStatus.Size = [Drawing.Size]::new(($script:pageW - 40), 40)
$script:clipShareStatus.Anchor = "Top, Left, Right"
$script:clipShareStatus.Text = 'Reading status...'
$pageShare.Controls.Add($script:clipShareStatus)
foreach ($item in @(
    @{Text='Start'; Action='Start'; X=20; Y=104},
    @{Text='Stop'; Action='Stop'; X=200; Y=104},
    @{Text='Inbox'; Action='Inbox'; X=20; Y=152},
    @{Text='Library'; Action='Library'; X=200; Y=152},
    @{Text='Copy link'; Action='Copy'; X=20; Y=200},
    @{Text='Copy login'; Action='Login'; X=200; Y=200}
)) {
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $item.Text
    $button.Tag = $item.Action
    $button.Location = [Drawing.Point]::new($item.X, $item.Y)
    $button.Size = [Drawing.Size]::new(160, 34)
    Paint-Button $button ($item.Action -eq 'Start')
    $button.Add_Click({ param($sender, $event); Start-ClipShareOperation ([string]$sender.Tag) })
    $pageShare.Controls.Add($button)
    $script:clipShareButtons += $button
}
$script:clipShareMessage = New-Object System.Windows.Forms.Label
$script:clipShareMessage.Location = [Drawing.Point]::new(20, 252)
$script:clipShareMessage.Size = [Drawing.Size]::new(($script:pageW - 40), 80)
$script:clipShareMessage.Text = 'Drop downloaded clips/audio into Inbox. Copy link uses the latest completed share.'
$pageShare.Controls.Add($script:clipShareMessage)
$shareHint = New-Object System.Windows.Forms.Label
$shareHint.Location = [Drawing.Point]::new(20, 348)
$shareHint.Size = [Drawing.Size]::new(($script:pageW - 40), 180)
$shareHint.ForeColor = $mute
$shareHint.Text = "Background user app, not a Windows service. Closing Desk leaves it running.`r`n`r`nLibrary login: owner (Copy login copies its password). Originals stay in Inbox. Conversion is serial, CPU-only.`r`n`r`nDefault is local-only on 127.0.0.1:3923. External HTTPS is not configured automatically. Share links expire after 7 days; files are not auto-deleted."
$pageShare.Controls.Add($shareHint)

Add-Head $pageModel "Model" 16
$modelHint = New-Object System.Windows.Forms.Label
$modelHint.Text = "Pick one. Status starts and stops it. One GPU slot."
$modelHint.ForeColor = $mute
$modelHint.Location = New-Object System.Drawing.Point(100, 55)
$modelHint.Size = New-Object System.Drawing.Size(($script:pageW - 120), 22)
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
Add-ModelPick "image" "Qwen-Image-2.1" 304 16 272
$exlHeading = [System.Windows.Forms.Label]::new()
$exlHeading.Text = "EXL3"
$exlHeading.Location = [Drawing.Point]::new(20, 55)
$exlHeading.Size = [Drawing.Size]::new(72, 22)
$pageModel.Controls.Add($exlHeading)
Add-ModelPick "27b" "Qwen3.8-27B" 20 80 272
Add-ModelPick "vl" "Qwen3-VL-8B" 304 80 272
Add-ModelPick "uncensored" "Qwen3.8-27B-Uncensored" 20 124 272
Add-ModelPick "qfn" "Qwen3.8-Flash-Next" 304 124 272
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
$script:modelCpuLabel = $pageModel.Controls[$pageModel.Controls.Count - 1]
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
$script:modelSettingsHint.Location = [Drawing.Point]::new(20, 474)
$script:modelSettingsHint.Size = [Drawing.Size]::new(556, 80)
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
    if ($script:modelPick -eq "qfn") { $profile.CpuExperts = $script:modelCpuCache.Text; $profile.CpuCache = "0" }
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
        if ($button.Text -eq "Large text (~70k)") { $button.Enabled = $enabled -and $script:modelPick -in @("27b", "uncensored") }
        if ($button.Text -in @("Max context (kit)", "Quality preset")) {
            $button.Enabled = $enabled -and $script:modelPick -in @("27b", "qfn")
            $button.Text = if ($script:modelPick -eq "qfn") { "Quality preset" } else { "Max context (kit)" }
        }
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
        $script:modelCpuCache.Text = if ($script:modelPick -eq "qfn") { [string]$profile.CpuExperts } elseif ($profile.ContainsKey("CpuCache")) { [string]$profile.CpuCache } else { "0" }
        $script:modelVision.Checked = $script:modelPick -eq "27b" -and $profile.ContainsKey("Vision") -and [bool]$profile.Vision
    } else { $script:modelVision.Checked = $false }
    $script:modelCpuLabel.Text = if ($script:modelPick -eq "qfn") { "CPU experts (400/416/432/448/464)" } else { "RAM prefix cache GiB (reuse only)" }
    $script:modelMtp.Text = if ($script:modelPick -eq "qfn") { "MTP enabled (draft window 3)" } else { "MTP enabled (draft window 4)" }
    $script:modelSettingsHint.Text = if ($script:modelSettingsError) { $script:modelSettingsError } elseif (-not $enabled) {
        "Image diffusion does not have token context or MTP controls."
    } elseif ($script:modelPick -eq "qfn") {
        "3.05 weights unchanged; FP16 KV prioritizes quality, not context.`r`nCPU experts + hot GPU placement; both embeddings stream from disk.`r`n432 CPU needs 43 GiB free RAM; 4 GiB reserve, no RAM prefix tier.`r`nNo silent KV downgrade. Fit is unproven until a real generation."
    } else {
        "~70k: int4 KV, MTP/vision off; unchanged weights. Max is a kit plan.`r`nRAM cache reuses prefixes, not live context. No dense weight spill.`r`nVision/OCR applies on next 27B Start; speech stays CPU.`r`nReasoning applies next request; tools, pictures and /edit stay off."
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
    if ($script:modelPick -eq "qfn" -and -not $script:modelSettingsError) {
        $profile = Get-DeskModelDefaults "qfn"
        $script:modelContext.Text = [string]$profile.Context
        $script:modelCache.SelectedItem = $profile.CacheQuant
        $script:modelMtp.Checked = $profile.Mtp
        $script:modelVision.Checked = $false
        $script:modelBudget.Text = $profile.Budget.ToString([Globalization.CultureInfo]::InvariantCulture)
        $script:modelCpuCache.Text = [string]$profile.CpuExperts
        return
    }
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
Add-ModelLabel "Text reasoning effort (next request; no model restart)" 410
$script:modelReasoning = [Windows.Forms.ComboBox]::new()
$script:modelReasoning.DropDownStyle = "DropDownList"
$script:modelReasoning.Items.AddRange(@("Default (model)", "Off", "Low", "Medium", "High (xhigh)"))
$script:modelReasoning.Location = [Drawing.Point]::new(20, 434)
$script:modelReasoning.Size = [Drawing.Size]::new(168, 26)
$pageModel.Controls.Add($script:modelReasoning)
$script:modelReasoningStatus = [Windows.Forms.Label]::new()
$script:modelReasoningStatus.ForeColor = $mute
$script:modelReasoningStatus.Font = [Drawing.Font]::new("Segoe UI", 9)
$script:modelReasoningStatus.Location = [Drawing.Point]::new(392, 432)
$script:modelReasoningStatus.Size = [Drawing.Size]::new(184, 38)
$pageModel.Controls.Add($script:modelReasoningStatus)
function Show-DeskReasoningPreference {
    try {
        $preference = Read-DeskReasoningPreference (Join-Path $Repo "logs\thinking.txt")
        $script:modelReasoning.SelectedIndex = @("on", "off", "low", "medium", "xhigh").IndexOf($preference.Value)
        $script:modelReasoningStatus.Text = "Saved: $($script:modelReasoning.SelectedItem)"
    } catch {
        $script:modelReasoning.SelectedIndex = -1
        $script:modelReasoningStatus.Text = "Invalid preference; select and apply to repair."
    }
}
function Save-DeskReasoningPreference {
    if ($script:modelReasoning.SelectedIndex -lt 0) { throw "Select a reasoning effort first." }
    $value = @("on", "off", "low", "medium", "xhigh")[$script:modelReasoning.SelectedIndex]
    Write-DeskReasoningPreference (Join-Path $Repo "logs\thinking.txt") $value
    Show-DeskReasoningPreference
}
Add-Button $pageModel "Apply reasoning" 200 430 180 {
    try { Save-DeskReasoningPreference } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message) }
} $true
Show-DeskReasoningPreference

Add-Head $pageAsk "Ask" 16
$fileLabel = New-Object System.Windows.Forms.Label
$fileLabel.Text = "Optional scope / single file / image edit input"
$fileLabel.ForeColor = $mute
$fileLabel.Location = New-Object System.Drawing.Point(20, 44)
$fileLabel.AutoSize = $true
$pageAsk.Controls.Add($fileLabel)
$askPath = New-Object System.Windows.Forms.TextBox
$askPath.Location = New-Object System.Drawing.Point(20, 66)
$askPath.Size = New-Object System.Drawing.Size(($script:pageW - 40), 26)
Style-Box $askPath
$pageAsk.Controls.Add($askPath)
$attachmentLabel = [Windows.Forms.Label]::new()
$attachmentLabel.Text = "Attachments: read-only files / text screenshots (CPU OCR), up to 8"
$attachmentLabel.ForeColor = $mute
$attachmentLabel.Location = [Drawing.Point]::new(20, 102)
$attachmentLabel.AutoSize = $true
$pageAsk.Controls.Add($attachmentLabel)
$askAttachments = [Windows.Forms.ListBox]::new()
$askAttachments.Location = [Drawing.Point]::new(20, 160)
$askAttachments.Size = [Drawing.Size]::new(($script:pageW - 40), 54)
$askAttachments.IntegralHeight = $false
$askAttachments.HorizontalScrollbar = $true
$askAttachments.SelectionMode = "MultiExtended"
$askAttachments.DisplayMember = "Display"
$askAttachments.BackColor = $fieldBg
$askAttachments.ForeColor = $ink
$askAttachments.Anchor = "Top, Left, Right"
$askAttachments.AccessibleName = "Ask attachments"
$askAttachments.AllowDrop = $true
$pageAsk.Controls.Add($askAttachments)
function Add-DeskAskAttachments([string[]]$Paths) {
    if ($script:askJob) { throw "Wait for the current Ask before changing attachments." }
    $paths = Get-DeskAttachmentPaths (@($askAttachments.Items | ForEach-Object Path) + @($Paths))
    $askAttachments.Items.Clear()
    foreach ($path in $paths) {
        [void]$askAttachments.Items.Add([pscustomobject]@{ Path = $path; Display = "$(Split-Path -Leaf $path) - $path" })
    }
}
function Remove-DeskAskAttachments {
    if ($script:askJob) { return }
    foreach ($item in @($askAttachments.SelectedItems)) { $askAttachments.Items.Remove($item) }
}
function Paste-DeskAskImage {
    if ($script:askJob) { return }
    if ($askAttachments.Items.Count -ge 8) { throw "Attach at most eight files per analysis." }
    if (-not [Windows.Forms.Clipboard]::ContainsImage()) { throw "The clipboard does not contain an image." }
    $image = [Windows.Forms.Clipboard]::GetImage()
    $folder = Join-Path $Repo "logs\desk-attachments"
    [void][IO.Directory]::CreateDirectory($folder)
    $path = Join-Path $folder ("clipboard-" + [guid]::NewGuid().ToString("N") + ".png")
    try {
        $image.Save($path, [Drawing.Imaging.ImageFormat]::Png)
        if ((Get-Item -LiteralPath $path).Length -gt 10MB) { throw "Clipboard image exceeds 10 MiB." }
        Add-DeskAskAttachments @($path)
    } catch {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        throw
    } finally { $image.Dispose() }
}
Add-Button $pageAsk "Add files..." 20 122 124 {
    $dialog = [Windows.Forms.OpenFileDialog]::new()
    $dialog.Multiselect = $true
    $dialog.Title = "Attach files to analyse together"
    $dialog.Filter = "Text, scripts, logs and images|*.txt;*.log;*.ps1;*.cmd;*.bat;*.md;*.json;*.csv;*.xml;*.ini;*.cpp;*.h;*.py;*.go;*.rs;*.jpg;*.jpeg;*.png;*.webp;*.gif;*.bmp|All files|*.*"
    try {
        if ($dialog.ShowDialog($f) -eq "OK") { Add-DeskAskAttachments $dialog.FileNames }
    } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message) }
    finally { $dialog.Dispose() }
} $false
Add-Button $pageAsk "Remove" 152 122 104 { Remove-DeskAskAttachments } $false
Add-Button $pageAsk "Paste image" 264 122 136 {
    try { Paste-DeskAskImage } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message) }
} $false
$script:askAttachmentButtons = @($pageAsk.Controls | Where-Object { $_ -is [Windows.Forms.Button] -and $_.Top -eq 122 })
$askAttachments.Add_DragEnter({
    param($sender, $event)
    if (-not $script:askJob -and $event.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) {
        $event.Effect = [Windows.Forms.DragDropEffects]::Copy
    }
})
$askAttachments.Add_DragDrop({
    param($sender, $event)
    try { Add-DeskAskAttachments ($event.Data.GetData([Windows.Forms.DataFormats]::FileDrop)) }
    catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message) }
})
$askAttachments.Add_KeyDown({
    param($sender, $event)
    if ($event.KeyCode -eq "Delete") { Remove-DeskAskAttachments; $event.SuppressKeyPress = $true }
    if ($event.Control -and $event.KeyCode -eq "V") {
        try { Paste-DeskAskImage } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message) }
        $event.SuppressKeyPress = $true
    }
})
$askModeLabel = [Windows.Forms.Label]::new()
$askModeLabel.Text = "Text mode"
$askModeLabel.ForeColor = $mute
$askModeLabel.Location = [Drawing.Point]::new(20, 230)
$askModeLabel.AutoSize = $true
$pageAsk.Controls.Add($askModeLabel)
$askMode = [Windows.Forms.ComboBox]::new()
$askMode.DropDownStyle = "DropDownList"
$askMode.Location = [Drawing.Point]::new(126, 226)
$askMode.Size = [Drawing.Size]::new(($script:pageW - 146), 28)
[void]$askMode.Items.AddRange(@("Answer (no model tools)", "Research (read-only)", "Fix (scoped tools)"))
$askMode.SelectedIndex = 1
$askMode.AccessibleName = "Ask text tool mode"
$askMode.Anchor = "Top, Left, Right"
$pageAsk.Controls.Add($askMode)
$askSplit = [System.Windows.Forms.SplitContainer]::new()
$askSplit.Orientation = "Horizontal"
$askSplit.Location = [Drawing.Point]::new(20, 260)
$askSplit.Size = [Drawing.Size]::new(($script:pageW - 40), ($pageAsk.ClientSize.Height - 280))
$askSplit.SplitterWidth = 8
$askSplit.SplitterDistance = 80
$askSplit.Panel1MinSize = 80
$askSplit.Panel2MinSize = 96
$askSplit.FixedPanel = "Panel1"
$askSplit.Anchor = "Top, Bottom, Left, Right"
$askSplit.AccessibleName = "Prompt and answer divider"
$pageAsk.Controls.Add($askSplit)
$prompt = New-Object System.Windows.Forms.TextBox
$prompt.Multiline = $true
$prompt.ScrollBars = "Vertical"
$prompt.Location = [Drawing.Point]::new(0, 0)
$prompt.Size = [Drawing.Size]::new(($askSplit.Panel1.ClientSize.Width - 112), 52)
Style-Box $prompt
$askSplit.Panel1.Controls.Add($prompt)
$script:askWorker = [PowerShell]::Create()
$script:askJob = $null
$send = New-Object System.Windows.Forms.Button
$send.Text = "Send"
$send.Location = [Drawing.Point]::new(($askSplit.Panel1.ClientSize.Width - 104), 0)
$send.Size = New-Object System.Drawing.Size(104, 34)
Paint-Button $send $true
$send.Add_Click({
    if ($script:askJob) { return }
    $request = [pscustomobject]@{
        Message = [string]$prompt.Text
        Path = [string]$askPath.Text
        ImageModel = ($script:modelPick -eq "image")
        ReviewFile = [bool]$reviewFile.Checked
        Mode = @("answer", "research", "fix")[$askMode.SelectedIndex]
        Attachments = [string[]]@($askAttachments.Items | ForEach-Object Path)
    }
    $reply.Text = "$($askMode.SelectedItem): working..."
    $send.Enabled = $false
    foreach ($control in @($askAttachments) + $script:askAttachmentButtons) { $control.Enabled = $false }
    $script:askWorker.Commands.Clear()
    $script:askWorker.Streams.Error.Clear()
    [void]$script:askWorker.AddCommand($PSCommandPath).AddParameter("AskRequest", $request)
    $script:askJob = $script:askWorker.BeginInvoke()
})
$askSplit.Panel1.Controls.Add($send)
$reviewFile = [System.Windows.Forms.CheckBox]::new()
$reviewFile.Text = "Review complete file (read-only; auto above 128 KiB)"
$reviewFile.ForeColor = $ink
$reviewFile.Location = [Drawing.Point]::new(0, 56)
$reviewFile.Size = [Drawing.Size]::new($askSplit.Panel1.ClientSize.Width, 24)
$askSplit.Panel1.Controls.Add($reviewFile)
function Update-Ask {
    if (-not $script:askJob -or -not $script:askJob.IsCompleted) { return }
    try {
        $result = @($script:askWorker.EndInvoke($script:askJob))
        if ($result.Count -ne 1) { throw "Invalid Ask response." }
        $reply.Text = ([string]$result[0]) -replace "\r?\n", "`r`n"
    } catch {
        $reply.Text = "Error: $($_.Exception.GetBaseException().Message)"
        if ($_.ErrorDetails.Message) { $reply.Text += "`r`n$($_.ErrorDetails.Message)" }
    } finally {
        $script:askJob = $null
        $send.Enabled = $true
        foreach ($control in @($askAttachments) + $script:askAttachmentButtons) { $control.Enabled = $true }
    }
}
$reply = New-Object System.Windows.Forms.TextBox
$reply.Multiline = $true
$reply.ScrollBars = "Vertical"
$reply.Dock = "Fill"
$reply.MaxLength = 0
Style-Box $reply
$askSplit.Panel2.Controls.Add($reply)

$askPath.Anchor = "Top, Left, Right"
$prompt.Anchor = "Top, Bottom, Left, Right"
$reviewFile.Anchor = "Bottom, Left, Right"
$send.Anchor = "Top, Right"

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
Add-Button $pageMonitor "Layouts" 456 12 112 { Show-Page "Layouts" } $false
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
        $control.Minimum = if ($spec.Id -eq "contrast") { 25 } else { 0 }
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
        $enabled = -not $script:monitorJob -and -not $script:displayJob -and $script:monitorSnapshot -and
            $script:monitorSnapshot.$id.supported
        $script:monitorControls[$id].Enabled = [bool]$enabled
        $script:monitorApply[$id].Enabled = [bool]$enabled
        if ($id -eq "preset" -and $script:monitorControls[$id].SelectedIndex -lt 0) {
            $script:monitorApply[$id].Enabled = $false
        }
        Paint-Button $script:monitorApply[$id] $script:monitorApply[$id].Enabled
    }
    $script:monitorRefresh.Enabled = -not $script:monitorJob -and -not $script:displayJob
    $script:monitorCycle.Enabled = -not $script:monitorJob -and -not $script:displayJob -and $script:monitorSnapshot -and
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
    if ($script:displayJob) {
        Show-MonitorNotice "Display layout operation is busy; no monitor command sent or queued." $true
        return
    }
    if ($Control -eq "contrast") {
        try { Assert-DeskMonitorContrast $Value }
        catch {
            Show-MonitorNotice "$($_.Exception.Message) No command sent." $true
            return
        }
    }
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
    Set-DisplayEnabled
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
            if ($id -in @("brightness", "contrast")) {
                $minimum = $script:monitorControls[$id].Minimum
                $script:monitorControls[$id].Value = [Math]::Max($minimum, $state.current)
                if ($state.current -lt $minimum) {
                    $warnings += "Hardware contrast is $($state.current), below the allowed minimum $minimum. The input is $minimum for the next Apply; no setting was changed."
                }
            }
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
        Set-DisplayEnabled
    }
}
$script:monitorControls.preset.Add_SelectedIndexChanged({ Set-MonitorEnabled })

Add-Head $pageDisplayLayouts "Display layouts" 16
Add-Button $pageDisplayLayouts "Dell controls" 428 12 140 { Show-Page "Monitor" } $false
$layoutHint = [Windows.Forms.Label]::new()
$layoutHint.Text = "Save the layout configured in Windows. Apply switches directly to a saved profile, without a Keep popup. Dell picture settings are separate."
$layoutHint.Location = [Drawing.Point]::new(20, 56)
$layoutHint.Size = [Drawing.Size]::new(($script:pageW - 40), 48)
$layoutHint.ForeColor = $mute
$pageDisplayLayouts.Controls.Add($layoutHint)
$script:displayWorker = [PowerShell]::Create()
$script:displayJob = $null
$script:displaySnapshot = $null
$script:displayRequest = $null
$script:displayNotice = "No display layout has been changed."
$script:displayDetailProfile = $null
$script:displayHotkeys = @()
$script:displayHotkeyNames = @{}
$script:displayHotkeyStatus = @()
$script:displayButtons = @{}
foreach ($spec in @(@{ Text = "Profile"; Y = 114 }, @{ Text = "New name"; Y = 162 }, @{ Text = "Hotkey"; Y = 262 })) {
    $label = [Windows.Forms.Label]::new()
    $label.Text = $spec.Text
    $label.Location = [Drawing.Point]::new(20, $spec.Y)
    $label.Size = [Drawing.Size]::new(140, 28)
    $label.ForeColor = $ink
    $pageDisplayLayouts.Controls.Add($label)
}
$script:displayProfilesBox = [Windows.Forms.ComboBox]::new()
$script:displayProfilesBox.DropDownStyle = "DropDownList"
$script:displayProfilesBox.Location = [Drawing.Point]::new(168, 112)
$script:displayProfilesBox.Size = [Drawing.Size]::new(268, 30)
$script:displayProfilesBox.BackColor = $fieldBg
$script:displayProfilesBox.ForeColor = $ink
$pageDisplayLayouts.Controls.Add($script:displayProfilesBox)
$script:displayNameBox = [Windows.Forms.TextBox]::new()
$script:displayNameBox.Location = [Drawing.Point]::new(168, 160)
$script:displayNameBox.Size = [Drawing.Size]::new(268, 30)
Style-Box $script:displayNameBox
$pageDisplayLayouts.Controls.Add($script:displayNameBox)
$script:displayHotkeyBox = [Windows.Forms.ComboBox]::new()
$script:displayHotkeyBox.DropDownStyle = "DropDownList"
$script:displayHotkeyBox.Location = [Drawing.Point]::new(168, 260)
$script:displayHotkeyBox.Size = [Drawing.Size]::new(268, 30)
$script:displayHotkeyBox.BackColor = $fieldBg
$script:displayHotkeyBox.ForeColor = $ink
[void]$script:displayHotkeyBox.Items.Add("None")
foreach ($number in 1..12) { [void]$script:displayHotkeyBox.Items.Add("Ctrl+Alt+F$number") }
$script:displayHotkeyBox.SelectedIndex = 0
$pageDisplayLayouts.Controls.Add($script:displayHotkeyBox)
$script:displayDetails = [Windows.Forms.TextBox]::new()
$script:displayDetails.Multiline = $true
$script:displayDetails.ReadOnly = $true
$script:displayDetails.ScrollBars = "Vertical"
$script:displayDetails.Location = [Drawing.Point]::new(20, 356)
$script:displayDetails.Size = [Drawing.Size]::new(($script:pageW - 40), 232)
$script:displayDetails.Anchor = "Top, Bottom, Left, Right"
Style-Box $script:displayDetails
$pageDisplayLayouts.Controls.Add($script:displayDetails)
foreach ($spec in @(
    @{ Id = "list"; Text = "Refresh"; X = 456; Y = 110; W = 112 },
    @{ Id = "save"; Text = "Capture"; X = 456; Y = 158; W = 112 },
    @{ Id = "preview"; Text = "Preview"; X = 20; Y = 210; W = 120 },
    @{ Id = "apply"; Text = "Apply"; X = 148; Y = 210; W = 120 },
    @{ Id = "overwrite"; Text = "Overwrite"; X = 276; Y = 210; W = 140 },
    @{ Id = "delete"; Text = "Delete"; X = 424; Y = 210; W = 144 },
    @{ Id = "hotkey"; Text = "Set hotkey"; X = 456; Y = 258; W = 112 },
    @{ Id = "current"; Text = "Read current"; X = 20; Y = 308; W = 140 },
    @{ Id = "recover"; Text = "Recover previous layout"; X = 176; Y = 308; W = 244 }
)) {
    $button = [Windows.Forms.Button]::new()
    $button.Text = $spec.Text
    $button.Tag = $spec.Id
    $button.Location = [Drawing.Point]::new($spec.X, $spec.Y)
    $button.Size = [Drawing.Size]::new($spec.W, 34)
    Paint-Button $button ($spec.Id -eq "apply")
    $button.Add_Click({
        param($sender, $event)
        try {
            $operation = [string]$sender.Tag
            $name = $null
            $overwrite = $false
            if ($operation -eq "save") { $name = $script:displayNameBox.Text }
            elseif ($operation -in @("preview", "apply", "overwrite", "delete", "hotkey")) {
                $profile = Get-SelectedDisplayProfile
                if (-not $profile) { throw "Select a display profile first." }
                $name = [string]$profile.name
            }
            if ($operation -in @("overwrite", "delete")) {
                $verb = if ($operation -eq "overwrite") { "Replace" } else { "Delete" }
                if ([Windows.Forms.MessageBox]::Show("$verb GodBrain display profile '$name'? Monitor Profile Switcher's profiles are untouched.",
                        "Display layouts", "YesNo", "Warning", "Button2") -ne "Yes") { return }
                if ($operation -eq "overwrite") { $operation = "save"; $overwrite = $true }
            }
            Start-DisplayOperation $operation $name $script:displayHotkeyBox.SelectedIndex $overwrite
        } catch { $script:displayNotice = "Display layout error: $($_.Exception.Message)"; Update-DisplayDetails }
    })
    $script:displayButtons[$spec.Id] = $button
    $pageDisplayLayouts.Controls.Add($button)
}
function Get-SelectedDisplayProfile {
    $index = $script:displayProfilesBox.SelectedIndex
    if ($script:displaySnapshot -and $index -ge 0 -and $index -lt $script:displaySnapshot.profiles.Count) {
        return $script:displaySnapshot.profiles[$index]
    }
    return $null
}
function Format-DisplayProfile($Profile) {
    $lines = @("Profile: $($Profile.name)")
    foreach ($display in $Profile.displays) {
        $primary = if ($display.primary) { " primary" } else { "" }
        $orientation = @("landscape", "portrait", "landscape flipped", "portrait flipped")[$display.rotation - 1]
        $lines += "$($display.label): $($display.width)x$($display.height), $([Math]::Round($display.refresh_hz, 3)) Hz, $orientation, ($($display.x),$($display.y))$primary"
    }
    return $lines -join "`r`n"
}
function Update-DisplayDetails {
    $lines = @($script:displayNotice)
    if ($script:displaySnapshot.recovery_pending) {
        $lines += "UNFINISHED SWITCH: use Recover previous layout. Other layout changes are blocked."
    }
    $profile = if ($script:displayDetailProfile) { $script:displayDetailProfile } else { Get-SelectedDisplayProfile }
    if ($profile) { $lines += ""; $lines += Format-DisplayProfile $profile }
    if ($script:displayHotkeyStatus.Count) { $lines += ""; $lines += $script:displayHotkeyStatus }
    $script:displayDetails.Text = $lines -join "`r`n"
}
function Clear-DisplayHotkeys {
    foreach ($hotkey in $script:displayHotkeys) { $hotkey.Dispose() }
    $script:displayHotkeys = @()
    $script:displayHotkeyNames = @{}
}
function Register-DisplayHotkeys {
    Clear-DisplayHotkeys
    $script:displayHotkeyStatus = @()
    if ($script:displaySnapshot.recovery_pending) { return }
    foreach ($profile in $script:displaySnapshot.profiles) {
        if ($profile.hotkey -eq 0) { continue }
        $hotkey = [DeskMonitorHotkey]::new([uint32](0x6F + $profile.hotkey), 3)
        $script:displayHotkeys += $hotkey
        $script:displayHotkeyNames[$hotkey.Handle.ToInt64()] = [string]$profile.name
        $hotkey.Add_Pressed({
            param($sender, $event)
            Start-DisplayOperation "apply" $script:displayHotkeyNames[$sender.Handle.ToInt64()]
        })
        if ($hotkey.Register()) { $script:displayHotkeyStatus += "Ctrl+Alt+F$($profile.hotkey): $($profile.name) ready (also while Desk is hidden)." }
        else { $script:displayHotkeyStatus += "Ctrl+Alt+F$($profile.hotkey): unavailable, Windows error $($hotkey.RegistrationError). Release its other owner, then Refresh." }
    }
}
function Set-DisplayEnabled {
    $busy = $script:displayJob -or $script:monitorJob
    $selected = $null -ne (Get-SelectedDisplayProfile)
    $pending = $script:displaySnapshot.recovery_pending
    foreach ($id in $script:displayButtons.Keys) {
        $enabled = -not $busy
        if ($id -in @("preview", "apply", "overwrite", "delete", "hotkey")) { $enabled = $enabled -and $selected }
        if ($pending -and $id -notin @("list", "recover")) { $enabled = $false }
        $script:displayButtons[$id].Enabled = [bool]$enabled
        Paint-Button $script:displayButtons[$id] ($enabled -and $id -eq "apply")
    }
    $script:displayProfilesBox.Enabled = -not $busy
    $script:displayNameBox.Enabled = -not $busy -and -not $pending
    $script:displayHotkeyBox.Enabled = -not $busy -and -not $pending
}
function Start-DisplayOperation([string]$Operation, [string]$Name, [int]$Hotkey = 0, [bool]$Overwrite = $false) {
    try {
        if ($Operation -in @("save", "preview", "apply", "hotkey", "delete")) { Assert-DisplayProfileName $Name }
        if ($script:displayJob -or $script:monitorJob) { throw "Monitor/display operation is busy; no request sent or queued." }
        if ($script:displaySnapshot.recovery_pending -and $Operation -notin @("list", "recover")) {
            throw "An unfinished switch requires Recover previous layout."
        }
        $script:displayWorker.Dispose()
        $script:displayWorker = [PowerShell]::Create()
        $request = [pscustomobject]@{ Operation = $Operation; Name = $Name; Hotkey = $Hotkey; Overwrite = $Overwrite }
        [void]$script:displayWorker.AddCommand($PSCommandPath).AddParameter("DisplayRequest", $request)
        $script:displayRequest = $request
        $script:displayJob = $script:displayWorker.BeginInvoke()
        $script:displayDetailProfile = $null
        $script:displayNotice = if ($Operation -eq "apply") {
            "Switching to saved profile '$Name' without a confirmation popup. Validating and verifying the display configuration."
        } else { "Display layouts: $Operation..." }
    } catch { $script:displayNotice = "Display layout error: $($_.Exception.Message)" }
    Set-DisplayEnabled; Set-MonitorEnabled; Update-DisplayDetails
}
function Update-DisplayOperation {
    if (-not $script:displayJob -or -not $script:displayJob.IsCompleted) { return }
    $refresh = $false
    try {
        $results = @($script:displayWorker.EndInvoke($script:displayJob))
        if ($script:displayWorker.HadErrors) { throw ($script:displayWorker.Streams.Error | Out-String).Trim() }
        if ($results.Count -ne 1) { throw "Invalid display-profile result count." }
        $request = $script:displayRequest
        $result = Assert-DisplayProfileResult $results[0] $request.Operation $request.Name
        if ($request.Operation -eq "list") {
            $selected = [string]$script:displayProfilesBox.Text
            $script:displaySnapshot = $result
            $script:displayProfilesBox.Items.Clear()
            foreach ($profile in $result.profiles) { [void]$script:displayProfilesBox.Items.Add([string]$profile.name) }
            $script:displayProfilesBox.SelectedIndex = -1
            for ($i = 0; $i -lt $result.profiles.Count; $i++) {
                if ($result.profiles[$i].name -eq $selected) { $script:displayProfilesBox.SelectedIndex = $i; break }
            }
            if ($script:displayProfilesBox.SelectedIndex -lt 0 -and $result.profiles.Count) { $script:displayProfilesBox.SelectedIndex = 0 }
            Register-DisplayHotkeys
            $script:displayNotice = if ($script:displayLastNotice) { $script:displayLastNotice } else { "$($result.profiles.Count) GodBrain profiles. No layout change requested." }
            $script:displayLastNotice = $null
        } else {
            $script:displayNotice = switch ($request.Operation) {
                "apply" {
                    if ($result.confirmation -ceq "saved_profile") { "Applied '$($result.profile.name)' without a confirmation popup. Live and saved display configuration verified." }
                    else { "Layout $($result.outcome) ($($result.confirmation)). Actual display configuration verified." }
                }
                "recover" { "Previous layout restored and verified." }
                "save" { "Captured '$($result.profile.name)'. No display settings changed." }
                "preview" { "Validated without applying." }
                "current" { "Current Windows layout, read-only." }
                "hotkey" { "Saved hotkey for '$($result.profile.name)'." }
                "delete" { "Deleted only GodBrain profile '$($result.deleted)'." }
            }
            if ($request.Operation -in @("preview", "current")) { $script:displayDetailProfile = $result.profile }
            if ($request.Operation -in @("apply", "recover")) { $script:monitorSnapshot = $null }
            $refresh = $request.Operation -in @("save", "hotkey", "delete", "apply", "recover")
        }
    } catch {
        $script:displayNotice = "Display layout error: $($_.Exception.Message)"
        if ($script:displayRequest.Operation -eq "list") { $script:displaySnapshot = $null; Clear-DisplayHotkeys }
        else { $refresh = $true }
    } finally {
        $script:displayJob = $null; $script:displayRequest = $null
        Set-DisplayEnabled; Set-MonitorEnabled; Update-DisplayDetails
    }
    if ($refresh) {
        $script:displayLastNotice = $script:displayNotice
        Start-DisplayOperation "list"
    }
}
$script:displayProfilesBox.Add_SelectedIndexChanged({
    $script:displayDetailProfile = $null
    $profile = Get-SelectedDisplayProfile
    if ($profile) { $script:displayHotkeyBox.SelectedIndex = [int]$profile.hotkey }
    Set-DisplayEnabled; Update-DisplayDetails
})
Set-DisplayEnabled
Update-DisplayDetails
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
    Start-DisplayOperation "list"
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
    $script:airPlayWorker.Stop()
    $script:airPlayWorker.Dispose()
    $script:clipShareWorker.Stop()
    $script:clipShareWorker.Dispose()
    $script:monitorWorker.Stop()
    $script:monitorWorker.Dispose()
    Clear-DisplayHotkeys
    $script:displayWorker.Stop()
    $script:displayWorker.Dispose()
    if ($script:ni) {
        $script:ni.Visible = $false
        $script:ni.Dispose()
    }
}
