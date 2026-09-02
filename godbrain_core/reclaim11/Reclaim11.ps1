# Reclaim11 launcher. WPF around inventory. Not Heal. Not Galaxy. No irm|iex.
[CmdletBinding()]
param(
    [switch]$InventoryOnly,
    [switch]$KillingBlows,
    [string]$OutJson = "",
    [string]$WinPeLog = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($ExecutionContext.SessionState.LanguageMode -ne "FullLanguage") {
    throw "Reclaim11: PowerShell is ConstrainedLanguage. FullLanguage required."
}

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "inventory.ps1")
. (Join-Path $here "killing_blows.ps1")
. (Join-Path $here "noob_cleanse.ps1")
. (Join-Path $here "xbox_cleanse.ps1")

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

$sta = [Threading.Thread]::CurrentThread.GetApartmentState()
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if ($sta -ne "STA" -or -not $admin) {
    $pwsh = Join-Path $PSHOME "pwsh.exe"
    if (-not (Test-Path -LiteralPath $pwsh)) { $pwsh = (Get-Command pwsh).Source }
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

$btnScan = Get-Ui BtnScan
$btnPrep = Get-Ui BtnPrep
$btnSafe = Get-Ui BtnSafe
$btnXbox = Get-Ui BtnXbox
$btnKill = Get-Ui BtnKill
$btnRun  = Get-Ui BtnRun
$togHideCaptures = Get-Ui TogHideCaptures
$logBox  = Get-Ui LogBox
$script:LastInventory = $null
$script:ProcessRunning = $false

function Add-Log([string]$Line) {
    $logBox.AppendText($Line + [Environment]::NewLine)
    $logBox.ScrollToEnd()
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
    $btnKill.IsEnabled = $pe
    if (-not $pe) { $btnKill.IsChecked = $false }
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
    Add-Log "scan is read-only. Safe cleanse / killing blows mutate only after a WinPE receipt, not on IoTEnterpriseS."
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
    $btnScan.IsEnabled = $false
    try {
        $doSafe = [bool]$btnSafe.IsChecked
        $doXbox = [bool]$btnXbox.IsChecked
        $doKill = [bool]$btnKill.IsChecked
        if (-not ($doSafe -or $doXbox -or $doKill)) {
            [System.Windows.MessageBox]::Show("Tick Safe cleanse, Hide Xbox, and/or Killing blows.", "Reclaim11") | Out-Null
            return
        }
        $unlocked = $false
        if ($script:LastInventory -and $script:LastInventory.gates) {
            $unlocked = [bool]$script:LastInventory.gates.killing_blows
        }
        if (($doSafe -or $doKill) -and -not $unlocked) {
            [System.Windows.MessageBox]::Show(
                "Safe cleanse / killing blows stay locked until a WinPE receipt exists.",
                "Reclaim11") | Out-Null
            return
        }
        $q = [System.Windows.MessageBox]::Show(
            "Run the ticked actions on THIS Windows. restore.json is written first where it applies. Never BFE/mpssvc/FltMgr. Desk/IoT is refused. Continue?",
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
        if ($doKill) {
            try {
                $plan = Invoke-Reclaim11KillingBlows -Root $here
                Add-Log ("killing blows applied {0}" -f @($plan.applied).Count)
            } catch {
                Add-Log ("KILL FAIL  {0}" -f $_.Exception.Message)
                [System.Windows.MessageBox]::Show($_.Exception.Message, "Reclaim11 killing blows") | Out-Null
            }
        }
    } finally {
        $script:ProcessRunning = $false
        $btnRun.IsEnabled = $true
        $btnScan.IsEnabled = $true
    }
})

$btnPrep.Add_Click({
    $repoRoot = Split-Path -Parent (Split-Path -Parent $here)
    $build = Join-Path $repoRoot "scripts\New-Reclaim11WinPeIso.ps1"
    $iso = "C:\nvme\reclaim11\Reclaim11-WinPE-v7.iso"
    if (-not (Test-Path -LiteralPath $iso)) { $iso = "C:\nvme\reclaim11\Reclaim11-WinPE.iso" }
    $msg = if (Test-Path -LiteralPath $iso) {
        "ISO ready:`n$iso`n`nAttach in VMware (not USB). Snapshot first. Boot the ISO, then disconnect and wpeutil reboot. Operator PE deletes pack-A .sys (no sidecar .bak). This GUI Safe cleanse moves files to backup + restore.json."
    } else {
        "No ISO yet. Elevated (ADK + WinPE addon 10.1.26100.2454, not 28000):`n`npwsh -NoProfile -File `"$build`" -OutIso `"C:\nvme\reclaim11\Reclaim11-WinPE-v7.iso`"`n`nVMware first. Snapshot before boot. Not a physical USB."
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
