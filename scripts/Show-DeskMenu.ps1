# One window for the doors already on this machine.
# Status: model on :8888, kernel :8083, RAG :8084, Mongo :27017, gym :4177, CS2, mouth pause, GPU, RustDesk, sshd :2222, Tailscale.
# Model clicks stop whoever owns :8888, then start the other. One GPU slot.
# Lyrics: start the capture, wait until loopback is recording, wait the preroll,
# then Shift+P into the running ncspot (track already loaded and paused).
[CmdletBinding()]
param(
    [switch]$Status
)

$ErrorActionPreference = "Stop"
$Kit = "C:\nvme\Qwen3.8-27B-16gb"
$Start27 = Join-Path $Kit "paper-godbrain\Start-PaperQwen.ps1"
$StopModel = Join-Path $Kit "paper-godbrain\Stop-PaperQwen.ps1"
$Repo = Split-Path $PSScriptRoot -Parent
$StartVl = Join-Path $Repo "scripts\Start-QwenVL.ps1"
$StartImage = Join-Path $Repo "scripts\Start-QwenImage.ps1"
$Lyrics = Join-Path $Repo "scripts\Invoke-LyricsLoop.ps1"
$Pwsh = "C:\pwsh\pwsh.exe"
$cs2Helper = Join-Path $Repo "GodBrain-Cs2.ps1"
if (Test-Path -LiteralPath $cs2Helper) { . $cs2Helper }

function Test-Port([int]$Port) {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $ok = $c.ConnectAsync("127.0.0.1", $Port).Wait(300)
        $c.Close()
        return [bool]$ok
    } catch { return $false }
}

function Get-ModelLine {
    if (-not (Test-Port 8888)) { return "8888 down" }
    try {
        $r = Invoke-RestMethod http://127.0.0.1:8888/v1/models -TimeoutSec 2
        $id = $r.data[0].id
        $n = $r.data[0].max_model_len
        return "$id  ctx=$n"
    } catch { return "8888 up, models unread" }
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

function Set-HostService([string]$Name, [string]$Action) {
    $wsudo = "C:\Tools\TeamM2\wsudo.exe"
    if (-not (Test-Path -LiteralPath $wsudo)) {
        [System.Windows.Forms.MessageBox]::Show("Need $wsudo to $Action $Name")
        return
    }
    Start-Process -FilePath $wsudo -ArgumentList @("-A", "-w", "sc.exe", $Action, $Name) -WindowStyle Hidden -Wait
    Update-Status
}

function Get-Cs2DeskLine {
    if (-not (Get-Command Test-Cs2Running -ErrorAction SilentlyContinue)) { return "unread" }
    if (Test-Cs2Running) { return "running" }
    if (Test-GodBrainColiShouldSleep $Repo) { return "sleep" }
    return "idle"
}

function Test-GenerateBusy {
    try {
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
        $kernel
        $rag
        $mongo
        $gym
        $cs2
        $mouth
        (Get-GpuLine)
    ) -join "`r`n"
}

if ($Status) {
    Write-Output (Get-DeskStatus)
    exit 0
}

if ([Threading.Thread]::CurrentThread.ApartmentState -ne "STA") {
    Start-Process -FilePath $Pwsh -ArgumentList @("-NoProfile", "-Sta", "-File", $PSCommandPath)
    return
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

function Start-Door([string]$File) {
    Start-Process -FilePath $Pwsh -ArgumentList @("-NoProfile", "-File", $File) -WindowStyle Normal | Out-Null
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
    return $true
}

function Test-GymStarting {
    $hits = Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like "*Invoke-FrontendGym.ps1*" }
    return [bool]$hits
}

function Start-GymDashboard {
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
    if ($modelId -match 'vl') {
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
    if ($modelId -notmatch 'vl') {
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

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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
$f.FormBorderStyle = "FixedSingle"
$f.MaximizeBox = $false
$f.ClientSize = New-Object System.Drawing.Size(456, 440)
$f.StartPosition = "CenterScreen"
$f.BackColor = $bg
$f.ForeColor = $ink
$f.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$f.Icon = $deskIcon

$rail = New-Object System.Windows.Forms.Panel
$rail.Location = New-Object System.Drawing.Point(0, 0)
$rail.Size = New-Object System.Drawing.Size(52, 440)
$rail.BackColor = $railBg
$f.Controls.Add($rail)

$pages = @{}
function New-Page {
    $p = New-Object System.Windows.Forms.Panel
    $p.Location = New-Object System.Drawing.Point(52, 0)
    $p.Size = New-Object System.Drawing.Size(404, 440)
    $p.BackColor = $bg
    $p.Visible = $false
    $f.Controls.Add($p)
    return $p
}
$pageStatus = New-Page
$pageModel = New-Page
$pageAsk = New-Page
$pageLyrics = New-Page
$pages.Status = $pageStatus
$pages.Model = $pageModel
$pages.Ask = $pageAsk
$pages.Lyrics = $pageLyrics

$script:railMarks = @()
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
    $script:railMarks += [pscustomobject]@{ Name = $name; Mark = $mark; Button = $b }
}

function Show-Page([string]$name) {
    foreach ($key in @($pages.Keys)) { $pages[$key].Visible = ($key -eq $name) }
    foreach ($item in $script:railMarks) {
        $on = $item.Name -eq $name
        $item.Mark.Visible = $on
        $item.Button.ForeColor = $(if ($on) { $ink } else { $mute })
    }
}

# Gauge, sun, chat, music. Same rail idea as the sky strip.
Add-Rail "Status" ([char]0xE9D9) 16
Add-Rail "Model" ([char]0xE706) 64
Add-Rail "Ask" ([char]0xE8BD) 112
Add-Rail "Lyrics" ([char]0xE189) 160

$exitRail = New-Object System.Windows.Forms.Button
$exitRail.Text = [char]0xE7E8
$exitRail.Font = New-Object System.Drawing.Font("Segoe MDL2 Assets", 14)
$exitRail.FlatStyle = "Flat"
$exitRail.FlatAppearance.BorderSize = 0
$exitRail.BackColor = $railBg
$exitRail.ForeColor = $mute
$exitRail.Location = New-Object System.Drawing.Point(6, 392)
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
    $l.Location = New-Object System.Drawing.Point(20, $y)
    $l.Size = New-Object System.Drawing.Size(110, 22)
    $v = New-Object System.Windows.Forms.Label
    $v.Text = "..."
    $v.ForeColor = $ink
    $v.TextAlign = "MiddleRight"
    $v.Location = New-Object System.Drawing.Point(120, $y)
    $v.Size = New-Object System.Drawing.Size(260, 22)
    $parent.Controls.Add($l)
    $parent.Controls.Add($v)
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
$rowModel = Add-Row $pageStatus "Model" 52
$rowKernel = Add-Row $pageStatus "Kernel" 76
$rowRag = Add-Row $pageStatus "RAG" 100
$rowMongo = Add-Row $pageStatus "Mongo" 124
$rowGym = Add-Row $pageStatus "Gym" 148
$rowCs2 = Add-Row $pageStatus "CS2" 172
$rowMouth = Add-Row $pageStatus "Mouth" 196
$rowGpu = Add-Row $pageStatus "GPU" 220
$rowRust = Add-Row $pageStatus "RustDesk" 244
$rowSsh = Add-Row $pageStatus "SSH" 268
$rowTail = Add-Row $pageStatus "Tailscale" 292
$rowImage = Add-Row $pageStatus "Image" 316

function Update-Status {
    $mouth = "unread"
    $mf = Join-Path $Repo "logs\mouth-pause.txt"
    if (Test-Path $mf) { $mouth = (Get-Content $mf -Raw).Trim() }
    $rowModel.Text = Get-ModelLine
    $rowKernel.Text = $(if (Test-Port 8083) { "up" } else { "down" })
    $rowRag.Text = $(if (Test-Port 8084) { "up" } else { "down" })
    $rowMongo.Text = $(if (Test-Port 27017) { "up" } else { "down" })
    $rowGym.Text = $(if (Test-Port 4177) { "up" } else { "down" })
    $rowCs2.Text = Get-Cs2DeskLine
    $rowMouth.Text = $mouth
    $rowGpu.Text = (Get-GpuLine) -replace "^GPU ", ""
    $rowRust.Text = Get-RustDeskLine
    $rowSsh.Text = Get-SshLine
    $rowTail.Text = Get-TailscaleLine
    $rowImage.Text = $(if (Test-Port 8871) { "up :8871" } else { "down" })
}
Add-Button $pageStatus "Start RustDesk" 20 352 176 {
    Set-HostService "RustDesk" "start"
} $true
Add-Button $pageStatus "Stop RustDesk" 208 352 176 {
    $ask = [System.Windows.Forms.MessageBox]::Show(
        "Stop the RustDesk service? Remote desktop will drop.",
        "RustDesk",
        [System.Windows.Forms.MessageBoxButtons]::YesNo)
    if ($ask -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    Set-HostService "RustDesk" "stop"
} $false
Update-Status
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 4000
$timer.Add_Tick({ Update-Status })
$timer.Start()

Add-Head $pageModel "Model" 16
Add-Button $pageModel "27B text" 20 56 112 { if (Stop-Door) { Start-Door $Start27 } } $true
Add-Button $pageModel "8B vision" 140 56 112 { if (Stop-Door) { Start-Door $StartVl } } $false
Add-Button $pageModel "Image" 260 56 124 { if (Stop-Door) { Start-Door $StartImage } } $false
Add-Button $pageModel "Stop" 20 100 112 { if (Stop-Door) { Update-Status } } $false
Add-Button $pageModel "Galaxy" 144 100 112 { Start-Process "http://127.0.0.1:8083/" } $false
Add-Button $pageModel "Gym" 268 100 116 { Start-Process "http://127.0.0.1:4177/" } $false
Add-Button $pageModel "Start gym" 20 144 176 { Start-GymDashboard } $true
Add-Button $pageModel "Scan clips" 208 144 176 { Start-ClipScan } $false

$cwdLabel = New-Object System.Windows.Forms.Label
$cwdLabel.Text = "Grok folder"
$cwdLabel.ForeColor = $mute
$cwdLabel.Location = New-Object System.Drawing.Point(20, 196)
$cwdLabel.AutoSize = $true
$pageModel.Controls.Add($cwdLabel)
$cwd = New-Object System.Windows.Forms.TextBox
$cwd.Text = $Repo
$cwd.Location = New-Object System.Drawing.Point(20, 218)
$cwd.Size = New-Object System.Drawing.Size(240, 26)
Style-Box $cwd
$pageModel.Controls.Add($cwd)
Add-Button $pageModel "Open Grok" 272 214 112 {
    $dir = $cwd.Text
    if (-not (Test-Path -LiteralPath $dir)) { [System.Windows.Forms.MessageBox]::Show("No such folder: $dir"); return }
    $grok = (Get-Command grok -ErrorAction SilentlyContinue).Source
    if (-not $grok) { [System.Windows.Forms.MessageBox]::Show("grok is not on PATH"); return }
    Start-Process -FilePath $grok -WorkingDirectory $dir | Out-Null
} $false

Add-Head $pageAsk "Ask" 16
$prompt = New-Object System.Windows.Forms.TextBox
$prompt.Location = New-Object System.Drawing.Point(20, 56)
$prompt.Size = New-Object System.Drawing.Size(240, 26)
Style-Box $prompt
$pageAsk.Controls.Add($prompt)
Add-Button $pageAsk "Send" 272 52 112 {
    $busy = Test-GenerateBusy
    if ($null -eq $busy) {
        [System.Windows.Forms.MessageBox]::Show("Kernel status is down, so Ask cannot tell if the GPU slot is free.")
        return
    }
    if ($busy) {
        [System.Windows.Forms.MessageBox]::Show("A generate is already running (one GPU slot). Wait.")
        return
    }
    $text = [string]$prompt.Text
    if ($text -notmatch '^(?i)no tools\b') { $text = "No tools. `n" + $text }
    $body = @{ message = $text } | ConvertTo-Json -Compress
    $reply.Text = "waiting..."
    try {
        $res = Invoke-RestMethod http://127.0.0.1:8083/api/chat -Method Post -Body $body -ContentType "application/json; charset=utf-8" -TimeoutSec 180
        if ($res.response) { $reply.Text = [string]$res.response }
        elseif ($res.error) { $reply.Text = [string]$res.error }
        else { $reply.Text = ($res | ConvertTo-Json -Compress) }
    } catch {
        $reply.Text = $_.Exception.Message
    }
} $true
$reply = New-Object System.Windows.Forms.TextBox
$reply.Multiline = $true
$reply.ScrollBars = "Vertical"
$reply.Location = New-Object System.Drawing.Point(20, 96)
$reply.Size = New-Object System.Drawing.Size(364, 200)
Style-Box $reply
$pageAsk.Controls.Add($reply)

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
$hint.Size = New-Object System.Drawing.Size(364, 48)
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
[System.Windows.Forms.Application]::Run($f)
$timer.Stop()
if ($script:ni) {
    $script:ni.Visible = $false
    $script:ni.Dispose()
}
