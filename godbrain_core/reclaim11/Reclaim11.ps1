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
if ($sta -ne "STA") {
    $pwsh = Join-Path $PSHOME "pwsh.exe"
    if (-not (Test-Path -LiteralPath $pwsh)) { $pwsh = (Get-Command pwsh).Source }
    $arg = @(
        "-STA", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $MyInvocation.MyCommand.Path
    )
    if ($WinPeLog) { $arg += @("-WinPeLog", $WinPeLog) }
    Start-Process -FilePath $pwsh -ArgumentList $arg
    return
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$xamlPath = Join-Path $here "ui\MainWindow.xaml"
[xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

function Get-Ui([string]$Name) { $window.FindName($Name) }

$btnScan = Get-Ui BtnScan
$btnPrep = Get-Ui BtnPrep
$btnSafe = Get-Ui BtnSafe
$btnXbox = Get-Ui BtnXbox
$btnKill = Get-Ui BtnKill
$logBox  = Get-Ui LogBox
$script:LastInventory = $null

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
    $btnSafe.IsEnabled = [bool]$inv.gates.killing_blows
    $btnXbox.IsEnabled = $true
    $btnKill.IsEnabled = [bool]$inv.gates.killing_blows
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

$btnSafe.Add_Click({
    $unlocked = $false
    if ($script:LastInventory -and $script:LastInventory.gates) {
        $unlocked = [bool]$script:LastInventory.gates.killing_blows
    }
    if (-not $unlocked) {
        [System.Windows.MessageBox]::Show(
            "Safe cleanse stays locked until a WinPE receipt exists.",
            "Reclaim11") | Out-Null
        return
    }
    $q = [System.Windows.MessageBox]::Show(
        "Move pack-A files to C:\reclaim11\backup\<stamp>\ and write restore.json. Does not delete. Never BFE/mpssvc/FltMgr. Continue?",
        "Reclaim11 Safe cleanse",
        "YesNo",
        "Warning")
    if ($q -ne "Yes") { return }
    try {
        $plan = Invoke-Reclaim11NoobCleanse -Root $here
        Add-Log ("safe cleanse moved {0} -> {1}" -f @($plan.items).Count, $plan.backup_root)
        Add-Log ("manifest {0}" -f $plan.manifest_path)
        [System.Windows.MessageBox]::Show(
            ("Moved {0} files.`n{1}`nRestore: Restore-Reclaim11Noob.ps1 -Manifest restore.json" -f @($plan.items).Count, $plan.manifest_path),
            "Reclaim11 Safe cleanse") | Out-Null
    } catch {
        Add-Log ("SAFE FAIL  {0}" -f $_.Exception.Message)
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Reclaim11 Safe cleanse") | Out-Null
    }
})

$btnXbox.Add_Click({
    $q = [System.Windows.MessageBox]::Show(
        "Hide Xbox Game Bar in Settings (Captures + Game Mode stay) and sc delete Xbox usermode services. Does not delete xboxgip (controller). Never BFE/mpssvc/FltMgr. Desk/IoT is refused. Continue?",
        "Reclaim11 Hide Xbox",
        "YesNo",
        "Warning")
    if ($q -ne "Yes") { return }
    try {
        $plan = Invoke-Reclaim11XboxCleanse -Root $here
        Add-Log ("xbox hide {0}" -f $plan.hide_pages)
        Add-Log ("xbox sc_delete {0}" -f (@($plan.sc_delete) -join ", "))
        [System.Windows.MessageBox]::Show(
            ("Settings hide set.`nsc delete: {0}`nRe-open Settings. Captures + Game Mode stay." -f ((@($plan.sc_delete) -join ", "))),
            "Reclaim11 Hide Xbox") | Out-Null
    } catch {
        Add-Log ("XBOX FAIL  {0}" -f $_.Exception.Message)
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Reclaim11 Hide Xbox") | Out-Null
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

$btnKill.Add_Click({
    $unlocked = $false
    if ($script:LastInventory -and $script:LastInventory.gates) {
        $unlocked = [bool]$script:LastInventory.gates.killing_blows
    }
    if (-not $unlocked) {
        [System.Windows.MessageBox]::Show(
            "Killing blows stay locked until a WinPE receipt exists.",
            "Reclaim11") | Out-Null
        return
    }
    $q = [System.Windows.MessageBox]::Show(
        "Mutate pack A on THIS Windows (IFEO + sc delete WinDefend/Sense/AppID). Never BFE/mpssvc/FltMgr. Desk/IoT is refused. Continue?",
        "Reclaim11 killing blows",
        "YesNo",
        "Warning")
    if ($q -ne "Yes") { return }
    try {
        $plan = Invoke-Reclaim11KillingBlows -Root $here
        Add-Log ("killing blows applied {0}" -f @($plan.applied).Count)
        foreach ($a in @($plan.applied)) { Add-Log ("  {0}" -f $a) }
        [System.Windows.MessageBox]::Show("Pack A killing blows applied. BFE/mpssvc must still be Running.", "Reclaim11") | Out-Null
    } catch {
        Add-Log ("KILL FAIL  {0}" -f $_.Exception.Message)
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Reclaim11 killing blows") | Out-Null
    }
})

$window.Add_Loaded({
    try {
        Show-Inventory (Get-Reclaim11Inventory -Root $here -WinPeLog $WinPeLog)
    } catch {
        Add-Log ("boot scan FAIL  {0}" -f $_.Exception.Message)
    }
})

[void]$window.ShowDialog()
