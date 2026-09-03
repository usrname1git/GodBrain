# Reclaim11 launcher. WPF around inventory. Not Heal. Not Galaxy. No irm|iex.
[CmdletBinding()]
param(
    [switch]$InventoryOnly,
    [switch]$KillingBlows,
    [Alias("T")]
    [switch]$Test,
    [string]$OutJson = "",
    [string]$WinPeLog = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($ExecutionContext.SessionState.LanguageMode -ne "FullLanguage") {
    throw "Reclaim11: PowerShell is ConstrainedLanguage. FullLanguage required."
}

$ps1Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ps1Dir "inventory.ps1")
$here = Get-Reclaim11Root
. (Join-Path $ps1Dir "killing_blows.ps1")
. (Join-Path $ps1Dir "noob_cleanse.ps1")
. (Join-Path $ps1Dir "xbox_cleanse.ps1")
. (Join-Path $ps1Dir "telemetry_cleanse.ps1")
. (Join-Path $ps1Dir "nic_tune.ps1")

function Write-Reclaim11InventoryFile {
    param($Inventory, [string]$Path)
    $json = ConvertTo-Reclaim11Json -Inventory $Inventory
    if ($Path) {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir | Out-Null
        }
        Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
    }
    $json
}

if ($InventoryOnly) {
    $inv = Get-Reclaim11Inventory -Root $here -WinPeLog $WinPeLog
    $json = Write-Reclaim11InventoryFile -Inventory $inv -Path $OutJson
    Write-Output $json
    return
}

if ($KillingBlows) {
    $plan = Invoke-Reclaim11KillingBlows -Root $here
    $plan | ConvertTo-Json -Depth 6
    return
}

if ($Test) {
    Write-Host "TEST ONLY (DeviceCleanupCmd -t). mutate=false."
    $keepCap = $false
    $xbox = Invoke-Reclaim11XboxCleanse -Root $here -WhatIf -KeepCaptures:$keepCap
    Write-Host (Format-Reclaim11TestReport -Plan $xbox -Title "xbox_cleanse")
    $tel = Invoke-Reclaim11TelemetryCleanse -Root $here -WhatIf
    Write-Host (Format-Reclaim11TestReport -Plan $tel -Title "telemetry_cleanse")
    $kill = Invoke-Reclaim11KillingBlows -Root $here -WhatIf
    Write-Host (Format-Reclaim11TestReport -Plan $kill -Title "killing_blows")
    $safe = Invoke-Reclaim11NoobCleanse -Root $here -WhatIf
    Write-Host (Format-Reclaim11TestReport -Plan $safe -Title "safe_cleanse")
    $nic = Invoke-Reclaim11NicTune -Root $here -WhatIf
    Write-Host (Format-Reclaim11TestReport -Plan $nic -Title "nic_tune")
    if ($OutJson) {
        $bundle = [pscustomobject]@{
            what_if = $true
            mutate  = $false
            xbox    = $xbox
            telemetry = $tel
            killing = $kill
            safe    = $safe
            nic     = $nic
        }
        Write-Reclaim11InventoryFile -Inventory $bundle -Path $OutJson | Out-Null
    }
    return
}

$sta = [Threading.Thread]::CurrentThread.GetApartmentState()
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if ($sta -ne "STA" -or -not $admin) {
    $pwsh = Get-Reclaim11Pwsh
    $arg = @(
        "-STA", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $MyInvocation.MyCommand.Path
    )
    if ($WinPeLog) { $arg += @("-WinPeLog", $WinPeLog) }
    if (-not $admin) {
        Start-Process -FilePath $pwsh -ArgumentList $arg -Verb RunAs
    } else {
        Start-Process -FilePath $pwsh -ArgumentList $arg
    }
    return
}

try { $Host.UI.RawUI.WindowTitle = "Reclaim11" } catch { }

$logRoot = [Environment]::GetFolderPath("LocalApplicationData")
if (-not $logRoot) { $logRoot = $env:TEMP }
$logDir = Join-Path $logRoot "Reclaim11\logs"
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$guiLog = Join-Path $logDir ("gui-" + [datetime]::UtcNow.ToString("yyyyMMddTHHmmssZ") + ".log")
Start-Transcript -Path $guiLog -Append | Out-Null

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$xamlPath = Join-Path $here "ui\MainWindow.xaml"
try {
    [xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)
} catch {
    Stop-Transcript | Out-Null
    throw "Reclaim11: XAML load failed: $($_.Exception.Message)"
}

function Get-Ui([string]$Name) { $window.FindName($Name) }

function Invoke-Reclaim11GrimReaperCli {
    param([switch]$WhatIf)
    $script = Join-Path $ps1Dir "grim_reaper.ps1"
    if (-not (Test-Path -LiteralPath $script)) {
        throw "Reclaim11: missing grim_reaper.ps1"
    }
    $pwsh = Get-Reclaim11Pwsh
    $arg = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $script)
    if ($WhatIf) { $arg += "-T" }
    $out = & $pwsh @arg 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw ("grim_reaper exit {0}`n{1}" -f $LASTEXITCODE, $out)
    }
    $out
}

$btnScan = Get-Ui BtnScan
$btnPrep = Get-Ui BtnPrep
$btnSafe = Get-Ui BtnSafe
$btnXbox = Get-Ui BtnXbox
$btnTelemetry = Get-Ui BtnTelemetry
$btnNic = Get-Ui BtnNic
$btnKill = Get-Ui BtnKill
$btnReaper = Get-Ui BtnReaper
$btnRun  = Get-Ui BtnRun
$btnTest = Get-Ui BtnTest
$togHideCaptures = Get-Ui TogHideCaptures
$logBox  = Get-Ui LogBox
$panelDoor = Get-Ui PanelDoor
$panelNoob = Get-Ui PanelNoob
$panelExpert = Get-Ui PanelExpert
$noobLog = Get-Ui NoobLog
$btnDoorNoob = Get-Ui BtnDoorNoob
$btnDoorExpert = Get-Ui BtnDoorExpert
$btnNoobBack = Get-Ui BtnNoobBack
$btnExpertBack = Get-Ui BtnExpertBack
$btnNoobTest = Get-Ui BtnNoobTest
$btnNoobFix = Get-Ui BtnNoobFix
$btnNoobXbox = Get-Ui BtnNoobXbox
$btnNoobTel = Get-Ui BtnNoobTel
$btnNoobSafe = Get-Ui BtnNoobSafe
$script:LastInventory = $null
$script:ProcessRunning = $false
$script:UiDoor = "door"

function Add-Log([string]$Line) {
    $logBox.AppendText($Line + [Environment]::NewLine)
    $logBox.ScrollToEnd()
}

function Add-NoobLog([string]$Line) {
    $noobLog.AppendText($Line + [Environment]::NewLine)
    $noobLog.ScrollToEnd()
}

function Show-Reclaim11Door([string]$Name) {
    $script:UiDoor = $Name
    $panelDoor.Visibility = [Windows.Visibility]::Collapsed
    $panelNoob.Visibility = [Windows.Visibility]::Collapsed
    $panelExpert.Visibility = [Windows.Visibility]::Collapsed
    switch ($Name) {
        "noob" { $panelNoob.Visibility = [Windows.Visibility]::Visible }
        "expert" { $panelExpert.Visibility = [Windows.Visibility]::Visible }
        default { $panelDoor.Visibility = [Windows.Visibility]::Visible }
    }
}

function Show-Inventory($inv) {
    $script:LastInventory = $inv
    (Get-Ui OsPin).Text = $inv.os.os_pin
    $sb = $inv.secure_boot
    (Get-Ui SecureBoot).Text = if ($sb.available) {
        if ($sb.enabled) { "ON  (WdBoot stub refused)" } else { "off  (WdBoot stub allowed offline)" }
    } else { "n/a  $($sb.error)" }
    $bl = $inv.bitlocker_c
    (Get-Ui BitLocker).Text = if ($bl.present) { "$($bl.protection) / $($bl.volume_status)" } else { "not present / $($bl.error)" }
    (Get-Ui NeverTouch).Text = if ($inv.never_touch_ok) { "BFE + mpssvc RUNNING" } else { "FAIL  do not continue" }
    (Get-Ui WdBootGate).Text = $inv.gates.reason_wdboot
    $btnPrep.IsEnabled = [bool]$inv.gates.prep_media
    $pe = [bool]$inv.gates.killing_blows
    $btnSafe.IsEnabled = $pe
    if (-not $pe) { $btnSafe.IsChecked = $false }
    $btnXbox.IsEnabled = $true
    $btnTelemetry.IsEnabled = $true
    $btnKill.IsEnabled = $pe
    if (-not $pe) { $btnKill.IsChecked = $false }
    $btnReaper.IsEnabled = $pe
    if (-not $pe) { $btnReaper.IsChecked = $false }
    $btnNoobSafe.IsEnabled = $pe
    $logBox.Clear()
    Add-Log ("at        {0}" -f $inv.at)
    Add-Log ("catalog   {0}" -f $inv.catalog)
    Add-Log ("os_pin    {0}" -f $inv.os.os_pin)
    Add-Log ("sku       {0}" -f $inv.os.edition_id)
    Add-Log ("firmware  {0}" -f $inv.os.firmware)
    Add-Log ("secure_boot enabled={0} available={1}" -f $inv.secure_boot.enabled, $inv.secure_boot.available)
    Add-Log ("bitlocker {0}" -f (Get-Ui BitLocker).Text)
    Add-Log ("never_touch_ok {0}" -f $inv.never_touch_ok)
    Add-Log ("stub_exe  exists={0} {1}" -f $inv.stub_exe_exists, $inv.stub_exe)
    Add-Log ("prep_media={0} stub_wdboot={1} killing_blows={2}" -f $inv.gates.prep_media, $inv.gates.stub_wdboot, $inv.gates.killing_blows)
    Add-Log $inv.gates.reason_wdboot
    Add-Log $inv.gates.reason_killing_blows
    Add-Log "--- services (pack A + never-touch) ---"
    foreach ($s in $inv.services) {
        Add-Log ("  {0,-24} present={1,-5} {2}" -f $s.name, $s.present, $s.status)
    }
    Add-Log ("winpe_log {0}" -f $inv.gates.winpe_log)
    Add-Log "scan is read-only. MUST boot a WinPE ISO for Defender. No receipt = bloat only. Safe / killing blows / Grim Reaper stay locked, not on IoTEnterpriseS."
}

$btnScan.Add_Click({
    try {
        $inv = Get-Reclaim11Inventory -Root $here -WinPeLog $WinPeLog
        Show-Inventory $inv
    } catch {
        Add-Log ("SCAN FAIL  {0}" -f $_.Exception.Message)
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Reclaim11 scan failed") | Out-Null
    }
})

$btnRun.Add_Click({
    if ($script:ProcessRunning) { return }
    $script:ProcessRunning = $true
    $btnRun.IsEnabled = $false
    $btnTest.IsEnabled = $false
    $btnScan.IsEnabled = $false
    try {
        $doSafe = [bool]$btnSafe.IsChecked
        $doXbox = [bool]$btnXbox.IsChecked
        $doTelemetry = [bool]$btnTelemetry.IsChecked
        $doNic = [bool]$btnNic.IsChecked
        $doKill = [bool]$btnKill.IsChecked
        $doReaper = [bool]$btnReaper.IsChecked
        if (-not ($doSafe -or $doXbox -or $doTelemetry -or $doNic -or $doKill -or $doReaper)) {
            [System.Windows.MessageBox]::Show("Tick Safe cleanse, Hide Xbox, telemetry, NIC, Killing blows, and/or Send Grim Reaper.", "Reclaim11") | Out-Null
            return
        }
        $unlocked = $false
        if ($script:LastInventory -and $script:LastInventory.gates) {
            $unlocked = [bool]$script:LastInventory.gates.killing_blows
        }
        if (($doSafe -or $doKill -or $doReaper) -and -not $unlocked) {
            [System.Windows.MessageBox]::Show(
                "Safe cleanse / killing blows / Grim Reaper stay locked until a WinPE receipt exists.",
                "Reclaim11") | Out-Null
            return
        }
        $warn = "Run the ticked actions on THIS Windows. restore.json is written first where it applies. Never BFE/mpssvc/FltMgr. Desk/IoT is refused. Continue?"
        if ($doReaper) {
            $warn = "Send Grim Reaper on THIS Windows. WU/Medic/USO die. Defender trees stub+DACL. After PE. Never BFE. Desk refused. Continue?"
        }
        $q = [System.Windows.MessageBox]::Show(
            $warn,
            "Reclaim11 RUN SELECTED",
            "YesNo",
            "Warning")
        if ($q -ne "Yes") { return }
        if ($doSafe) {
            try {
                $plan = Invoke-Reclaim11NoobCleanse -Root $here
                Add-Log ("safe cleanse moved {0} -> {1}" -f @($plan.items).Count, $plan.backup_root)
                Add-Log ("manifest {0}" -f $plan.manifest_path)
            } catch {
                Add-Log ("SAFE FAIL  {0}" -f $_.Exception.Message)
                [System.Windows.MessageBox]::Show($_.Exception.Message, "Reclaim11 Safe cleanse") | Out-Null
            }
        }
        if ($doXbox) {
            try {
                $keepCap = -not [bool]$togHideCaptures.IsChecked
                $plan = Invoke-Reclaim11XboxCleanse -Root $here -KeepCaptures:$keepCap
                Add-Log ("xbox hide {0}" -f $plan.settings_page_visibility.after)
                Add-Log ("manifest {0}" -f $plan.manifest_path)
            } catch {
                Add-Log ("XBOX FAIL  {0}" -f $_.Exception.Message)
                [System.Windows.MessageBox]::Show($_.Exception.Message, "Reclaim11 Hide Xbox") | Out-Null
            }
        }
        if ($doTelemetry) {
            try {
                $plan = Invoke-Reclaim11TelemetryCleanse -Root $here
                Add-Log ("telemetry disabled {0}" -f (@($plan.sc_disabled) -join ","))
                Add-Log ("manifest {0}" -f $plan.manifest_path)
            } catch {
                Add-Log ("TELEMETRY FAIL  {0}" -f $_.Exception.Message)
                [System.Windows.MessageBox]::Show($_.Exception.Message, "Reclaim11 telemetry") | Out-Null
            }
        }
        if ($doNic) {
            try {
                $plan = Invoke-Reclaim11NicTune -Root $here
                Add-Log ("nic applied {0}" -f (@($plan.applied).Count))
                Add-Log ("manifest {0}" -f $plan.manifest_path)
            } catch {
                Add-Log ("NIC FAIL  {0}" -f $_.Exception.Message)
                [System.Windows.MessageBox]::Show($_.Exception.Message, "Reclaim11 NIC tune") | Out-Null
            }
        }
        if ($doKill) {
            try {
                $plan = Invoke-Reclaim11KillingBlows -Root $here
                Add-Log ("killing blows applied {0}" -f @($plan.applied).Count)
                if ($plan.PSObject.Properties["manifest_path"] -and $plan.manifest_path) {
                    Add-Log ("manifest {0}" -f $plan.manifest_path)
                }
                if ($plan.PSObject.Properties["backup_root"] -and $plan.backup_root) {
                    Add-Log ("backup {0}" -f $plan.backup_root)
                }
            } catch {
                Add-Log ("KILL FAIL  {0}" -f $_.Exception.Message)
                [System.Windows.MessageBox]::Show($_.Exception.Message, "Reclaim11 killing blows") | Out-Null
            }
        }
        if ($doReaper) {
            try {
                $out = Invoke-Reclaim11GrimReaperCli
                Add-Log $out.TrimEnd()
                Add-Log "grim reaper done"
            } catch {
                Add-Log ("GRIM FAIL  {0}" -f $_.Exception.Message)
                [System.Windows.MessageBox]::Show($_.Exception.Message, "Reclaim11 Grim Reaper") | Out-Null
            }
        }
    } finally {
        $script:ProcessRunning = $false
        $btnRun.IsEnabled = $true
        $btnTest.IsEnabled = $true
        $btnScan.IsEnabled = $true
    }
})

$btnTest.Add_Click({
    if ($script:ProcessRunning) { return }
    $script:ProcessRunning = $true
    $btnRun.IsEnabled = $false
    $btnTest.IsEnabled = $false
    $btnScan.IsEnabled = $false
    try {
        $doSafe = [bool]$btnSafe.IsChecked
        $doXbox = [bool]$btnXbox.IsChecked
        $doTelemetry = [bool]$btnTelemetry.IsChecked
        $doNic = [bool]$btnNic.IsChecked
        $doKill = [bool]$btnKill.IsChecked
        $doReaper = [bool]$btnReaper.IsChecked
        if (-not ($doSafe -or $doXbox -or $doTelemetry -or $doNic -or $doKill -or $doReaper)) {
            [System.Windows.MessageBox]::Show("Tick Safe cleanse, Hide Xbox, telemetry, NIC, Killing blows, and/or Send Grim Reaper.", "Reclaim11") | Out-Null
            return
        }
        Add-Log "TEST ONLY (DeviceCleanupCmd -t). mutate=false."
        if ($doSafe) {
            $plan = Invoke-Reclaim11NoobCleanse -Root $here -WhatIf
            Add-Log (Format-Reclaim11TestReport -Plan $plan -Title "safe_cleanse")
        }
        if ($doXbox) {
            $keepCap = -not [bool]$togHideCaptures.IsChecked
            $plan = Invoke-Reclaim11XboxCleanse -Root $here -WhatIf -KeepCaptures:$keepCap
            Add-Log (Format-Reclaim11TestReport -Plan $plan -Title "xbox_cleanse")
        }
        if ($doTelemetry) {
            $plan = Invoke-Reclaim11TelemetryCleanse -Root $here -WhatIf
            Add-Log (Format-Reclaim11TestReport -Plan $plan -Title "telemetry_cleanse")
        }
        if ($doNic) {
            $plan = Invoke-Reclaim11NicTune -Root $here -WhatIf
            Add-Log (Format-Reclaim11TestReport -Plan $plan -Title "nic_tune")
        }
        if ($doKill) {
            $plan = Invoke-Reclaim11KillingBlows -Root $here -WhatIf
            Add-Log (Format-Reclaim11TestReport -Plan $plan -Title "killing_blows")
        }
        if ($doReaper) {
            Add-Log (Invoke-Reclaim11GrimReaperCli -WhatIf)
        }
    } catch {
        Add-Log ("TEST FAIL  {0}" -f $_.Exception.Message)
    } finally {
        $script:ProcessRunning = $false
        $btnRun.IsEnabled = $true
        $btnTest.IsEnabled = $true
        $btnScan.IsEnabled = $true
    }
})

$btnDoorNoob.Add_Click({
    Show-Reclaim11Door "noob"
    try {
        Show-Inventory (Get-Reclaim11Inventory -Root $here -WinPeLog $WinPeLog)
        Add-NoobLog "Noob door. TEST FIRST lists what would happen. JUST FIX MY SH*T = Xbox + telemetry after TEST. Killing blows live on the expert door."
    } catch {
        Add-NoobLog ("scan FAIL  {0}" -f $_.Exception.Message)
    }
})
$btnDoorExpert.Add_Click({ Show-Reclaim11Door "expert" })
$btnNoobBack.Add_Click({ Show-Reclaim11Door "door" })
$btnExpertBack.Add_Click({ Show-Reclaim11Door "door" })

$btnNoobTest.Add_Click({
    if ($script:ProcessRunning) { return }
    $script:ProcessRunning = $true
    try {
        Add-NoobLog "TEST ONLY. mutate=false."
        $keepCap = -not [bool]$togHideCaptures.IsChecked
        $xbox = Invoke-Reclaim11XboxCleanse -Root $here -WhatIf -KeepCaptures:$keepCap
        Add-NoobLog (Format-Reclaim11TestReport -Plan $xbox -Title "xbox")
        $tel = Invoke-Reclaim11TelemetryCleanse -Root $here -WhatIf
        Add-NoobLog (Format-Reclaim11TestReport -Plan $tel -Title "telemetry")
        $pe = $false
        if ($script:LastInventory -and $script:LastInventory.gates) {
            $pe = [bool]$script:LastInventory.gates.killing_blows
        }
        if ($pe) {
            $safe = Invoke-Reclaim11NoobCleanse -Root $here -WhatIf
            Add-NoobLog (Format-Reclaim11TestReport -Plan $safe -Title "safe")
        }
    } catch {
        Add-NoobLog ("TEST FAIL  {0}" -f $_.Exception.Message)
    } finally { $script:ProcessRunning = $false }
})

$btnNoobFix.Add_Click({
    if ($script:ProcessRunning) { return }
    $q = [System.Windows.MessageBox]::Show(
        "TEST already listed Xbox + telemetry. This RUNS them on THIS Windows. restore.json first. Not Grim Reaper. Desk/IoT refused. Continue?",
        "Reclaim11 JUST FIX MY SH*T",
        "YesNo",
        "Warning")
    if ($q -ne "Yes") { return }
    $script:ProcessRunning = $true
    try {
        $keepCap = -not [bool]$togHideCaptures.IsChecked
        try {
            $plan = Invoke-Reclaim11XboxCleanse -Root $here -KeepCaptures:$keepCap
            Add-NoobLog ("xbox  {0}" -f $plan.manifest_path)
        } catch { Add-NoobLog ("XBOX FAIL  {0}" -f $_.Exception.Message) }
        try {
            $plan = Invoke-Reclaim11TelemetryCleanse -Root $here
            Add-NoobLog ("telemetry  {0}" -f $plan.manifest_path)
        } catch { Add-NoobLog ("TELEMETRY FAIL  {0}" -f $_.Exception.Message) }
    } finally { $script:ProcessRunning = $false }
})

$btnNoobXbox.Add_Click({
    if ($script:ProcessRunning) { return }
    $q = [System.Windows.MessageBox]::Show(
        "Hide Xbox + Appx bloat on THIS Windows. restore.json first. Game Mode stays. Continue?",
        "Reclaim11 HIDE XBOX",
        "YesNo",
        "Warning")
    if ($q -ne "Yes") { return }
    $script:ProcessRunning = $true
    try {
        $keepCap = -not [bool]$togHideCaptures.IsChecked
        $plan = Invoke-Reclaim11XboxCleanse -Root $here -KeepCaptures:$keepCap
        Add-NoobLog ("xbox  {0}" -f $plan.manifest_path)
    } catch {
        Add-NoobLog ("XBOX FAIL  {0}" -f $_.Exception.Message)
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Reclaim11 Hide Xbox") | Out-Null
    } finally { $script:ProcessRunning = $false }
})

$btnNoobTel.Add_Click({
    if ($script:ProcessRunning) { return }
    $q = [System.Windows.MessageBox]::Show(
        "Disable DiagTrack + dmwappushservice, AllowTelemetry=0. restore.json first. Continue?",
        "Reclaim11 TELEMETRY",
        "YesNo",
        "Warning")
    if ($q -ne "Yes") { return }
    $script:ProcessRunning = $true
    try {
        $plan = Invoke-Reclaim11TelemetryCleanse -Root $here
        Add-NoobLog ("telemetry  {0}" -f $plan.manifest_path)
    } catch {
        Add-NoobLog ("TELEMETRY FAIL  {0}" -f $_.Exception.Message)
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Reclaim11 telemetry") | Out-Null
    } finally { $script:ProcessRunning = $false }
})

$btnNoobSafe.Add_Click({
    if ($script:ProcessRunning) { return }
    $unlocked = $false
    if ($script:LastInventory -and $script:LastInventory.gates) {
        $unlocked = [bool]$script:LastInventory.gates.killing_blows
    }
    if (-not $unlocked) {
        [System.Windows.MessageBox]::Show("Safe cleanse stays locked until a WinPE receipt exists.", "Reclaim11") | Out-Null
        return
    }
    $q = [System.Windows.MessageBox]::Show(
        "Move pack-A leftovers to backup + restore.json. Does not delete. Continue?",
        "Reclaim11 SAFE CLEANSE",
        "YesNo",
        "Warning")
    if ($q -ne "Yes") { return }
    $script:ProcessRunning = $true
    try {
        $plan = Invoke-Reclaim11NoobCleanse -Root $here
        Add-NoobLog ("safe  {0}" -f $plan.manifest_path)
    } catch {
        Add-NoobLog ("SAFE FAIL  {0}" -f $_.Exception.Message)
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Reclaim11 Safe cleanse") | Out-Null
    } finally { $script:ProcessRunning = $false }
})

$btnPrep.Add_Click({
    $repoRoot = Split-Path -Parent (Split-Path -Parent $here)
    $build = Join-Path $repoRoot "scripts\New-Reclaim11WinPeIso.ps1"
    $iso = "C:\nvme\reclaim11\Reclaim11-WinPE-v7.iso"
    if (-not (Test-Path -LiteralPath $iso)) { $iso = "C:\nvme\reclaim11\Reclaim11-WinPE.iso" }
    $msg = if (Test-Path -LiteralPath $iso) {
        "MUST boot this ISO on the target to remove Defender. In-Windows without a PE receipt is bloat only.`n`nISO ready:`n$iso`n`nAttach in VMware (not USB). Snapshot first. Boot the ISO, then disconnect and wpeutil reboot. Operator PE deletes pack-A .sys (no sidecar .bak). This GUI Safe cleanse moves files to backup + restore.json."
    } else {
        "MUST: build and boot a WinPE ISO to remove Defender. Without that boot this GUI is bloat only.`n`nNo ISO yet. Elevated (ADK + WinPE addon 10.1.26100.2454, not 28000):`n`npwsh -NoProfile -File `"$build`" -OutIso `"C:\nvme\reclaim11\Reclaim11-WinPE-v7.iso`"`n`nVMware first. Snapshot before boot. Not a physical USB."
    }
    [System.Windows.MessageBox]::Show($msg, "Reclaim11 prep media") | Out-Null
})

$window.Add_MouseLeftButtonDown({
    $src = $_.OriginalSource
    if ($src -is [System.Windows.Controls.Control]) { return }
    try { $window.DragMove() } catch { }
})

$window.Add_PreviewKeyDown({
    if ($script:ProcessRunning) { return }
    if ($_.Key -eq "Escape") { $window.Close(); $_.Handled = $true }
    if ($_.KeyboardDevice.Modifiers -eq "Ctrl" -and $_.Key -eq "Q") {
        $window.Close()
        $_.Handled = $true
    }
})

$window.Add_ContentRendered({
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $s = [System.Windows.Forms.Screen]::PrimaryScreen
        if ($s -and ($window.ActualWidth -gt $s.Bounds.Width -or $window.ActualHeight -gt $s.Bounds.Height)) {
            $window.Left = 0
            $window.Top = 0
            $window.Width = $s.Bounds.Width
            $window.Height = $s.Bounds.Height
        }
    } catch { }
})

$window.Add_Loaded({
    try {
        Show-Inventory (Get-Reclaim11Inventory -Root $here -WinPeLog $WinPeLog)
    } catch {
        Add-Log ("boot scan FAIL  {0}" -f $_.Exception.Message)
    }
})

$window.Add_Closed({
    try { Stop-Transcript | Out-Null } catch { }
})

[void]$window.ShowDialog()
