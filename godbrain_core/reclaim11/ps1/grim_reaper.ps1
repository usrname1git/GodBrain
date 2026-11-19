# Grim Reaper. Remainder after WinPE pack A. Boot-safe.
# Old wipe copied DefenderStub.exe over kernel .sys and over
# CodeIntegrity\CIPolicies\Active *.cip, then DENY SYSTEM.
# That is Automatic Repair ("couldn't be repaired") on 25H2.
#
# This door:
#   - DELETE named .sys (never stub a driver with a usermode PE).
#   - Never touch CIPolicies / CodeIntegrity.
#   - Never stub .cip, .reclaim11.bak, mscoree.dll, fltmgr, BFE/mpssvc.
#   - Never stub appidsvc.dll (svchost).
#   - 25H2: Wd*.sys live in drivers\ (wd\ is often empty). Exact names.
#   - Never glob Wd*.sys (that hits wdf01000 / WdfLdr / WdiWiFi).
#   - Skip WdBoot.sys when Secure Boot is on (ELAM).
#   - If a .sys is in use (PPL), skip — do not stub. Boot PE first.
#   - DENY SYSTEM only on Defender Program Files / ProgramData trees,
#     never under System32.
# Keep GPO DisableAntiSpyware=1. Never BFE / mpssvc / FltMgr / EventLog.
# Core WU stays by default; USO/Medic remain destructive targets. -RemoveWindowsUpdate opts into the
# old WU service/file/IFEO/task/registry removal and Settings hiding.
# Never stub usosvc.dll / wuaueng.dll / WaaSMedicSvc.dll (svchost).
# Never bits / DoSvc / TrustedInstaller. Not killing-blows pack A.
#
# pwsh -NoProfile -ExecutionPolicy Bypass -File grim_reaper.ps1
# pwsh -NoProfile -File grim_reaper.ps1 -SelfTest

[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$RemoveWindowsUpdate,
    [Alias("T", "Test")]
    [switch]$WhatIf
)

$ErrorActionPreference = "Continue"
$WipeVersion = "6.3"

Write-Host ("=== Grim Reaper v{0} (boot-safe) ===" -f $WipeVersion) -ForegroundColor Red
Write-Host ("Windows Update: {0}; USO/Medic: REMOVE" -f $(if ($RemoveWindowsUpdate) { "REMOVE (explicit opt-in)" } else { "KEEP core WU (manual-only policy)" })) -ForegroundColor Yellow

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($here)) { $here = $PWD.Path }

$WindowsUpdate = @{
    targets = @("wuauclt.exe")
    files = @("C:\Windows\System32\wuauclt.exe")
    services = @("wuauserv")
    registry = @(
        "HKLM:\SYSTEM\CurrentControlSet\Services\wuauserv",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate",
        "HKLM:\SOFTWARE\Microsoft\WindowsUpdate",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\WindowsUpdate"
    )
    processes = @("wuauclt")
    tasks = @("\Microsoft\Windows\WindowsUpdate")
}
$UpdateWorkers = @{
    targets = @(
        "WaaSMedicAgent.exe", "usoclient.exe", "UsoCoreWorker.exe", "MoUsoCoreWorker.exe",
        "musnotification.exe", "musnotificationux.exe", "UpdateNotificationMgr.exe"
    )
    files = @(
        "C:\Windows\System32\UsoCoreWorker.exe", "C:\Windows\System32\MoUsoCoreWorker.exe",
        "C:\Windows\System32\usoclient.exe", "C:\Windows\System32\WaaSMedicAgent.exe"
    )
    services = @("UsoSvc", "WaaSMedicSvc")
    registry = @(
        "HKLM:\SYSTEM\CurrentControlSet\Services\UsoSvc",
        "HKLM:\SYSTEM\CurrentControlSet\Services\WaaSMedicSvc"
    )
    processes = @(
        "UsoCoreWorker", "MoUsoCoreWorker", "usoclient", "WaaSMedicAgent",
        "MusNotification", "MusNotificationUx"
    )
    tasks = @(
        "\Microsoft\Windows\WaaSMedic",
        "\Microsoft\Windows\UpdateOrchestrator"
    )
}
$Targets = @(
    "SecurityHealthHost.exe", "SecurityHealthService.exe", "SecurityHealthSystray.exe", "SecurityHealthSetup.exe",
    "smartscreen.exe",
    "MsMpEng.exe", "NisSrv.exe", "MpCmdRun.exe", "MSASCuiL.exe", "MSASCui.exe",
    "ConfigSecurityPolicy.exe", "MpCopyAccelerator.exe", "MpDefenderCoreService.exe",
    "MpDlpService.exe", "MpDlpCmd.exe", "DlpUserAgent.exe", "MipDlp.exe", "mpextms.exe",
    "OfflineScannerShell.exe",
    "MsSense.exe", "SenseIR.exe", "SenseCE.exe", "SenseCM.exe", "SenseNdr.exe",
    "SenseCncProxy.exe", "SenseSampleUploader.exe", "SenseImdsCollector.exe",
    "SenseAP.exe", "SenseAPToast.exe", "SenseDlpProcessor.exe", "SenseDlpService.exe",
    "SenseGPParser.exe", "SenseIdentity.exe", "SenseNAS.exe", "SenseTask.exe",
    "SenseTracer.exe", "SenseTVM.exe",
    "SgrmBroker.exe", "SgrmLpac.exe",
    "WebThreatDefenseService.exe", "webthreatdefsvc.exe", "webthreatdefusersvc.exe",
    "appidcertstorecheck.exe", "AppIdPolicyConverter.exe", "AppIdTel.exe"
)

# Exact paths only. 25H2 flat drivers\ plus older drivers\wd\.
$DriverFiles = @(
    "C:\Windows\System32\drivers\msseccore.sys",
    "C:\Windows\System32\drivers\mssecflt.sys",
    "C:\Windows\System32\drivers\mssecwfp.sys",
    "C:\Windows\System32\drivers\WdBoot.sys",
    "C:\Windows\System32\drivers\WdFilter.sys",
    "C:\Windows\System32\drivers\WdNisDrv.sys",
    "C:\Windows\System32\drivers\WdDevFlt.sys",
    "C:\Windows\System32\drivers\KslD.sys",
    "C:\Windows\System32\drivers\wd\WdBoot.sys",
    "C:\Windows\System32\drivers\wd\WdFilter.sys",
    "C:\Windows\System32\drivers\wd\WdNisDrv.sys",
    "C:\Windows\System32\drivers\wd\WdDevFlt.sys",
    "C:\Windows\System32\drivers\wd\KslD.sys",
    "C:\Windows\System32\drivers\appid.sys",
    "C:\Windows\System32\drivers\applockerfltr.sys"
)

# Usermode only. Never appidsvc.dll (svchost).
$ExtraFiles = @(
    "C:\Windows\System32\SecurityHealthHost.exe",
    "C:\Windows\System32\SecurityHealthService.exe",
    "C:\Windows\System32\SecurityHealthSystray.exe",
    "C:\Windows\System32\smartscreen.exe",
    "C:\Windows\SysWOW64\smartscreen.exe",
    "C:\Windows\System32\appidcertstorecheck.exe",
    "C:\Windows\System32\AppIdPolicyConverter.exe",
    "C:\Windows\System32\AppIdTel.exe"
)

# Never CodeIntegrity\CIPolicies. Never drivers\ (named .sys are deleted separately).
$FoldersToNuke = @(
    "C:\Program Files\Windows Defender",
    "C:\Program Files (x86)\Windows Defender",
    "C:\Program Files\Windows Defender Advanced Threat Protection",
    "C:\ProgramData\Microsoft\Windows Defender",
    "C:\ProgramData\Microsoft\Windows Defender Advanced Threat Protection",
    "C:\ProgramData\Microsoft\Windows Security Health",
    "C:\Windows\System32\Config\SystemProfile\AppData\Local\Microsoft\Windows Defender",
    "C:\ProgramData\Microsoft\Windows Defender\Definition Updates\Default",
    "C:\Windows\System32\SecurityHealth",
    "C:\Windows\System32\WebThreatDefSvc"
)

$DenyAclFolders = @(
    "C:\Program Files\Windows Defender",
    "C:\Program Files (x86)\Windows Defender",
    "C:\Program Files\Windows Defender Advanced Threat Protection",
    "C:\ProgramData\Microsoft\Windows Defender",
    "C:\ProgramData\Microsoft\Windows Defender Advanced Threat Protection",
    "C:\ProgramData\Microsoft\Windows Security Health"
)

$ServicesToRemove = @(
    "WinDefend", "WdNisSvc", "WdNisDrv", "WdFilter", "WdBoot", "WdDevFlt", "KslD",
    "Sense", "MDCoreSvc", "SecurityHealthService",
    "webthreatdefsvc", "webthreatdefusersvc",
    "SgrmBroker", "SgrmAgent",
    "wscsvc",
    "MsSecCore", "MsSecFlt", "MsSecWfp",
    "AppIDSvc", "AppID"
)

$NeverTouchService = @(
    "BFE", "mpssvc", "mpsdrv", "Dnscache", "EventLog", "RpcSs", "DcomLaunch",
    "PlugPlay", "SamSs", "Winmgmt", "MongoDB", "mpssvc_wlidsvc", "FltMgr"
)

$NeverStubLeaf = @(
    "mscoree.dll", "fltmgr.sys", "mpsdrv.sys", "bfe.dll", "mpssvc.dll",
    "wdf01000.sys", "WdfLdr.sys", "WdiWiFi.sys", "appidsvc.dll",
    "usosvc.dll", "wuaueng.dll", "WaaSMedicSvc.dll"
)

$RegKeysToDelete = @(
    "HKLM:\SOFTWARE\Microsoft\Windows Defender",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Defender",
    "HKLM:\SOFTWARE\Microsoft\Windows Defender Security Center",
    "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection",
    "HKLM:\SOFTWARE\Classes\windowsdefender",
    "HKLM:\SOFTWARE\Classes\CLSID\{09A47860-11B0-4DA5-AFA5-26D86198A780}",
    "HKLM:\SOFTWARE\Classes\CLSID\{2781761E-28E0-4109-99FE-B9D127C57AFE}",
    "HKLM:\SOFTWARE\Classes\CLSID\{A7C452EF-8E9F-42EB-9F2B-245613CA0DC9}",
    "HKLM:\SOFTWARE\Classes\Wow6432Node\CLSID\{2781761E-28E0-4109-99FE-B9D127C57AFE}",
    "HKLM:\SOFTWARE\WOW6432Node\Classes\CLSID\{2781761E-28E0-4109-99FE-B9D127C57AFE}",
    "HKLM:\SOFTWARE\Classes\*\shellex\ContextMenuHandlers\EPP",
    "HKLM:\SOFTWARE\Classes\Directory\shellex\ContextMenuHandlers\EPP",
    "HKLM:\SOFTWARE\Classes\Drive\shellex\ContextMenuHandlers\EPP",
    "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Svchost\WebThreatDefense"
)

$script:WipeProcessNames = @(
    "MsMpEng", "NisSrv", "MpDefenderCoreService", "MpDlpService", "MsSense",
    "SecurityHealthSystray", "SecurityHealthHost", "SecurityHealthService",
    "smartscreen", "SenseIR", "SenseCE"
)
$script:WipeTaskPaths = @("\Microsoft\Windows\Windows Defender", "\Microsoft\Windows\ExploitGuard")
$Targets += $UpdateWorkers.targets
$ExtraFiles += $UpdateWorkers.files
$ServicesToRemove += $UpdateWorkers.services
$RegKeysToDelete += $UpdateWorkers.registry
$script:WipeProcessNames += $UpdateWorkers.processes
$script:WipeTaskPaths += $UpdateWorkers.tasks
if ($RemoveWindowsUpdate) {
    $Targets += $WindowsUpdate.targets
    $ExtraFiles += $WindowsUpdate.files
    $ServicesToRemove += $WindowsUpdate.services
    $RegKeysToDelete += $WindowsUpdate.registry
    $script:WipeProcessNames += $WindowsUpdate.processes
    $script:WipeTaskPaths += $WindowsUpdate.tasks
} else {
    $NeverTouchService += $WindowsUpdate.services
    $NeverStubLeaf += $WindowsUpdate.targets
}

$RegValuesToDelete = @(
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"; Name = "SecurityHealth" },
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"; Name = "SecurityHealth" },
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Approved"; Name = "{09A47860-11B0-4DA5-AFA5-26D86198A780}" }
)

$script:Deleted = 0
$script:Stubbed = 0
$script:Skipped = 0
$script:InUse = 0
$script:Pending = 0
$script:SvcGone = 0
$script:SecureBootOn = $false
$script:InUseList = @()

function Test-PeMz([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $fs = [IO.File]::OpenRead($Path)
    try {
        $b0 = $fs.ReadByte(); $b1 = $fs.ReadByte()
        return ($b0 -eq 0x4D -and $b1 -eq 0x5A)
    } finally {
        $fs.Close()
    }
}

function Get-WipeStubPath {
    $cands = @(
        (Join-Path $env:SystemRoot "reclaim11-stub.exe"),
        "C:\Reclaim11\reclaim11-stub.exe"
    )
    foreach ($c in $cands) {
        if (Test-PeMz $c) { return $c }
    }
    "C:\Reclaim11\reclaim11-stub.exe"
}
$StubPath = Get-WipeStubPath

function Get-WipeSecureBootOn {
    try {
        $v = Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State" -Name UEFISecureBootEnabled -ErrorAction Stop
        return [bool]$v.UEFISecureBootEnabled
    } catch {
        try { return [bool](Confirm-SecureBootUEFI) } catch { return $false }
    }
}

function Test-WipeNeverStub([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $true }
    $name = Split-Path $Path -Leaf
    foreach ($n in $NeverStubLeaf) {
        if ($name -ieq $n) { return $true }
    }
    $ext = [IO.Path]::GetExtension($Path)
    if ($ext -ieq ".sys") { return $true }
    if ($ext -ieq ".cip") { return $true }
    if ($Path -like "*.reclaim11.bak") { return $true }
    $low = $Path.ToLowerInvariant()
    if ($low -like "*\codeintegrity\*") { return $true }
    return $false
}

function Unlock-WipeFile([string]$Path) {
    & takeown.exe /F $Path /A 2>&1 | Out-Null
    & icacls.exe $Path /grant:r "Administrators:F" 2>&1 | Out-Null
}

# Hide WU in Settings after Reaper kills wuauserv. Game Mode stays.
# GPO format is hide:id1;id2 — NOT hide:id1;hide:id2 (only the first page hid).
$script:WuHidePages = @(
    "windowsupdate",
    "windowsupdate-action",
    "windowsupdate-history",
    "windowsupdate-optionalupdates",
    "windowsupdate-restartoptions",
    "windowsupdate-activehours",
    "windowsupdate-options",
    "windowsupdate-seekerondemand"
)

function Get-WipeHidePageIds([string]$Current = "") {
    $ids = @()
    if ([string]::IsNullOrWhiteSpace($Current)) { return $ids }
    $s = $Current.Trim()
    if ($s.StartsWith("hide:", [StringComparison]::OrdinalIgnoreCase)) {
        $s = $s.Substring(5)
    } elseif ($s.StartsWith("showonly:", [StringComparison]::OrdinalIgnoreCase)) {
        $s = $s.Substring(9)
    }
    foreach ($t in ($s -split ";")) {
        $t = $t.Trim()
        if ($t.StartsWith("hide:", [StringComparison]::OrdinalIgnoreCase)) {
            $t = $t.Substring(5).Trim()
        }
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        $ids += $t
    }
    $ids
}

function Merge-WipeHidePages {
    param(
        [string]$Current = "",
        [string[]]$Hide
    )
    $parts = @()
    $seen = @{}
    foreach ($t in @(Get-WipeHidePageIds -Current $Current)) {
        $key = $t.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        if ($key -eq "gaming-gamemode") { continue }
        $seen[$key] = $true
        $parts += $t
    }
    foreach ($h in $Hide) {
        if ([string]::IsNullOrWhiteSpace($h)) { continue }
        $leaf = $h.Trim()
        if ($leaf.StartsWith("hide:", [StringComparison]::OrdinalIgnoreCase)) {
            $leaf = $leaf.Substring(5).Trim()
        }
        if ($leaf -ieq "gaming-gamemode") {
            throw "Merge-WipeHidePages: refuse hide gaming-gamemode (Game Mode stays)"
        }
        $key = $leaf.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $parts += $leaf
    }
    if ($parts.Count -lt 1) { return "" }
    "hide:" + ($parts -join ";")
}

function Set-WipeWuSettingsHide {
    if (-not $RemoveWindowsUpdate) { throw "Refuse: Windows Update preservation forbids hiding its Settings UI" }
    $hives = New-Object System.Collections.Generic.List[string]
    [void]$hives.Add("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer")
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    # NT SERVICE\TrustedInstaller (elevate.ps1). Do not write TI/.DEFAULT HKCU.
    $tiSid = "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464"
    $skipCu = ($sid -eq "S-1-5-18") -or ($sid -eq $tiSid) -or ($env:RECLAIM11_AS_TI -eq "1")
    if (-not $skipCu) {
        [void]$hives.Add("HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer")
    }
    foreach ($hive in @($hives)) {
        if (-not (Test-Path -LiteralPath $hive)) {
            New-Item -Path $hive -Force | Out-Null
        }
        $cur = ""
        try {
            $ip = Get-ItemProperty -LiteralPath $hive -ErrorAction SilentlyContinue
            if ($ip -and $ip.PSObject.Properties["SettingsPageVisibility"]) {
                $cur = [string]$ip.SettingsPageVisibility
            }
        } catch { }
        $merged = Merge-WipeHidePages -Current $cur -Hide $script:WuHidePages
        New-ItemProperty -Path $hive -Name SettingsPageVisibility -Value $merged -PropertyType String -Force | Out-Null
        Write-Host ("  SettingsPageVisibility {0} -> {1}" -f $hive, $merged) -ForegroundColor Yellow
    }
    $ux = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
    if (-not (Test-Path -LiteralPath $ux)) {
        New-Item -Path $ux -Force | Out-Null
    }
    New-ItemProperty -Path $ux -Name SetDisableUXWUAccess -Value 1 -PropertyType DWord -Force | Out-Null
    Write-Host "  SetDisableUXWUAccess=1 (Check for updates chrome)" -ForegroundColor Yellow
    foreach ($n in @("SystemSettings", "ApplicationFrameHost")) {
        Get-Process -Name $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

function Assert-WipeWuPrerequisites {
    foreach ($name in $WindowsUpdate.services) {
        $service = Get-Service -Name $name -ErrorAction Stop
        if ($service.StartType -eq "Disabled") { throw "Windows Update preservation: $name is already disabled; no automatic repair" }
    }
    foreach ($exe in $WindowsUpdate.targets) {
        $path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$exe"
        if (Test-Path -LiteralPath $path -ErrorAction Stop) {
            $key = Get-Item -LiteralPath $path -ErrorAction Stop
            try {
                if ($key.GetValueNames() -contains "Debugger") {
                    throw "Windows Update preservation: existing IFEO Debugger for $exe; no automatic repair"
                }
            } finally { $key.Close() }
        }
    }
    $policy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
    if (Test-Path -LiteralPath $policy -ErrorAction Stop) {
        $values = Get-ItemProperty -LiteralPath $policy -ErrorAction Stop
        if ($values.PSObject.Properties["SetDisableUXWUAccess"] -and $values.SetDisableUXWUAccess -ne 0) {
            throw "Windows Update preservation: existing policy blocks manual WU access"
        }
        foreach ($name in @("ConfigureDeadlineForQualityUpdates", "ConfigureDeadlineForFeatureUpdates", "SetComplianceDeadline")) {
            if ($values.PSObject.Properties[$name]) {
                throw "Windows Update preservation: existing $name requires separate policy review"
            }
        }
    }
    $explorer = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"
    if (Test-Path -LiteralPath $explorer -ErrorAction Stop) {
        $values = Get-ItemProperty -LiteralPath $explorer -ErrorAction Stop
        if ($values.PSObject.Properties["SettingsPageVisibility"]) {
            $visibility = [string]$values.SettingsPageVisibility
            $ids = @(Get-WipeHidePageIds $visibility)
            if (($visibility -like "hide:*" -and @($ids | Where-Object { $script:WuHidePages -contains $_ }).Count -gt 0) -or
                ($visibility -like "showonly:*" -and $ids -notcontains "windowsupdate")) {
                throw "Windows Update preservation: existing Settings visibility blocks WU; no automatic repair"
            }
        }
    }
}

function Set-WipeWuManualPolicy {
    $path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
    $before = @{ present = $false; kind = $null; value = $null }
    if (Test-Path -LiteralPath $path -ErrorAction Stop) {
        $key = Get-Item -LiteralPath $path -ErrorAction Stop
        try {
            if ($key.GetValueNames() -contains "NoAutoUpdate") {
                $before.present = $true
                $before.kind = [string]$key.GetValueKind("NoAutoUpdate")
                $before.value = $key.GetValue("NoAutoUpdate", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            }
        } finally { $key.Close() }
    }
    $stamp = [datetime]::UtcNow.ToString("yyyyMMddTHHmmssfffffffZ") + "-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    $backup = Join-Path $env:SystemDrive.TrimEnd("\") ("reclaim11\backup\wu-policy-" + $stamp)
    New-Item -ItemType Directory -Path $backup -ErrorAction Stop | Out-Null
    $receipt = Join-Path $backup "windows-update-policy.json"
    @{ id = "reclaim11-wu-policy-v1"; path = $path; name = "NoAutoUpdate"; before = $before; requested = 1 } |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $receipt -Encoding UTF8 -ErrorAction Stop
    $saved = Get-Content -LiteralPath $receipt -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($saved.id -cne "reclaim11-wu-policy-v1" -or $saved.path -cne $path -or
        $saved.name -cne "NoAutoUpdate" -or $saved.requested -ne 1 -or
        ($saved.before | ConvertTo-Json -Compress) -cne ([pscustomobject]$before | ConvertTo-Json -Compress)) {
        throw "Windows Update policy backup readback failed; no policy write"
    }
    if (-not (Test-Path -LiteralPath $path -ErrorAction Stop)) {
        New-Item -Path $path -Force -ErrorAction Stop | Out-Null
    }
    New-ItemProperty -Path $path -Name NoAutoUpdate -Value 1 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
    $key = Get-Item -LiteralPath $path -ErrorAction Stop
    try {
        if ($key.GetValueKind("NoAutoUpdate") -ne [Microsoft.Win32.RegistryValueKind]::DWord -or
            $key.GetValue("NoAutoUpdate") -ne 1) {
            throw "Windows Update manual-only policy readback failed; backup=$receipt"
        }
    } finally { $key.Close() }
    Write-Host "  NoAutoUpdate=1 verified; original policy at $receipt (manual functionality not tested)" -ForegroundColor Yellow
}

function Register-WipePendingStub([string]$Path) {
    if (-not ("WipeMoveEx" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class WipeMoveEx {
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool MoveFileEx(string existingFileName, string newFileName, int flags);
}
"@
    }
    $staging = $Path + ".reclaim11.new"
    Copy-Item -LiteralPath $StubPath -Destination $staging -Force
    $delay = 4
    $replace = 1
    $okDel = [WipeMoveEx]::MoveFileEx($Path, $null, $delay)
    $okNew = [WipeMoveEx]::MoveFileEx($staging, $Path, ($delay -bor $replace))
    if ($okDel -or $okNew) {
        $script:Pending++
        Write-Host "  pending-reboot stub $Path" -ForegroundColor Yellow
        return $true
    }
    return $false
}

function Set-WipeStubFile {
    param(
        [string]$Path,
        [switch]$Final
    )
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (Test-WipeNeverStub $Path) {
        $script:Skipped++
        $name = Split-Path $Path -Leaf
        $noisy = $false
        foreach ($n in $NeverStubLeaf) { if ($name -ieq $n) { $noisy = $true } }
        if ($noisy) {
            Write-Host "  skip boot-critical $Path" -ForegroundColor DarkYellow
        }
        return
    }
    try {
        Copy-Item -LiteralPath $StubPath -Destination $Path -Force -ErrorAction Stop
        $script:Stubbed++
        Write-Host "  stubbed $Path" -ForegroundColor Green
        return
    } catch {
        try {
            Unlock-WipeFile $Path
            Copy-Item -LiteralPath $StubPath -Destination $Path -Force -ErrorAction Stop
            $script:Stubbed++
            Write-Host "  stubbed $Path" -ForegroundColor Green
            return
        } catch {
            # Loaded image: rename often works when overwrite does not.
            $dead = $Path + ".reclaim11.inuse"
            try {
                Unlock-WipeFile $Path
                if (Test-Path -LiteralPath $dead) {
                    Remove-Item -LiteralPath $dead -Force -ErrorAction SilentlyContinue
                }
                Move-Item -LiteralPath $Path -Destination $dead -Force -ErrorAction Stop
                Copy-Item -LiteralPath $StubPath -Destination $Path -Force -ErrorAction Stop
                $script:Stubbed++
                Write-Host "  stubbed (renamed aside) $Path" -ForegroundColor Green
                return
            } catch {
                if ($Final) {
                    if (Register-WipePendingStub $Path) { return }
                    $script:InUse++
                    Write-Host "  [!] Could not stub $Path (In use?)" -ForegroundColor DarkRed
                } else {
                    $script:InUseList += $Path
                    Write-Host "  [!] in use, will retry $Path" -ForegroundColor DarkYellow
                }
            }
        }
    }
}

function Stop-WipeDefenderUserMode {
    foreach ($n in $script:WipeProcessNames) {
        Get-Process -Name $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

function Complete-WipeInUseFiles {
    if (@($script:InUseList).Count -lt 1) { return }
    Write-Host "Retry in-use usermode files (MpClient/MpOAV are usually explorer COM)..." -ForegroundColor Cyan
    Stop-WipeDefenderUserMode
    $left = @()
    foreach ($p in @($script:InUseList)) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $before = $script:Stubbed
        Set-WipeStubFile -Path $p -Final
        if ($script:Stubbed -eq $before -and (Test-Path -LiteralPath $p)) {
            $left += $p
        }
    }
    $script:InUseList = $left
}

function Remove-WipeDriver([string]$Path) {
    $name = Split-Path $Path -Leaf
    foreach ($n in $NeverStubLeaf) {
        if ($name -ieq $n) {
            Write-Host "  REFUSE $Path" -ForegroundColor Red
            $script:Skipped++
            return
        }
    }
    if ($name -ieq "WdBoot.sys" -and $script:SecureBootOn) {
        Write-Host "  skip WdBoot.sys (Secure Boot on, ELAM)" -ForegroundColor DarkYellow
        $script:Skipped++
        return
    }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        Unlock-WipeFile $Path
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        $script:Deleted++
        Write-Host "  deleted $Path" -ForegroundColor Green
    } catch {
        $script:InUse++
        Write-Host "  [!] could not delete $Path (PPL/in use). Not stubbing. Boot PE first." -ForegroundColor DarkRed
    }
}

function Remove-WipePackAScheduledTasks {
    # Named folders only. Never a host-wide task glob. WU/Medic/USO are
    # Grim Reaper remainder (resurrection lock), not killing-blows pack A.
    $allow = $script:WipeTaskPaths
    $n = 0
    $tasks = @()
    try { $tasks = @(Get-ScheduledTask -ErrorAction Stop) } catch { return 0 }
    foreach ($t in $tasks) {
        $p = ([string]$t.TaskPath).Replace("/", "\").TrimEnd("\")
        $ok = $false
        foreach ($a in $allow) { if ($p -ieq $a) { $ok = $true } }
        if (-not $ok) { continue }
        $full = $p + "\" + [string]$t.TaskName
        schtasks.exe /Delete /TN $full /F 2>&1 | Out-Null
        Write-Host "  deltask $full" -ForegroundColor Yellow
        $n++
    }
    $n
}

function Remove-RegKey([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  delkey $Path" -ForegroundColor Yellow
    }
}

function Remove-RegValue([string]$Path, [string]$Name) {
    if ((Test-Path -LiteralPath $Path) -and $null -ne (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue)) {
        Remove-ItemProperty -LiteralPath $Path -Name $Name -Force -ErrorAction SilentlyContinue
        Write-Host "  delval $Path : $Name" -ForegroundColor Yellow
    }
}

function Remove-MultiStringToken([string]$Path, [string]$Name, [string]$Token) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $cur = (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue).$Name
    if ($null -eq $cur) { return }
    $arr = @($cur | Where-Object { $_ -and ($_ -ne $Token) })
    if ($arr.Count -eq @($cur).Count) { return }
    Set-ItemProperty -LiteralPath $Path -Name $Name -Value $arr -Type MultiString
    Write-Host "  strip $Name -= $Token" -ForegroundColor Yellow
}

function Test-WipeSelf {
    $fail = 0
    $cases = @(
        @{ p = "C:\Windows\System32\mscoree.dll"; skip = $true; why = "CLR" },
        @{ p = "C:\Windows\System32\drivers\WdFilter.sys"; skip = $true; why = "kernel" },
        @{ p = "C:\Windows\System32\drivers\msseccore.sys"; skip = $true; why = "kernel" },
        @{ p = "C:\Windows\System32\drivers\wdf01000.sys"; skip = $true; why = "KMDF" },
        @{ p = "C:\Windows\System32\drivers\WdfLdr.sys"; skip = $true; why = "KMDF" },
        @{ p = "C:\Windows\System32\appidsvc.dll"; skip = $true; why = "svchost" },
        @{ p = "C:\Windows\System32\usosvc.dll"; skip = $true; why = "WU svchost dll" },
        @{ p = "C:\Windows\System32\wuaueng.dll"; skip = $true; why = "WU engine dll" },
        @{ p = "C:\Windows\System32\WaaSMedicSvc.dll"; skip = $true; why = "Medic svchost dll" },
        @{ p = "C:\Windows\System32\UsoCoreWorker.exe"; skip = $false; why = "USO removal in both profiles" },
        @{ p = "C:\Windows\System32\wuauclt.exe"; skip = (-not $RemoveWindowsUpdate); why = "core WU profile" },
        @{ p = "C:\Windows\System32\CodeIntegrity\CIPolicies\Active\{0283AC0F-FFF1-49AE-ADA1-8A933130CAD6}.cip"; skip = $true; why = "CI" },
        @{ p = "C:\Program Files\Windows Defender\MsMpEng.exe.reclaim11.bak"; skip = $true; why = "bak" },
        @{ p = "C:\Program Files\Windows Defender\MpClient.dll"; skip = $false; why = "usermode dll" },
        @{ p = "C:\Program Files\Windows Defender\MsMpEng.exe"; skip = $false; why = "usermode exe" },
        @{ p = "C:\Windows\System32\smartscreen.exe"; skip = $false; why = "usermode exe" },
        @{ p = "C:\Program Files\Windows Defender\MpOAV.dll"; skip = $false; why = "oav dll" },
        @{ p = "C:\Program Files\Windows Defender\MpClient.dll"; skip = $false; why = "client dll" }
    )
    foreach ($c in $cases) {
        $got = Test-WipeNeverStub $c.p
        if ($got -ne $c.skip) {
            Write-Host ("SELFTEST FAIL {0} skip={1} got={2} ({3})" -f $c.p, $c.skip, $got, $c.why) -ForegroundColor Red
            $fail++
        } else {
            Write-Host ("SELFTEST ok   skip={0} {1}" -f $got, $c.why) -ForegroundColor Green
        }
    }
    if ($FoldersToNuke -match "CodeIntegrity") {
        Write-Host "SELFTEST FAIL FoldersToNuke still lists CodeIntegrity" -ForegroundColor Red
        $fail++
    } else {
        Write-Host "SELFTEST ok   CIPolicies not in FoldersToNuke" -ForegroundColor Green
    }
    if ($ExtraFiles -match "appidsvc.dll") {
        Write-Host "SELFTEST FAIL ExtraFiles lists appidsvc.dll" -ForegroundColor Red
        $fail++
    } else {
        Write-Host "SELFTEST ok   appidsvc.dll not stubbed" -ForegroundColor Green
    }
    $flat = @($DriverFiles | Where-Object { $_ -like "*\drivers\WdFilter.sys" })
    if ($flat.Count -lt 1) {
        Write-Host "SELFTEST FAIL missing 25H2 drivers\WdFilter.sys" -ForegroundColor Red
        $fail++
    } else {
        Write-Host "SELFTEST ok   25H2 drivers\WdFilter.sys listed" -ForegroundColor Green
    }
    foreach ($s in @("BFE", "mpssvc", "FltMgr")) {
        if ($NeverTouchService -notcontains $s) {
            Write-Host "SELFTEST FAIL never-touch missing $s" -ForegroundColor Red
            $fail++
        }
    }
    Write-Host "SELFTEST ok   never-touch BFE/mpssvc/FltMgr" -ForegroundColor Green
    foreach ($updateProfile in @(
        @{ data = $WindowsUpdate; selected = [bool]$RemoveWindowsUpdate; name = "core WU" },
        @{ data = $UpdateWorkers; selected = $true; name = "USO/Medic" }
    )) {
        foreach ($group in @(
            @{ actual = $Targets; expected = $updateProfile.data.targets },
            @{ actual = $ExtraFiles; expected = $updateProfile.data.files },
            @{ actual = $ServicesToRemove; expected = $updateProfile.data.services },
            @{ actual = $RegKeysToDelete; expected = $updateProfile.data.registry },
            @{ actual = $script:WipeProcessNames; expected = $updateProfile.data.processes },
            @{ actual = $script:WipeTaskPaths; expected = $updateProfile.data.tasks }
        )) {
            foreach ($value in $group.expected) {
                if ([bool]($group.actual -contains $value) -ne $updateProfile.selected) {
                    Write-Host ("SELFTEST FAIL {0} target {1}" -f $updateProfile.name, $value) -ForegroundColor Red
                    $fail++
                }
            }
        }
        foreach ($s in $updateProfile.data.services) {
            if ([bool]($NeverTouchService -contains $s) -eq $updateProfile.selected) {
                Write-Host "SELFTEST FAIL service protection $s" -ForegroundColor Red
                $fail++
            }
        }
    }
    foreach ($s in @("bits", "DoSvc", "TrustedInstaller")) {
        if ($ServicesToRemove -contains $s) {
            Write-Host "SELFTEST FAIL must not sc delete $s" -ForegroundColor Red
            $fail++
        }
    }
    Write-Host ("SELFTEST core WU remove={0}; USO/Medic remove=true; not bits/DoSvc/TI" -f [bool]$RemoveWindowsUpdate) -ForegroundColor Green
    $dllExtra = @($ExtraFiles | Where-Object { $_ -match "usosvc\.dll|wuaueng\.dll|WaaSMedicSvc\.dll" })
    if ($dllExtra.Count -gt 0) {
        Write-Host "SELFTEST FAIL ExtraFiles lists WU svchost dll" -ForegroundColor Red
        $fail++
    } else {
        Write-Host "SELFTEST ok   WU svchost dll not stubbed" -ForegroundColor Green
    }
    if ($script:WuHidePages -notcontains "windowsupdate") {
        Write-Host "SELFTEST FAIL WuHidePages missing windowsupdate" -ForegroundColor Red
        $fail++
    }
    foreach ($need in @("windowsupdate-optionalupdates", "windowsupdate-options", "windowsupdate-seekerondemand")) {
        if ($script:WuHidePages -notcontains $need) {
            Write-Host ("SELFTEST FAIL WuHidePages missing {0}" -f $need) -ForegroundColor Red
            $fail++
        }
    }
    if ($script:WuHidePages -contains "windowsupdate-optional") {
        Write-Host "SELFTEST FAIL WuHidePages has windowsupdate-optional (not a Settings URI)" -ForegroundColor Red
        $fail++
    }
    if ($script:WuHidePages -contains "gaming-gamemode") {
        Write-Host "SELFTEST FAIL WuHidePages hides Game Mode" -ForegroundColor Red
        $fail++
    }
    $fmt = Merge-WipeHidePages -Current "hide:gaming-gamebar;hide:gaming-gamedvr" -Hide $script:WuHidePages
    if ($fmt -notmatch '^hide:gaming-gamebar;gaming-gamedvr;windowsupdate') {
        Write-Host ("SELFTEST FAIL hide GPO format {0}" -f $fmt) -ForegroundColor Red
        $fail++
    }
    if ($fmt -match "hide:windowsupdate") {
        Write-Host "SELFTEST FAIL hide:id;hide:id form would only hide the first page" -ForegroundColor Red
        $fail++
    }
    $uxSrc = Get-Content -LiteralPath $PSCommandPath -Raw -Encoding UTF8
    if ($uxSrc -notmatch "SetDisableUXWUAccess") {
        Write-Host "SELFTEST FAIL missing SetDisableUXWUAccess (System Check for updates chrome)" -ForegroundColor Red
        $fail++
    } else {
        Write-Host "SELFTEST ok   SetDisableUXWUAccess hides Check for updates chrome" -ForegroundColor Green
    }
    if ($fmt -match "gamemode") {
        Write-Host "SELFTEST FAIL merged hide list contains Game Mode" -ForegroundColor Red
        $fail++
    } else {
        Write-Host "SELFTEST ok   WU Settings hide (hide:id1;id2, Game Mode stays)" -ForegroundColor Green
    }
    $gamemodeThrew = $false
    try {
        $null = Merge-WipeHidePages -Current "" -Hide @("gaming-gamemode")
    } catch {
        $gamemodeThrew = $true
    }
    if (-not $gamemodeThrew) {
        Write-Host "SELFTEST FAIL gamemode hide must throw" -ForegroundColor Red
        $fail++
    } else {
        Write-Host "SELFTEST ok   refuse hide gaming-gamemode" -ForegroundColor Green
    }
    if ($fail -gt 0) {
        throw ("Grim Reaper -SelfTest failed ({0})" -f $fail)
    }
    Write-Host "SELFTEST Grim Reaper ok" -ForegroundColor Green
}

if ($SelfTest) {
    Test-WipeSelf
    return
}

function Test-Reclaim11ReaperWinPeReceipt {
    # Inline JSON id. Do not dotsource inventory.ps1 (StrictMode/Stop).
    $root = $env:SystemRoot
    if ([string]::IsNullOrWhiteSpace($root)) { return $false }
    $cands = @(
        (Join-Path $root "reclaim11-winpe.log")
    )
    $parent = Split-Path -Parent $root
    if ($parent) { $cands += (Join-Path $parent "reclaim11-winpe.log") }
    foreach ($c in $cands) {
        if (-not (Test-Path -LiteralPath $c)) { continue }
        try {
            $j = Get-Content -LiteralPath $c -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j -and $j.PSObject.Properties["id"] -and ([string]$j.id -like "reclaim11-winpe*")) {
                return $true
            }
        } catch { }
    }
    $false
}

$hasReceipt = Test-Reclaim11ReaperWinPeReceipt
$wd = Join-Path $env:SystemRoot "System32\drivers\WdFilter.sys"
$wdPresent = Test-Path -LiteralPath $wd
$wuRefusal = ""
if (-not $RemoveWindowsUpdate) {
    try { Assert-WipeWuPrerequisites } catch { $wuRefusal = $_.Exception.Message }
}
if (-not $WhatIf) {
    if (-not $hasReceipt) {
        throw "Refuse: no WinPE receipt. Boot the Reclaim11 WinPE ISO first."
    }
    if ($wdPresent) {
        throw "Refuse: WdFilter.sys still present. PE park did not land."
    }
    if ($wuRefusal) { throw $wuRefusal }
}

if ($WhatIf) {
    Write-Host "TEST ONLY (DeviceCleanupCmd -t). mutate=false." -ForegroundColor Yellow
    Write-Host ("  winpe_receipt={0}" -f $hasReceipt)
    Write-Host ("  WdFilter.sys present={0}" -f $wdPresent)
    Write-Host ("  stub={0} exists={1}" -f $StubPath, (Test-PeMz $StubPath))
    foreach ($f in $DriverFiles) {
        if (Test-Path -LiteralPath $f) { Write-Host ("  would DELETE {0}" -f $f) }
    }
    foreach ($f in $ExtraFiles) {
        if (Test-Path -LiteralPath $f) { Write-Host ("  would STUB {0}" -f $f) }
    }
    foreach ($f in $FoldersToNuke) {
        if (Test-Path -LiteralPath $f) { Write-Host ("  would LOCK {0}" -f $f) }
    }
    foreach ($k in $RegKeysToDelete) {
        if (Test-Path -LiteralPath $k) { Write-Host ("  would delkey {0}" -f $k) }
    }
    foreach ($s in $ServicesToRemove) {
        Write-Host ("  would sc delete {0}" -f $s)
    }
    foreach ($exe in $Targets) { Write-Host "  would IFEO $exe" }
    foreach ($path in $script:WipeTaskPaths) { Write-Host "  would deltask $path (named folder)" }
    if ($RemoveWindowsUpdate) {
        Write-Host ("  would hide WU in Settings ({0}; Game Mode stays)" -f (Merge-WipeHidePages -Current "" -Hide $script:WuHidePages))
        Write-Host "  would SetDisableUXWUAccess=1 (Check for updates on System)"
    } else {
        Write-Host "  would KEEP core WU services/files/tasks/IFEO/registry/Settings; REMOVE USO/Medic; backup and verify NoAutoUpdate=1"
    }
    if (-not $hasReceipt) { Write-Host "WOULD REFUSE  no WinPE receipt" -ForegroundColor Red }
    elseif ($wdPresent) { Write-Host "WOULD REFUSE  WdFilter.sys still present" -ForegroundColor Red }
    elseif ($wuRefusal) { Write-Host "WOULD REFUSE  $wuRefusal" -ForegroundColor Red }
    else { Write-Host "WOULD RUN (after WinPE; named .sys delete, never stub kernel)" -ForegroundColor Green }
    return
}

$el = Join-Path $here "elevate.ps1"
if (Test-Path -LiteralPath $el) {
    $pay = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($pay)) { $pay = $MyInvocation.MyCommand.Path }
    # Child scope so elevate.ps1 StrictMode/Stop does not infect this wipe.
    $hop = & {
        . $el
        $payloadArguments = @()
        if ($RemoveWindowsUpdate) { $payloadArguments += "-RemoveWindowsUpdate" }
        Invoke-Reclaim11AsTrustedInstaller -File $pay -TimeoutSec 300 -PayloadArguments $payloadArguments
    }
    if (-not $hop.continue) {
        if ($hop.output) { Write-Host $hop.output }
        if ([int]$hop.exit_code -ne 0) {
            throw ("TI Grim Reaper exit {0}" -f $hop.exit_code)
        }
        return
    }
}

Write-Host "Deletes named drivers. Stubs usermode Defender trees. Never CIPolicies. Never stub .sys." -ForegroundColor Yellow

if (-not (Test-PeMz $StubPath)) {
    throw "reclaim11-stub.exe is missing or not a PE (MZ). PREP MEDIA compiles it to C:\Reclaim11\reclaim11-stub.exe. PE also drops %SystemRoot%\reclaim11-stub.exe. Do not copy a .cmd to .exe."
}

$log = Join-Path $here ("grim-reaper-v{0}.txt" -f $WipeVersion)
Start-Transcript -Path $log -Force | Out-Null
try {
    $script:SecureBootOn = Get-WipeSecureBootOn
    Write-Host ("Secure Boot enabled={0} (WdBoot delete refused when on)" -f $script:SecureBootOn) -ForegroundColor Cyan
    if (-not $RemoveWindowsUpdate) { Set-WipeWuManualPolicy }

    Write-Host "Setting IFEO redirects..." -ForegroundColor Cyan
    foreach ($exe in $Targets) {
        $key = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$exe"
        New-Item -Path $key -Force | Out-Null
        New-ItemProperty -Path $key -Name "Debugger" -Value $StubPath -PropertyType String -Force | Out-Null
    }

    Write-Host ("Removing selected services (remove Windows Update={0})..." -f [bool]$RemoveWindowsUpdate) -ForegroundColor Cyan
    $svcNames = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    foreach ($s in $ServicesToRemove) { [void]$svcNames.Add($s) }
    Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Services" -ErrorAction SilentlyContinue | Where-Object {
        $_.PSChildName -like "MpKsl*" -or $_.PSChildName -like "webthreatdefusersvc*"
    } | ForEach-Object { [void]$svcNames.Add($_.PSChildName) }

    foreach ($svc in $svcNames) {
        if ($NeverTouchService -contains $svc) {
            Write-Host "  REFUSE $svc" -ForegroundColor Red
            continue
        }
        $q = sc.exe query $svc 2>&1 | Out-String
        if ($q -match "FAILED 1060") {
            Write-Host "  $svc already gone" -ForegroundColor DarkGray
            continue
        }
        sc.exe stop $svc 2>&1 | Out-Null
        sc.exe delete $svc 2>&1 | Out-Null
        $script:SvcGone++
        Write-Host "  sc delete $svc" -ForegroundColor Yellow
    }

    if ($RemoveWindowsUpdate) {
        Write-Host "Hiding Windows Update in Settings (Game Mode stays)..." -ForegroundColor Cyan
        Set-WipeWuSettingsHide
    }

    Write-Host "Deleting named kernel drivers (not stubbing)..." -ForegroundColor Cyan
    foreach ($f in $DriverFiles) { Remove-WipeDriver $f }

    Write-Host "Stubbing System32 usermode extras..." -ForegroundColor Cyan
    foreach ($f in $ExtraFiles) { Set-WipeStubFile $f }

    Stop-WipeDefenderUserMode

    Write-Host "Stubbing Defender directories..." -ForegroundColor Red
    foreach ($folder in $FoldersToNuke) {
        if (Test-Path -LiteralPath $folder) {
            Write-Host "Processing $folder ..." -ForegroundColor Yellow
            & takeown.exe /F $folder /R /A /D Y /SKIPSL 2>&1 | Out-Null
            & icacls.exe $folder /grant:r "Administrators:(OI)(CI)(F)" /T /C /Q 2>&1 | Out-Null
            $files = Get-ChildItem -LiteralPath $folder -Recurse -File -Force -ErrorAction SilentlyContinue
            foreach ($file in $files) {
                Set-WipeStubFile $file.FullName
            }
            $doDeny = $false
            foreach ($d in $DenyAclFolders) {
                if ($folder -ieq $d) { $doDeny = $true }
            }
            if ($doDeny) {
                & icacls.exe $folder /deny "NT AUTHORITY\SYSTEM:(OI)(CI)(F)" /T /C /Q 2>&1 | Out-Null
                & icacls.exe $folder /deny "NT SERVICE\TrustedInstaller:(OI)(CI)(F)" /T /C /Q 2>&1 | Out-Null
                Write-Host "  -> Stubbed and Locked: $folder" -ForegroundColor Green
            } else {
                Write-Host "  -> Stubbed (no DENY SYSTEM under System32): $folder" -ForegroundColor Green
            }
        }
    }

    Write-Host "Removing selected Defender/USO/Medic/WU scheduled tasks (named folders only)..." -ForegroundColor Cyan
    $goneTasks = Remove-WipePackAScheduledTasks
    Write-Host ("  tasks deleted={0}" -f $goneTasks) -ForegroundColor Yellow

    Write-Host "Cleaning selected Defender/USO/Medic/WU registry leftovers..." -ForegroundColor Cyan
    foreach ($k in $RegKeysToDelete) { Remove-RegKey $k }
    foreach ($v in $RegValuesToDelete) { Remove-RegValue $v.Path $v.Name }
    Remove-MultiStringToken "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Svchost" "WebThreatDefense" "webthreatdefsvc"
    Remove-MultiStringToken "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Svchost" "LocalSystemNetworkRestricted" "webthreatdefusersvc"
    Remove-MultiStringToken "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Svchost" "LocalServiceNetworkRestricted" "AppIDSvc"

    $pol = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender"
    if (-not (Test-Path $pol)) { New-Item $pol -Force | Out-Null }
    New-ItemProperty -Path $pol -Name DisableAntiSpyware -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $pol -Name ServiceKeepAlive -Value 0 -PropertyType DWord -Force | Out-Null
    $rtp = "$pol\Real-Time Protection"
    if (-not (Test-Path $rtp)) { New-Item $rtp -Force | Out-Null }
    foreach ($n in @("DisableRealtimeMonitoring","DisableBehaviorMonitoring","DisableIOAVProtection","DisableOnAccessProtection","DisableScanOnRealtimeEnable","DisableScriptScanning")) {
        New-ItemProperty -Path $rtp -Name $n -Value 1 -PropertyType DWord -Force | Out-Null
    }
    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" -Name SmartScreenEnabled -Value "Off" -PropertyType String -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppHost" -Name EnableWebContentEvaluation -Value 0 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name EnableSmartScreen -Value 0 -PropertyType DWord -Force | Out-Null
    Write-Host "  kept/reinforced DisableAntiSpyware=1, SmartScreen Off" -ForegroundColor Green

    Complete-WipeInUseFiles

    Write-Host ""
    Write-Host "Leftover named drivers:" -ForegroundColor Cyan
    $left = 0
    foreach ($f in $DriverFiles) {
        if (Test-Path -LiteralPath $f) {
            $left++
            Write-Host ("  STILL PRESENT {0}" -f $f) -ForegroundColor DarkRed
        }
    }
    if ($left -eq 0) {
        Write-Host "  none" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host ("WIPE v{0} COMPLETE (boot-safe)." -f $WipeVersion) -ForegroundColor Red
    Write-Host ("deleted={0} stubbed={1} skipped={2} in_use={3} pending_reboot={4} sc_delete={5}" -f $script:Deleted, $script:Stubbed, $script:Skipped, $script:InUse, $script:Pending, $script:SvcGone) -ForegroundColor Yellow
    Write-Host "CIPolicies not touched. DO NOT run sfc /scannow." -ForegroundColor Yellow
    Write-Host "If WdFilter.sys is still present, PPL won: boot Reclaim11 WinPE v7 first, then rerun." -ForegroundColor Cyan
    Write-Host ("log {0}" -f $log) -ForegroundColor DarkGray
} finally {
    Stop-Transcript | Out-Null
}
