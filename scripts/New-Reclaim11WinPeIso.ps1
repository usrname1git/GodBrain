# Build Reclaim11 WinPE ISO for VMware (not a physical USB).
# ADK DISM is used only against copype's boot.wim, never the host OS.
# Pin ADK + WinPE addon 10.1.26100.2454 (do not install ADK 10.1.28000 —
# winget's WinPE addon has no matching 28000 build).
[CmdletBinding()]
param(
    [string]$RepoRoot = $PSScriptRoot,
    [string]$OutIso = "C:\Reclaim11\Reclaim11-WinPE-v9.iso",
    [string]$WorkDir = "C:\Reclaim11\winpe-work",
    [string]$StubPath = "C:\Reclaim11\reclaim11-stub.exe",
    [switch]$Probe,
    [switch]$Reset
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Resolve-Reclaim11Kit.ps1")

$AdkVersionPin = "10.1.26100.2454"
$reclaim = $Reclaim11Root
$winpeSrc = Join-Path $reclaim "winpe"

function Get-Reclaim11Adk {
    $root = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\Assessment and Deployment Kit"
    $pe = Join-Path $root "Windows Preinstallation Environment"
    [pscustomobject]@{
        root     = $root
        pe       = $pe
        copype   = (Join-Path $pe "copype.cmd")
        make     = $(
            $m1 = Join-Path $root "Deployment Tools\MakeWinPEMedia.cmd"
            $m2 = Join-Path $pe "MakeWinPEMedia.cmd"
            if (Test-Path -LiteralPath $m1) { $m1 } elseif (Test-Path -LiteralPath $m2) { $m2 } else { $m1 }
        )
        dism     = (Join-Path $root "Deployment Tools\amd64\DISM\dism.exe")
        oscdimg  = (Join-Path $root "Deployment Tools\amd64\Oscdimg\oscdimg.exe")
        envbat   = (Join-Path $root "Deployment Tools\DandISetEnv.bat")
        oc       = (Join-Path $pe "amd64\WinPE_OCs")
        present  = (Test-Path -LiteralPath (Join-Path $pe "copype.cmd"))
        version  = $AdkVersionPin
    }
}

function Test-Reclaim11Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal $id
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$adk = Get-Reclaim11Adk
if ($Probe) {
    [pscustomobject]@{
        adk_present = [bool]$adk.present
        adk_copype  = $adk.copype
        adk_version = $adk.version
        out_iso     = $OutIso
        work_dir    = $WorkDir
        reclaim     = $reclaim
    } | ConvertTo-Json -Compress
    if (-not $adk.present) { exit 2 }
    exit 0
}

if (-not $adk.present) {
    throw @"
New-Reclaim11WinPeIso: Windows ADK WinPE is missing.
Install the matching pair (not ADK 10.1.28000):
  winget install --id Microsoft.WindowsADK --version $AdkVersionPin --exact
  winget install --id Microsoft.WindowsADK.WinPEAddon --version $AdkVersionPin --exact
"@
}
foreach ($need in @("offline.ps1", "Apply-Reclaim11Offline.ps1", "startnet.cmd", "stub.c")) {
    $p = Join-Path $winpeSrc $need
    if (-not (Test-Path -LiteralPath $p)) { throw "New-Reclaim11WinPeIso: missing $p" }
}
$cat = Join-Path $reclaim "catalog.json"
if (-not (Test-Path -LiteralPath $cat)) { throw "New-Reclaim11WinPeIso: missing $cat" }
if (-not (Test-Reclaim11Admin)) { throw "New-Reclaim11WinPeIso: DISM mount needs elevation" }

$stub = Get-Reclaim11IsoStub -Preferred $StubPath

$outParent = Split-Path -Parent $OutIso
if ($outParent -and -not (Test-Path -LiteralPath $outParent)) {
    New-Item -ItemType Directory -Path $outParent | Out-Null
}
if ($Reset -and (Test-Path -LiteralPath $WorkDir)) {
    Remove-Item -LiteralPath $WorkDir -Recurse -Force
}
if (-not (Test-Path -LiteralPath (Join-Path $WorkDir "media\sources\boot.wim"))) {
    if (Test-Path -LiteralPath $WorkDir) {
        Remove-Item -LiteralPath $WorkDir -Recurse -Force
    }
    Write-Host "copype amd64 $WorkDir"
    $copypeLine = 'call "{0}" && call "{1}" amd64 "{2}"' -f $adk.envbat, $adk.copype, $WorkDir
    $p = Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", $copypeLine) -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) { throw "New-Reclaim11WinPeIso: copype exit $($p.ExitCode)" }
}

$dism = $adk.dism
function Invoke-Reclaim11Dism {
    param([Parameter(Mandatory)][string[]]$DismArgs)
    Write-Host ("dism {0}" -f ($DismArgs -join " "))
    & $dism @DismArgs
    if ($LASTEXITCODE -ne 0) {
        throw ("New-Reclaim11WinPeIso: dism exit {0} ({1})" -f $LASTEXITCODE, ($DismArgs -join " "))
    }
}

$wim = Join-Path $WorkDir "media\sources\boot.wim"
$mount = Join-Path $WorkDir "mount"
if (-not (Test-Path -LiteralPath $mount)) { New-Item -ItemType Directory -Path $mount | Out-Null }
if (Test-Path -LiteralPath (Join-Path $mount "Windows\System32")) {
    Write-Host "discard leftover mount"
    & $dism /Unmount-Image "/MountDir:$mount" /Discard
}

Write-Host "DISM mount $wim -> $mount (boot.wim only, not the host OS)"
Invoke-Reclaim11Dism -DismArgs @("/Mount-Image", "/ImageFile:$wim", "/Index:1", "/MountDir:$mount")

try {
    $oc = $adk.oc
    $en = Join-Path $oc "en-us"
    $pkgs = @(
        "WinPE-WMI",
        "WinPE-NetFx",
        "WinPE-Scripting",
        "WinPE-PowerShell",
        "WinPE-StorageWMI"
    )
    foreach ($name in $pkgs) {
        $cab = Join-Path $oc ($name + ".cab")
        $lang = Join-Path $en ($name + "_en-us.cab")
        if (-not (Test-Path -LiteralPath $cab)) { throw "New-Reclaim11WinPeIso: missing $cab" }
        Invoke-Reclaim11Dism -DismArgs @("/Image:$mount", "/Add-Package", "/PackagePath:$cab")
        if (Test-Path -LiteralPath $lang) {
            Invoke-Reclaim11Dism -DismArgs @("/Image:$mount", "/Add-Package", "/PackagePath:$lang")
        }
    }

    $dest = Join-Path $mount "Reclaim11"
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    New-Item -ItemType Directory -Path $dest | Out-Null
    Copy-Item -LiteralPath (Join-Path $winpeSrc "offline.ps1") -Destination (Join-Path $dest "offline.ps1") -Force
    Copy-Item -LiteralPath (Join-Path $winpeSrc "Apply-Reclaim11Offline.ps1") -Destination (Join-Path $dest "Apply-Reclaim11Offline.ps1") -Force
    Copy-Item -LiteralPath $cat -Destination (Join-Path $dest "catalog.json") -Force
    Copy-Item -LiteralPath $stub -Destination (Join-Path $dest "DefenderStub.exe") -Force
    $ps1Dir = Join-Path $reclaim "ps1"
    foreach ($n in @("inventory.ps1", "killing_blows.ps1", "Apply-KillingBlows.ps1", "noob_cleanse.ps1", "Apply-NoobCleanse.ps1", "Restore-Reclaim11Noob.ps1", "grim_reaper.ps1", "NuclearDefenderWipe-V6_3.ps1", "xbox_cleanse.ps1", "telemetry_cleanse.ps1", "nic_tune.ps1", "elevate.ps1")) {
        $s = Join-Path $ps1Dir $n
        if (-not (Test-Path -LiteralPath $s)) { throw "New-Reclaim11WinPeIso: missing $s" }
        Copy-Item -LiteralPath $s -Destination (Join-Path $dest $n) -Force
    }
    Copy-Item -LiteralPath (Join-Path $winpeSrc "startnet.cmd") -Destination (Join-Path $mount "Windows\System32\startnet.cmd") -Force

    $ps = Join-Path $mount "Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path -LiteralPath $ps)) {
        throw "New-Reclaim11WinPeIso: powershell.exe missing after WinPE-PowerShell"
    }
    Write-Host "payload copied; powershell.exe present"
} catch {
    Write-Host "discard mount after failure"
    & $dism /Unmount-Image "/MountDir:$mount" /Discard
    throw
}

Write-Host "DISM unmount /commit"
Invoke-Reclaim11Dism -DismArgs @("/Unmount-Image", "/MountDir:$mount", "/Commit")

$oscd = Split-Path -Parent $adk.oscdimg
$env:Path = $oscd + ";" + $env:Path
if (Test-Path -LiteralPath $OutIso) { Remove-Item -LiteralPath $OutIso -Force }
Write-Host "MakeWinPEMedia /ISO $OutIso"
$makeLine = 'call "{0}" && call "{1}" /ISO /f "{2}" "{3}"' -f $adk.envbat, $adk.make, $WorkDir, $OutIso
$p = Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", $makeLine) -Wait -PassThru -NoNewWindow
if ($p.ExitCode -ne 0) { throw "New-Reclaim11WinPeIso: MakeWinPEMedia exit $($p.ExitCode)" }
if (-not (Test-Path -LiteralPath $OutIso)) { throw "New-Reclaim11WinPeIso: ISO missing $OutIso" }

Write-Output ("Reclaim11 WinPE ISO: {0} ({1:N0} bytes). Attach in VMware. Snapshot first. Not USB." -f $OutIso, (Get-Item -LiteralPath $OutIso).Length)
exit 0
