# Write Reclaim11 WinPE to a small USB stick. Separate from the ISO builder
# (that script must never /UFD). Never the boot NVMe. Never a USB HDD.
# VM passthrough or another box. ADK DISM only against copype boot.wim, never the host OS.

[CmdletBinding()]
param(
    [Alias("T", "Test")]
    [switch]$WhatIf,
    [int]$DiskNumber = -1,
    [switch]$Go,
    [switch]$RefreshPayload,
    [string]$RepoRoot = $PSScriptRoot,
    [string]$WorkDir = "C:\Reclaim11\winpe-work",
    [string]$StubPath = "C:\Reclaim11\reclaim11-stub.exe"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Resolve-Reclaim11Kit.ps1")

$script:UsbMaxBytes = 32GB
$script:UsbMinBytes = 2GB
$AdkVersionPin = "10.1.26100.2454"
$reclaim = $Reclaim11Root
$winpeSrc = Join-Path $reclaim "winpe"
$script:Ps1Dir = Join-Path $reclaim "ps1"
$script:KitFiles = @(
    "inventory.ps1", "killing_blows.ps1", "Apply-KillingBlows.ps1",
    "noob_cleanse.ps1", "Apply-NoobCleanse.ps1", "Restore-Reclaim11Noob.ps1",
    "grim_reaper.ps1", "NuclearDefenderWipe-V6_3.ps1", "xbox_cleanse.ps1", "telemetry_cleanse.ps1",
    "nic_tune.ps1", "latency_bake.ps1", "install_pwsh.ps1", "elevate.ps1"
)

function Get-Reclaim11Adk {
    $root = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\Assessment and Deployment Kit"
    $pe = Join-Path $root "Windows Preinstallation Environment"
    $m1 = Join-Path $root "Deployment Tools\MakeWinPEMedia.cmd"
    $m2 = Join-Path $pe "MakeWinPEMedia.cmd"
    [pscustomobject]@{
        root    = $root
        pe      = $pe
        make    = $(if (Test-Path -LiteralPath $m1) { $m1 } elseif (Test-Path -LiteralPath $m2) { $m2 } else { $m1 })
        dism    = (Join-Path $root "Deployment Tools\amd64\DISM\dism.exe")
        envbat  = (Join-Path $root "Deployment Tools\DandISetEnv.bat")
        present = (Test-Path -LiteralPath (Join-Path $pe "copype.cmd"))
        version = $AdkVersionPin
    }
}

function Test-Reclaim11Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal $id
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Reclaim11UsbCandidates {
    $out = @()
    foreach ($d in @(Get-Disk -ErrorAction Stop)) {
        $why = @()
        if ($d.Number -eq 0) { $why += "disk0" }
        if ([bool]$d.IsBoot -or [bool]$d.IsSystem -or [bool]$d.BootFromDisk) { $why += "boot" }
        if ([string]$d.BusType -ne "USB") { $why += ("bus=" + $d.BusType) }
        if ([int64]$d.Size -gt $script:UsbMaxBytes) { $why += "over-32GiB" }
        if ([int64]$d.Size -lt $script:UsbMinBytes) { $why += "under-2GiB" }
        $letters = @()
        try {
            $letters = @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue |
                    Get-Volume -ErrorAction SilentlyContinue |
                    Where-Object { $_.DriveLetter } |
                    ForEach-Object { [string]$_.DriveLetter })
        } catch { }
        if ($letters -contains "C") { $why += "letter-C" }
        $ok = ($why.Count -lt 1)
        $out += [pscustomobject]@{
            number  = [int]$d.Number
            name    = [string]$d.FriendlyName
            bus     = [string]$d.BusType
            size    = [int64]$d.Size
            letters = @($letters)
            ok      = $ok
            refuse  = ($why -join ",")
        }
    }
    $out
}

function Copy-Reclaim11PePayload {
    param(
        [string]$Mount,
        [string]$Stub
    )
    $dest = Join-Path $Mount "Reclaim11"
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    New-Item -ItemType Directory -Path $dest | Out-Null
    foreach ($n in @("offline.ps1", "Apply-Reclaim11Offline.ps1", "Start-Reclaim11Pe.ps1", "Skip-Reclaim11WinRe.ps1")) {
        Copy-Item -LiteralPath (Join-Path $winpeSrc $n) -Destination (Join-Path $dest $n) -Force
    }
    Copy-Item -LiteralPath (Join-Path $reclaim "catalog.json") -Destination (Join-Path $dest "catalog.json") -Force
    Copy-Item -LiteralPath $Stub -Destination (Join-Path $dest "DefenderStub.exe") -Force
    foreach ($n in $script:KitFiles) {
        $s = Join-Path $script:Ps1Dir $n
        if (-not (Test-Path -LiteralPath $s)) { throw "New-Reclaim11WinPeUsb: missing $s" }
        Copy-Item -LiteralPath $s -Destination (Join-Path $dest $n) -Force
    }
    Copy-Item -LiteralPath (Join-Path $winpeSrc "startnet.cmd") -Destination (Join-Path $Mount "Windows\System32\startnet.cmd") -Force
}

$adk = Get-Reclaim11Adk
$cands = @(Get-Reclaim11UsbCandidates)
$ok = @($cands | Where-Object { $_.ok })
$wim = Join-Path $WorkDir "media\sources\boot.wim"
$plan = [pscustomobject]@{
    id         = "reclaim11-winpe-usb-v1"
    what_if    = [bool]$WhatIf
    mutate     = $false
    adk        = $adk.version
    work_dir   = $WorkDir
    wim        = $wim
    candidates = $cands
    legal      = @($ok | ForEach-Object { $_.number })
    note       = "Disk 0 / >32GiB USB HDD refused. ISO builder stays /ISO only. Boot in a VM or another PC."
}

if ($WhatIf -or -not $Go) {
    Write-Host "TEST ONLY. mutate=false. No format."
    Write-Host ("  ADK {0} present={1}" -f $adk.version, $adk.present)
    Write-Host ("  boot.wim exists={0}" -f (Test-Path -LiteralPath $wim))
    foreach ($c in $cands) {
        $tag = if ($c.ok) { "LEGAL" } else { "REFUSE " + $c.refuse }
        $lett = if (@($c.letters).Count -gt 0) { ($c.letters -join ",") } else { "-" }
        Write-Host ("  disk {0} {1} {2:N1} GiB letter={3}  {4}" -f $c.number, $c.name, ($c.size / 1GB), $lett, $tag)
    }
    if ($ok.Count -eq 1) {
        Write-Host ("WOULD format disk {0} ({1}) via MakeWinPEMedia /UFD /F after payload refresh" -f $ok[0].number, $ok[0].name)
        Write-Host "Do not boot the stick on this IoT desk."
    } elseif ($ok.Count -lt 1) {
        Write-Host "WOULD REFUSE  no USB candidate (need 2-32GiB USB, not boot, not C:)"
    } else {
        Write-Host "WOULD REFUSE  multiple legal sticks; pass -DiskNumber N -Go"
    }
    $plan | ConvertTo-Json -Depth 6
    return
}
if (-not $adk.present) { throw "New-Reclaim11WinPeUsb: ADK WinPE missing (pin $AdkVersionPin)" }
if (-not (Test-Reclaim11Admin)) { throw "New-Reclaim11WinPeUsb: needs admin" }
if (-not (Test-Path -LiteralPath $wim)) {
    throw "New-Reclaim11WinPeUsb: missing $wim (build ISO once: New-Reclaim11WinPeIso.ps1)"
}
if ($DiskNumber -lt 0) {
    if ($ok.Count -eq 1) { $DiskNumber = [int]$ok[0].number }
    else { throw "New-Reclaim11WinPeUsb: pass -DiskNumber N -Go (legal=$($plan.legal -join ','))" }
}
$target = @($cands | Where-Object { $_.number -eq $DiskNumber }) | Select-Object -First 1
if (-not $target) { throw "New-Reclaim11WinPeUsb: no disk $DiskNumber" }
if (-not $target.ok) { throw "Refuse: disk $DiskNumber $($target.refuse). Not the boot NVMe, not a USB HDD." }
$letters = @($target.letters)
if ($letters.Count -lt 1) { throw "New-Reclaim11WinPeUsb: disk $DiskNumber has no drive letter" }
if ($letters -contains "C") { throw "Refuse: target has C:" }
$destLetter = [string]$letters[0]

$stub = Get-Reclaim11IsoStub -Preferred $StubPath

$doRefresh = $true
if ($PSBoundParameters.ContainsKey("RefreshPayload")) { $doRefresh = [bool]$RefreshPayload }
if ($doRefresh) {
    $dism = $adk.dism
    $mount = Join-Path $WorkDir "mount"
    if (-not (Test-Path -LiteralPath $mount)) { New-Item -ItemType Directory -Path $mount | Out-Null }
    if (Test-Path -LiteralPath (Join-Path $mount "Windows\System32")) {
        Write-Host "discard leftover mount"
        & $dism /Unmount-Image "/MountDir:$mount" /Discard | Out-Null
    }
    Write-Host "DISM mount boot.wim (not host OS) for payload refresh"
    & $dism /Mount-Image "/ImageFile:$wim" /Index:1 "/MountDir:$mount"
    if ($LASTEXITCODE -ne 0) { throw "New-Reclaim11WinPeUsb: dism mount exit $LASTEXITCODE" }
    try {
        Copy-Reclaim11PePayload -Mount $mount -Stub $stub
        $ps = Join-Path $mount "Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
        if (-not (Test-Path -LiteralPath $ps)) { throw "New-Reclaim11WinPeUsb: powershell.exe missing in WinPE" }
    } catch {
        & $dism /Unmount-Image "/MountDir:$mount" /Discard | Out-Null
        throw
    }
    Write-Host "DISM unmount /commit"
    & $dism /Unmount-Image "/MountDir:$mount" /Commit
    if ($LASTEXITCODE -ne 0) { throw "New-Reclaim11WinPeUsb: dism commit exit $LASTEXITCODE" }
}

Write-Host ("MakeWinPEMedia /UFD /F disk {0} {1}:  ({2})" -f $DiskNumber, $destLetter, $target.name)
Write-Host "This FORMATS the stick. Not disk 0. Boot in a VM or another PC."
$makeLine = 'call "{0}" && call "{1}" /UFD /F "{2}" {3}:' -f $adk.envbat, $adk.make, $WorkDir, $destLetter
$p = Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", $makeLine) -Wait -PassThru -NoNewWindow
if ($p.ExitCode -ne 0) { throw "New-Reclaim11WinPeUsb: MakeWinPEMedia /UFD exit $($p.ExitCode)" }

$usbRoot = ($destLetter + ":\")
$kitDest = Join-Path $usbRoot "reclaim11"
if (-not (Test-Path -LiteralPath $kitDest)) { New-Item -ItemType Directory -Path $kitDest | Out-Null }
Copy-Item -LiteralPath (Join-Path $reclaim "catalog.json") -Destination (Join-Path $kitDest "catalog.json") -Force
Copy-Item -LiteralPath (Join-Path $reclaim "Reclaim11.cmd") -Destination (Join-Path $kitDest "Reclaim11.cmd") -Force
$ps1Dest = Join-Path $kitDest "ps1"
if (-not (Test-Path -LiteralPath $ps1Dest)) { New-Item -ItemType Directory -Path $ps1Dest | Out-Null }
foreach ($n in $script:KitFiles) {
    Copy-Item -LiteralPath (Join-Path $script:Ps1Dir $n) -Destination (Join-Path $ps1Dest $n) -Force
}
Copy-Item -LiteralPath (Join-Path $script:Ps1Dir "Reclaim11.ps1") -Destination (Join-Path $ps1Dest "Reclaim11.ps1") -Force
$uiSrc = Join-Path $reclaim "ui"
if (Test-Path -LiteralPath $uiSrc) {
    $uiDest = Join-Path $kitDest "ui"
    if (-not (Test-Path -LiteralPath $uiDest)) { New-Item -ItemType Directory -Path $uiDest | Out-Null }
    Copy-Item -LiteralPath (Join-Path $uiSrc "MainWindow.xaml") -Destination (Join-Path $uiDest "MainWindow.xaml") -Force
}
Copy-Item -LiteralPath $stub -Destination (Join-Path $kitDest "DefenderStub.exe") -Force

[pscustomobject]@{
    id          = "reclaim11-winpe-usb-v1"
    applied     = $true
    disk        = $DiskNumber
    name        = $target.name
    letter      = $destLetter
    kit         = $kitDest
    note        = "First boot: PE pack-A delete. Reboot. Double-click E:\reclaim11\Reclaim11.cmd (Grim Reaper) in the VM, not this desk."
} | ConvertTo-Json -Depth 5
Write-Host "USB ready. Boot in a VM or another PC."
