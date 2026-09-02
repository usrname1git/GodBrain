# ================================================
# FINAL NUCLEAR DEFENDER WIPE v6.3 - boot-safe
# ================================================
# v6.2 copied DefenderStub.exe over kernel .sys and over
# CodeIntegrity\CIPolicies\Active *.cip, then DENY SYSTEM.
# That is Automatic Repair ("couldn't be repaired") on 25H2.
#
# v6.3:
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
#
# pwsh -NoProfile -ExecutionPolicy Bypass -File NuclearDefenderWipe-V6_3.ps1
# pwsh -NoProfile -File NuclearDefenderWipe-V6_3.ps1 -SelfTest

[CmdletBinding()]
param(
    [switch]$SelfTest
)

$ErrorActionPreference = "Continue"
$WipeVersion = "6.3"

Write-Host ("=== FINAL NUCLEAR WIPE v{0} (boot-safe) ===" -f $WipeVersion) -ForegroundColor Red

$StubPath = "C:\Tools\DefenderStub.exe"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($here)) { $here = $PWD.Path }

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
    "WaaSMedicAgent.exe", "usoclient.exe", "musnotification.exe", "musnotificationux.exe",
    "UpdateNotificationMgr.exe",
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
    "wdf01000.sys", "WdfLdr.sys", "WdiWiFi.sys", "appidsvc.dll"
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
    foreach ($n in @(
            "MsMpEng", "NisSrv", "MpDefenderCoreService", "MpDlpService", "MsSense",
            "SecurityHealthSystray", "SecurityHealthHost", "SecurityHealthService",
            "smartscreen", "SenseIR", "SenseCE"
        )) {
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
    if ($fail -gt 0) {
        throw ("Nuclear v6.3 -SelfTest failed ({0})" -f $fail)
    }
    Write-Host "SELFTEST v6.3 ok" -ForegroundColor Green
}

if ($SelfTest) {
    Test-WipeSelf
    return
}

Write-Host "Deletes named drivers. Stubs usermode Defender trees. Never CIPolicies. Never stub .sys." -ForegroundColor Yellow

if (-not (Test-PeMz $StubPath)) {
    throw "DefenderStub.exe is missing or not a PE (MZ). Build C:\Tools\DefenderStub.c with cl /ENTRY:mainCRTStartup /SUBSYSTEM:WINDOWS /NODEFAULTLIB kernel32.lib. Do not copy DefenderStub.cmd to .exe."
}

$log = Join-Path $here ("FINAL NUCLEAR WIPE v{0}.txt" -f $WipeVersion)
Start-Transcript -Path $log -Force | Out-Null
try {
    $script:SecureBootOn = Get-WipeSecureBootOn
    Write-Host ("Secure Boot enabled={0} (WdBoot delete refused when on)" -f $script:SecureBootOn) -ForegroundColor Cyan

    Write-Host "Setting IFEO redirects..." -ForegroundColor Cyan
    foreach ($exe in $Targets) {
        $key = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$exe"
        New-Item -Path $key -Force | Out-Null
        New-ItemProperty -Path $key -Name "Debugger" -Value $StubPath -PropertyType String -Force | Out-Null
    }

    Write-Host "Removing Defender-only services..." -ForegroundColor Cyan
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

    Write-Host "Cleaning Defender registry leftovers..." -ForegroundColor Cyan
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
