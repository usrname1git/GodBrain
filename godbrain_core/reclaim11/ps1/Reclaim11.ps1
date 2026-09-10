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
. (Join-Path $ps1Dir "latency_bake.ps1")
. (Join-Path $ps1Dir "install_pwsh.ps1")
. (Join-Path $ps1Dir "rustdesk.ps1")
. (Join-Path $ps1Dir "restore.ps1")

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
    $lat = Invoke-Reclaim11LatencyBake -Root $here -WhatIf
    Write-Host (Format-Reclaim11TestReport -Plan $lat -Title "latency_bake")
    $rd = Install-Reclaim11RustDesk -Root $here -WhatIf -PasswordMode one-time -InstallService
    Write-Host (Format-Reclaim11TestReport -Plan $rd -Title "rustdesk")
    if ($OutJson) {
        $bundle = [pscustomobject]@{
            what_if = $true
            mutate  = $false
            xbox    = $xbox
            telemetry = $tel
            killing = $kill
            safe    = $safe
            nic     = $nic
            latency = $lat
            rustdesk = $rd
        }
        Write-Reclaim11InventoryFile -Inventory $bundle -Path $OutJson | Out-Null
    }
    return
}

function Start-Reclaim11HiddenHost {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [switch]$RunAs
    )
    $quoted = New-Object System.Collections.Generic.List[string]
    foreach ($a in $ArgumentList) {
        $s = [string]$a
        if ($s -match '[\s"]') {
            [void]$quoted.Add('"' + ($s -replace '"', '""') + '"')
        } else {
            [void]$quoted.Add($s)
        }
    }
    $argLine = ($quoted -join " ")
    $verb = ""
    if ($RunAs) { $verb = "runas" }
    $app = New-Object -ComObject Shell.Application
    # 0 = SW_HIDE. Start-Process -WindowStyle Hidden opens Windows Terminal
    # as an empty black window when WT is the default console host.
    [void]$app.ShellExecute($FilePath, $argLine, "", $verb, 0)
}

$sta = [Threading.Thread]::CurrentThread.GetApartmentState()
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if ($sta -ne "STA" -or -not $admin) {
    $pwsh = Get-Reclaim11Pwsh
    $arg = @(
        "-STA", "-NoProfile", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File", $MyInvocation.MyCommand.Path
    )
    if ($WinPeLog) { $arg += @("-WinPeLog", $WinPeLog) }
    Start-Reclaim11HiddenHost -FilePath $pwsh -ArgumentList $arg -RunAs:(-not $admin)
    return
}

if ($PSVersionTable.PSVersion.Major -lt 7) {
    $pwsh7 = Show-Reclaim11PwshOffer
    if ($pwsh7) {
        $arg = @(
            "-STA", "-NoProfile", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File", $MyInvocation.MyCommand.Path
        )
        if ($WinPeLog) { $arg += @("-WinPeLog", $WinPeLog) }
        Start-Reclaim11HiddenHost -FilePath $pwsh7 -ArgumentList $arg
        return
    }
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
    if (-not $WhatIf) {
        if (-not (Get-Reclaim11WinPeReceipt)) {
            throw "Refuse: no WinPE receipt. Boot the Reclaim11 WinPE ISO first."
        }
        $wd = Join-Path $env:SystemRoot "System32\drivers\WdFilter.sys"
        if (Test-Path -LiteralPath $wd) {
            throw "Refuse: WdFilter.sys still present. PE park did not land."
        }
    }
    $pwsh = Get-Reclaim11Pwsh
    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$script`""
    if ($WhatIf) { $arg += " -T" }
    $stamp = [guid]::NewGuid().ToString("N").Substring(0, 8)
    $outFile = Join-Path $env:TEMP ("reclaim11-reaper-" + $stamp + ".out")
    $errFile = Join-Path $env:TEMP ("reclaim11-reaper-" + $stamp + ".err")
    try {
        $p = Start-Process -FilePath $pwsh -ArgumentList $arg -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $chunks = @()
        if (Test-Path -LiteralPath $outFile) {
            $chunks += Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $errFile) {
            $chunks += Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue
        }
        $out = ($chunks -join "`n")
        if ([int]$p.ExitCode -ne 0) {
            throw ("grim_reaper exit {0}`n{1}" -f $p.ExitCode, $out)
        }
        $out
    } finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

$btnScan = Get-Ui BtnScan
$btnPrep = Get-Ui BtnPrep
$btnSafe = Get-Ui BtnSafe
$btnXbox = Get-Ui BtnXbox
$btnTelemetry = Get-Ui BtnTelemetry
$btnNic = Get-Ui BtnNic
$btnLatency = Get-Ui BtnLatency
$btnKill = Get-Ui BtnKill
$btnReaper = Get-Ui BtnReaper
$btnRun  = Get-Ui BtnRun
$btnTest = Get-Ui BtnTest
$togHideCaptures = Get-Ui TogHideCaptures
$logBox  = Get-Ui LogBox
$panelBusy = Get-Ui PanelBusy
$busyBar = Get-Ui BusyBar
$busyStatus = Get-Ui BusyStatus
$panelDoor = Get-Ui PanelDoor
$panelNoob = Get-Ui PanelNoob
$panelExpert = Get-Ui PanelExpert
$noobLog = Get-Ui NoobLog
$btnDoorNoob = Get-Ui BtnDoorNoob
$btnDoorExpert = Get-Ui BtnDoorExpert
$btnDoorRestoreAll = Get-Ui BtnDoorRestoreAll
$btnDoorRestoreCustom = Get-Ui BtnDoorRestoreCustom
$btnNoobBack = Get-Ui BtnNoobBack
$btnExpertBack = Get-Ui BtnExpertBack
$btnNoobTest = Get-Ui BtnNoobTest
$btnNoobFix = Get-Ui BtnNoobFix
$btnNoobXbox = Get-Ui BtnNoobXbox
$btnNoobTel = Get-Ui BtnNoobTel
$btnNoobNic = Get-Ui BtnNoobNic
$btnNoobLatency = Get-Ui BtnNoobLatency
$btnNoobRustDesk = Get-Ui BtnNoobRustDesk
$btnNoobSafe = Get-Ui BtnNoobSafe
$btnRustDesk = Get-Ui BtnRustDesk
$actionsHeader = Get-Ui ActionsHeader
$actionsHint = Get-Ui ActionsHint
$subtitle = Get-Ui Subtitle
$footer = Get-Ui Footer

function Add-Reclaim11RowToggle {
    param($Row, $Toggle)
    if (-not $Row -or -not $Toggle) { return }
    $Row.Add_MouseLeftButtonUp({
        param($sender, $e)
        if (-not $Toggle.IsEnabled) { return }
        $walk = $e.OriginalSource
        while ($null -ne $walk) {
            if ($walk -eq $Toggle) { return }
            if ($walk -is [Windows.DependencyObject]) {
                $walk = [Windows.Media.VisualTreeHelper]::GetParent($walk)
            } else {
                break
            }
        }
        $Toggle.IsChecked = -not [bool]$Toggle.IsChecked
        $e.Handled = $true
    }.GetNewClosure())
}

Add-Reclaim11RowToggle (Get-Ui RowSafe) $btnSafe
Add-Reclaim11RowToggle (Get-Ui RowXbox) $btnXbox
Add-Reclaim11RowToggle (Get-Ui RowTelemetry) $btnTelemetry
Add-Reclaim11RowToggle (Get-Ui RowNic) $btnNic
Add-Reclaim11RowToggle (Get-Ui RowLatency) $btnLatency
Add-Reclaim11RowToggle (Get-Ui RowKill) $btnKill
Add-Reclaim11RowToggle (Get-Ui RowReaper) $btnReaper
Add-Reclaim11RowToggle (Get-Ui RowHideCaptures) $togHideCaptures

function Apply-Reclaim11ExpertGates {
    if ($script:UiRestore) { return }
    $pe = $false
    if ($script:LastInventory -and $script:LastInventory.gates) {
        $pe = [bool]$script:LastInventory.gates.killing_blows
    }
    $btnSafe.IsEnabled = $pe
    if (-not $pe) { $btnSafe.IsChecked = $false }
    $btnXbox.IsEnabled = $true
    $btnTelemetry.IsEnabled = $true
    $btnNic.IsEnabled = $true
    $btnLatency.IsEnabled = $true
    $btnKill.IsEnabled = $pe
    if (-not $pe) { $btnKill.IsChecked = $false }
    $btnReaper.IsEnabled = $pe
    if (-not $pe) { $btnReaper.IsChecked = $false }
    $btnNoobSafe.IsEnabled = $pe
}
$script:LastInventory = $null
$script:ProcessRunning = $false
$script:UiDoor = "door"
$script:UiRestore = $false
$script:ApplyRunLabel = [string]$btnRun.Content
$script:ApplyTestLabel = [string]$btnTest.Content
$script:ApplySubtitle = [string]$subtitle.Text
$script:ApplyFooter = [string]$footer.Text
$script:ApplyActionsHeader = [string]$actionsHeader.Text
$script:ApplyActionsHint = [string]$actionsHint.Text

function Add-Log([string]$Line) {
    $logBox.AppendText($Line + [Environment]::NewLine)
    $logBox.ScrollToEnd()
}

function Invoke-Reclaim11UiPump {
    $window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Background)
}

function Set-Reclaim11Busy {
    param([string]$Status = "")
    if (-not $panelBusy) { return }
    if ([string]::IsNullOrWhiteSpace($Status)) {
        $panelBusy.Visibility = [Windows.Visibility]::Collapsed
        $window.Title = "Reclaim11"
        return
    }
    $panelBusy.Visibility = [Windows.Visibility]::Visible
    $busyStatus.Text = $Status
    $window.Title = "Reclaim11 — $Status"
    Invoke-Reclaim11UiPump
}

function Add-NoobLog([string]$Line) {
    $noobLog.AppendText($Line + [Environment]::NewLine)
    $noobLog.ScrollToEnd()
}

function Show-Reclaim11Door {
    param(
        [string]$Name,
        [switch]$Restore
    )
    $script:UiDoor = $Name
    $script:UiRestore = [bool]$Restore
    $panelDoor.Visibility = [Windows.Visibility]::Collapsed
    $panelNoob.Visibility = [Windows.Visibility]::Collapsed
    $panelExpert.Visibility = [Windows.Visibility]::Collapsed
    switch ($Name) {
        "noob" { $panelNoob.Visibility = [Windows.Visibility]::Visible }
        "expert" { $panelExpert.Visibility = [Windows.Visibility]::Visible }
        default { $panelDoor.Visibility = [Windows.Visibility]::Visible }
    }
    if ($Name -eq "expert" -and $Restore) {
        $btnRun.Content = "RESTORE SELECTED"
        $btnTest.Content = "TEST RESTORE"
        $subtitle.Text = "Custom Restore. Select what to undo from restore.json. Newest backup first."
        $footer.Text = "Restore uses C:\reclaim11\backup\*\restore.json. Killing blows / Grim Reaper have no restore."
        $actionsHeader.Text = "RESTORE"
        $actionsHint.Text = "Select what to restore, then RESTORE SELECTED. Newest stamp first."
        $btnPrep.Visibility = [Windows.Visibility]::Collapsed
        $btnRustDesk.Visibility = [Windows.Visibility]::Collapsed
        $kinds = @{}
        foreach ($row in @(Get-Reclaim11RestoreManifests)) { $kinds[[string]$row.kind] = $true }
        $btnSafe.IsEnabled = [bool]$kinds["safe"]
        $btnXbox.IsEnabled = [bool]$kinds["xbox"]
        $btnTelemetry.IsEnabled = [bool]$kinds["telemetry"]
        $btnNic.IsEnabled = [bool]$kinds["nic"]
        $btnLatency.IsEnabled = [bool]$kinds["latency"]
        $btnKill.IsEnabled = $false
        $btnReaper.IsEnabled = $false
        if (-not $btnSafe.IsEnabled) { $btnSafe.IsChecked = $false }
        if (-not $btnXbox.IsEnabled) { $btnXbox.IsChecked = $false }
        if (-not $btnTelemetry.IsEnabled) { $btnTelemetry.IsChecked = $false }
        if (-not $btnNic.IsEnabled) { $btnNic.IsChecked = $false }
        if (-not $btnLatency.IsEnabled) { $btnLatency.IsChecked = $false }
        $btnKill.IsChecked = $false
        $btnReaper.IsChecked = $false
    } elseif ($Name -eq "expert") {
        $btnRun.Content = $script:ApplyRunLabel
        $btnTest.Content = $script:ApplyTestLabel
        $subtitle.Text = $script:ApplySubtitle
        $footer.Text = $script:ApplyFooter
        $actionsHeader.Text = $script:ApplyActionsHeader
        $actionsHint.Text = $script:ApplyActionsHint
        $btnPrep.Visibility = [Windows.Visibility]::Visible
        $btnRustDesk.Visibility = [Windows.Visibility]::Visible
        Apply-Reclaim11ExpertGates
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
    $btnPrep.IsEnabled = $true
    Apply-Reclaim11ExpertGates
    if ($script:UiRestore) {
        $pe = [bool]$inv.gates.killing_blows
        $btnNoobSafe.IsEnabled = $pe
    }
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
    Add-Log "scan is read-only. MUST boot a WinPE ISO for Defender. No receipt = bloat only. Safe / killing blows / Grim Reaper stay locked."
    if ($script:UiRestore) { Show-Reclaim11Door "expert" -Restore }
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

function Confirm-Reclaim11LatencyHighPerformance {
    $switchHp = $false
    $hpOffer = Get-Reclaim11LatencyHighPerformanceOffer
    if ($hpOffer.listed -and -not $hpOffer.already_active) {
        $hpQ = [System.Windows.MessageBox]::Show(
            "Recommended: switch the active power plan to High Performance.`n`nUSB selective suspend, USB 3 link power, and PCIe ASPM are written onto High Performance and onto the current plan either way. Switch now?",
            "Reclaim11 High Performance",
            "YesNo",
            "Question")
        $switchHp = ($hpQ -eq "Yes")
    } elseif (-not $hpOffer.listed) {
        Add-Log "High Performance plan not listed; baking the active plan only."
        Add-NoobLog "High Performance plan not listed; baking the active plan only."
    }
    $switchHp
}

function Get-Reclaim11RestoreKindsFromTicks {
    $kinds = @()
    if ([bool]$btnSafe.IsEnabled -and [bool]$btnSafe.IsChecked) { $kinds += "safe" }
    if ([bool]$btnXbox.IsEnabled -and [bool]$btnXbox.IsChecked) { $kinds += "xbox" }
    if ([bool]$btnTelemetry.IsEnabled -and [bool]$btnTelemetry.IsChecked) { $kinds += "telemetry" }
    if ([bool]$btnNic.IsEnabled -and [bool]$btnNic.IsChecked) { $kinds += "nic" }
    if ([bool]$btnLatency.IsEnabled -and [bool]$btnLatency.IsChecked) { $kinds += "latency" }
    $kinds
}

$btnRun.Add_Click({
    if ($script:ProcessRunning) { return }
    $script:ProcessRunning = $true
    $btnRun.IsEnabled = $false
    $btnTest.IsEnabled = $false
    $btnScan.IsEnabled = $false
    try {
        if ($script:UiRestore) {
            $kinds = @(Get-Reclaim11RestoreKindsFromTicks)
            if ($kinds.Count -lt 1) {
                [System.Windows.MessageBox]::Show("Select Xbox, telemetry, NIC, latency bake, and/or Safe cleanse to restore.", "Reclaim11") | Out-Null
                return
            }
            $q = [System.Windows.MessageBox]::Show(
                "Restore the ticked actions from C:\reclaim11\backup (newest stamp first). Continue?",
                "Reclaim11 RESTORE SELECTED",
                "YesNo",
                "Warning")
            if ($q -ne "Yes") { return }
            $plan = Restore-Reclaim11Selected -Kinds $kinds -Root $here
            Add-Log ("restore kinds {0} manifests {1}" -f ($kinds -join ","), @($plan.items).Count)
            foreach ($f in @($plan.failed)) { Add-Log ("RESTORE FAIL  {0}" -f $f) }
            if (@($plan.failed).Count -lt 1) { Add-Log "restore done" }
            return
        }
        $doSafe = [bool]$btnSafe.IsChecked
        $doXbox = [bool]$btnXbox.IsChecked
        $doTelemetry = [bool]$btnTelemetry.IsChecked
        $doNic = [bool]$btnNic.IsChecked
        $doLatency = [bool]$btnLatency.IsChecked
        $doKill = [bool]$btnKill.IsChecked
        $doReaper = [bool]$btnReaper.IsChecked
        if (-not ($doSafe -or $doXbox -or $doTelemetry -or $doNic -or $doLatency -or $doKill -or $doReaper)) {
            [System.Windows.MessageBox]::Show("Select Safe cleanse, Hide Xbox, telemetry, NIC, latency bake, Killing blows, and/or Send Grim Reaper.", "Reclaim11") | Out-Null
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
        $warn = "Run the ticked actions on THIS Windows. restore.json is written first where it applies. Continue?"
        if ($doReaper) {
            $warn = "Send Grim Reaper on THIS Windows. WU/Medic/USO die. Defender trees stub+DACL. After PE. Continue?"
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
        if ($doLatency) {
            try {
                $switchHp = Confirm-Reclaim11LatencyHighPerformance
                $plan = Invoke-Reclaim11LatencyBake -Root $here -SwitchHighPerformance:$switchHp
                Add-Log ("latency bake applied {0}" -f (@($plan.applied).Count))
                Add-Log ("manifest {0}" -f $plan.manifest_path)
            } catch {
                Add-Log ("LATENCY FAIL  {0}" -f $_.Exception.Message)
                [System.Windows.MessageBox]::Show($_.Exception.Message, "Reclaim11 latency bake") | Out-Null
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
        if ($script:UiRestore) {
            $kinds = @(Get-Reclaim11RestoreKindsFromTicks)
            if ($kinds.Count -lt 1) {
                [System.Windows.MessageBox]::Show("Select Xbox, telemetry, NIC, latency bake, and/or Safe cleanse to restore.", "Reclaim11") | Out-Null
                return
            }
            Add-Log "TEST RESTORE. mutate=false."
            $plan = Restore-Reclaim11Selected -Kinds $kinds -Root $here -WhatIf
            Add-Log ("would restore {0} manifest(s)" -f @($plan.items).Count)
            foreach ($it in @($plan.items)) {
                Add-Log ("  would  {0}  {1}" -f $it.kind, $it.path)
            }
            return
        }
        $doSafe = [bool]$btnSafe.IsChecked
        $doXbox = [bool]$btnXbox.IsChecked
        $doTelemetry = [bool]$btnTelemetry.IsChecked
        $doNic = [bool]$btnNic.IsChecked
        $doLatency = [bool]$btnLatency.IsChecked
        $doKill = [bool]$btnKill.IsChecked
        $doReaper = [bool]$btnReaper.IsChecked
        if (-not ($doSafe -or $doXbox -or $doTelemetry -or $doNic -or $doLatency -or $doKill -or $doReaper)) {
            [System.Windows.MessageBox]::Show("Select Safe cleanse, Hide Xbox, telemetry, NIC, latency bake, Killing blows, and/or Send Grim Reaper.", "Reclaim11") | Out-Null
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
        if ($doLatency) {
            $plan = Invoke-Reclaim11LatencyBake -Root $here -WhatIf
            Add-Log (Format-Reclaim11TestReport -Plan $plan -Title "latency_bake")
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
        Add-NoobLog "Beginner mode. TEST FIRST lists Xbox, telemetry, NIC, latency bake. RUN ALL FIXES applies those. Killing blows live on the Power User door."
    } catch {
        Add-NoobLog ("scan FAIL  {0}" -f $_.Exception.Message)
    }
})
$btnDoorExpert.Add_Click({ Show-Reclaim11Door "expert" })
$btnDoorRestoreAll.Add_Click({
    if ($script:ProcessRunning) { return }
    $rows = @(Get-Reclaim11RestoreManifests | Where-Object { @("xbox", "telemetry", "nic", "latency", "safe") -contains $_.kind })
    if ($rows.Count -lt 1) {
        [System.Windows.MessageBox]::Show("Nothing to restore. No restore.json under C:\reclaim11\backup.", "Reclaim11 Restore Everything") | Out-Null
        return
    }
    $q = [System.Windows.MessageBox]::Show(
        ("Restore Xbox, telemetry, NIC, latency bake, and Safe cleanse from {0} backup(s). Newest first. Not Grim Reaper. Continue?" -f $rows.Count),
        "Reclaim11 Restore Everything",
        "YesNo",
        "Warning")
    if ($q -ne "Yes") { return }
    $script:ProcessRunning = $true
    try {
        $plan = Restore-Reclaim11Selected -Kinds @("xbox", "telemetry", "nic", "latency", "safe") -Root $here
        $msg = ("Restored {0} manifest(s). Failed {1}." -f @($plan.items).Count, @($plan.failed).Count)
        if (@($plan.failed).Count -gt 0) { $msg = $msg + "`n`n" + (@($plan.failed) -join "`n") }
        [System.Windows.MessageBox]::Show($msg, "Reclaim11 Restore Everything") | Out-Null
    } catch {
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Reclaim11 Restore Everything") | Out-Null
    } finally { $script:ProcessRunning = $false }
})
$btnDoorRestoreCustom.Add_Click({
    Show-Reclaim11Door "expert" -Restore
    try {
        Show-Inventory (Get-Reclaim11Inventory -Root $here -WinPeLog $WinPeLog)
        Add-Log "Custom Restore. Select what to undo. TEST RESTORE lists restore.json. Killing blows / Grim Reaper have no restore."
    } catch {
        Add-Log ("scan FAIL  {0}" -f $_.Exception.Message)
    }
})
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
        $nic = Invoke-Reclaim11NicTune -Root $here -WhatIf
        Add-NoobLog (Format-Reclaim11TestReport -Plan $nic -Title "nic")
        $lat = Invoke-Reclaim11LatencyBake -Root $here -WhatIf
        Add-NoobLog (Format-Reclaim11TestReport -Plan $lat -Title "latency")
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
        "RUN ALL FIXES on THIS Windows: Hide Xbox, telemetry, NIC tune, latency bake (BCD + registry + power). restore.json first. Not Defender. Not Grim Reaper. Continue?",
        "Reclaim11 RUN ALL FIXES",
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
        try {
            $plan = Invoke-Reclaim11NicTune -Root $here
            Add-NoobLog ("nic  {0}" -f $plan.manifest_path)
        } catch { Add-NoobLog ("NIC FAIL  {0}" -f $_.Exception.Message) }
        try {
            $switchHp = Confirm-Reclaim11LatencyHighPerformance
            $plan = Invoke-Reclaim11LatencyBake -Root $here -SwitchHighPerformance:$switchHp
            Add-NoobLog ("latency  {0}" -f $plan.manifest_path)
        } catch { Add-NoobLog ("LATENCY FAIL  {0}" -f $_.Exception.Message) }
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

$btnNoobNic.Add_Click({
    if ($script:ProcessRunning) { return }
    $q = [System.Windows.MessageBox]::Show(
        "Tune Ethernet NIC (offloads off, RSS on, Rx/Tx 256-512). restore.json first. Continue?",
        "Reclaim11 TUNE NIC",
        "YesNo",
        "Warning")
    if ($q -ne "Yes") { return }
    $script:ProcessRunning = $true
    try {
        $plan = Invoke-Reclaim11NicTune -Root $here
        Add-NoobLog ("nic  {0}" -f $plan.manifest_path)
    } catch {
        Add-NoobLog ("NIC FAIL  {0}" -f $_.Exception.Message)
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Reclaim11 NIC tune") | Out-Null
    } finally { $script:ProcessRunning = $false }
})

$btnNoobLatency.Add_Click({
    if ($script:ProcessRunning) { return }
    $q = [System.Windows.MessageBox]::Show(
        "Latency bake: BCD, timer/MMCSS, USB/ASPM power. restore.json first. Continue?",
        "Reclaim11 LATENCY BAKE",
        "YesNo",
        "Warning")
    if ($q -ne "Yes") { return }
    $script:ProcessRunning = $true
    try {
        $switchHp = Confirm-Reclaim11LatencyHighPerformance
        $plan = Invoke-Reclaim11LatencyBake -Root $here -SwitchHighPerformance:$switchHp
        Add-NoobLog ("latency  {0}" -f $plan.manifest_path)
    } catch {
        Add-NoobLog ("LATENCY FAIL  {0}" -f $_.Exception.Message)
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Reclaim11 latency bake") | Out-Null
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

function Write-Reclaim11RustDeskUiLog {
    param($Result, [switch]$Noob)
    $line1 = ("rustdesk id {0}" -f $Result.id)
    $line2 = ("rustdesk mode={0} service={1} servers={2} tag={3}" -f `
            $Result.password_mode, $Result.install_service, $Result.servers, $Result.tag)
    if ($Noob) {
        Add-NoobLog $line1
        Add-NoobLog $line2
    } else {
        Add-Log $line1
        Add-Log $line2
    }
}

$btnRustDesk.Add_Click({
    if ($script:ProcessRunning) { return }
    $choice = Show-Reclaim11RustDeskChooser -Owner $window
    if (-not $choice) { return }
    try {
        $pin = Get-Reclaim11RustDeskPlan -Root $here
        $msg = @(
            ("Install official RustDesk {0} on THIS Windows?" -f $pin.tag),
            "",
            $pin.asset,
            ("sha256 {0}" -f $pin.sha256),
            ("servers {0}" -f $pin.servers),
            ("mode {0}" -f $choice.password_mode),
            ("service {0}" -f $choice.install_service),
            "",
            "Password is never logged. Continue?"
        ) -join "`n"
        $q = [System.Windows.MessageBox]::Show($msg, "Reclaim11 RustDesk", "YesNo", "Warning")
        if ($q -ne "Yes") { return }
        $script:ProcessRunning = $true
        $btnRustDesk.IsEnabled = $false
        $btnNoobRustDesk.IsEnabled = $false
        $btnScan.IsEnabled = $false
        $btnPrep.IsEnabled = $false
        $btnRun.IsEnabled = $false
        $btnTest.IsEnabled = $false
        try {
            Set-Reclaim11Busy "Installing official RustDesk"
            $plan = Install-Reclaim11RustDesk -Root $here -PasswordMode $choice.password_mode `
                -Password $choice.password -InstallService:([bool]$choice.install_service)
            Write-Reclaim11RustDeskUiLog $plan
            $done = if ($plan.password_mode -eq "one-time") {
                "RustDesk ID: {0}`n`nOne-time password is in the RustDesk window. It is not stored here." -f $plan.id
            } else {
                "RustDesk ID: {0}`n`nPermanent password is what you set. It was not logged." -f $plan.id
            }
            [System.Windows.MessageBox]::Show($done, "Reclaim11 RustDesk") | Out-Null
        } catch {
            Add-Log ("RUSTDESK FAIL  {0}" -f $_.Exception.Message)
            [System.Windows.MessageBox]::Show($_.Exception.Message, "Reclaim11 RustDesk") | Out-Null
        } finally {
            Set-Reclaim11Busy ""
        }
    } finally {
        if ($choice.password) {
            try { $choice.password.Dispose() } catch { }
        }
        $script:ProcessRunning = $false
        $btnRustDesk.IsEnabled = $true
        $btnNoobRustDesk.IsEnabled = $true
        $btnScan.IsEnabled = $true
        $btnPrep.IsEnabled = $true
        $btnRun.IsEnabled = $true
        $btnTest.IsEnabled = $true
    }
})

$btnNoobRustDesk.Add_Click({
    if ($script:ProcessRunning) { return }
    $pin = Get-Reclaim11RustDeskPlan -Root $here
    $msg = @(
        "Install RustDesk to get remote support?",
        "",
        "Official public servers. One-time codes only (no permanent password).",
        "",
        ("{0} {1}" -f $pin.tag, $pin.asset),
        ("sha256 {0}" -f $pin.sha256),
        "",
        "Continue?"
    ) -join "`n"
    $q = [System.Windows.MessageBox]::Show($msg, "Reclaim11 RustDesk", "YesNo", "Warning")
    if ($q -ne "Yes") { return }
    $script:ProcessRunning = $true
    try {
        Set-Reclaim11Busy "Installing official RustDesk"
        $plan = Install-Reclaim11RustDesk -Root $here -PasswordMode one-time -InstallService
        Write-Reclaim11RustDeskUiLog $plan -Noob
        $done = "RustDesk ID: {0}`n`nThe one-time password is in the RustDesk window. It is not stored here." -f $plan.id
        [System.Windows.MessageBox]::Show($done, "Reclaim11 RustDesk") | Out-Null
    } catch {
        Add-NoobLog ("RUSTDESK FAIL  {0}" -f $_.Exception.Message)
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Reclaim11 RustDesk") | Out-Null
    } finally {
        Set-Reclaim11Busy ""
        $script:ProcessRunning = $false
    }
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

function Get-Reclaim11PrepScript([string]$Name) {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $here)
    foreach ($c in @(
            (Join-Path $here "scripts\$Name"),
            (Join-Path $repoRoot "scripts\$Name")
        )) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    $null
}

function Get-Reclaim11PrepIsoPath {
    $isoDir = "C:\Reclaim11"
    $want = Join-Path $isoDir "Reclaim11-WinPE-v11.iso"
    foreach ($n in @("Reclaim11-WinPE-v11.iso", "Reclaim11-WinPE-v10.iso", "Reclaim11-WinPE-v9.iso", "Reclaim11-WinPE.iso", "Reclaim11-WinPE-v8.iso", "Reclaim11-WinPE-v7.iso")) {
        $p = Join-Path $isoDir $n
        if (Test-Path -LiteralPath $p) {
            return [pscustomobject]@{ want = $want; iso = $p; have = $true }
        }
    }
    [pscustomobject]@{ want = $want; iso = $want; have = $false }
}

function Get-Reclaim11PlainText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return "" }
    $t = [regex]::Replace($Text, '\x1B\[[0-9;?]*[ -/]*[@-~]', "")
    $t = [regex]::Replace($t, '\x1B\][^\x07\x1B]*(\x07|\x1B\\)', "")
    $t = [regex]::Replace($t, '\[[0-9;]{1,12}m', "")
    $t.Trim()
}

function Get-Reclaim11PrepFailText {
    param([string]$Raw)
    $t = Get-Reclaim11PlainText $Raw
    if ($t -match "still missing after install" -or $t -match "adk-.+\.log") {
        return "ADK install did not finish. Check C:\Reclaim11\adk-*.log, then click PREP MEDIA again."
    }
    if ($t -match "Windows ADK WinPE is missing") {
        return "Windows ADK + WinPE addon 10.1.26100.2454 is missing (not 28000)."
    }
    $lines = @(
        $t -split "`r?`n" |
            Where-Object { $_ -notmatch '[█░]|^\s*\d+%\s*$|MB /' -and $_.Length -lt 220 }
    )
    if ($lines.Count -gt 12) {
        $lines = @($lines | Select-Object -First 12) + "..."
    }
    ($lines -join "`n").Trim()
}

function Confirm-Reclaim11PrepAdkInstall {
    $q = [System.Windows.MessageBox]::Show(
        @(
            "Windows ADK + WinPE addon 10.1.26100.2454 is missing (not 28000).",
            "",
            "PREP can install the matching pair now (internet, several minutes).",
            "",
            "No = stop. Yes = install the addons and continue."
        ) -join "`n",
        "Reclaim11 PREP MEDIA",
        "YesNo",
        "Warning")
    $q -eq "Yes"
}

function Invoke-Reclaim11PrepProcess {
    param(
        [Parameter(Mandatory)][string]$Arg,
        [Parameter(Mandatory)][string]$FailName,
        [string]$Status = ""
    )
    $pwsh = Get-Reclaim11Pwsh
    $stamp = [guid]::NewGuid().ToString("N").Substring(0, 8)
    $outFile = Join-Path $env:TEMP ("reclaim11-prep-" + $stamp + ".out")
    $errFile = Join-Path $env:TEMP ("reclaim11-prep-" + $stamp + ".err")
    $baseStatus = $Status
    if ($baseStatus) { Set-Reclaim11Busy $baseStatus }
    try {
        $p = Start-Process -FilePath $pwsh -ArgumentList $Arg -PassThru -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while (-not $p.HasExited) {
            if ($baseStatus) {
                Set-Reclaim11Busy ("{0}  {1:mm\:ss}" -f $baseStatus, $sw.Elapsed)
            } else {
                Invoke-Reclaim11UiPump
            }
            Start-Sleep -Milliseconds 250
        }
        $chunks = @()
        if (Test-Path -LiteralPath $outFile) {
            $chunks += Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $errFile) {
            $chunks += Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue
        }
        $out = Get-Reclaim11PlainText (($chunks -join "`n"))
        if ($out) { Add-Log $out }
        if ([int]$p.ExitCode -ne 0) {
            throw ("{0} exit {1}`n{2}" -f $FailName, $p.ExitCode, $out)
        }
        $out
    } finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-Reclaim11PrepUsbCandidates {
    param([Parameter(Mandatory)][string]$UsbScript)
    $raw = Invoke-Reclaim11PrepProcess -Arg ("-NoProfile -ExecutionPolicy Bypass -File `"{0}`" -ListJson" -f $UsbScript) -FailName "USB list"
    $text = [string]$raw
    $cut = $text.IndexOf("[")
    if ($cut -lt 0) { $cut = $text.IndexOf("{") }
    if ($cut -gt 0) { $text = $text.Substring($cut) }
    $parsed = $text | ConvertFrom-Json
    @($parsed)
}

function Select-Reclaim11PrepUsbDisk {
    param($Candidates)
    $ok = @($Candidates | Where-Object { $_.ok })
    if ($ok.Count -lt 1) {
        $ref = @($Candidates | ForEach-Object { "disk {0} {1} ({2})" -f $_.number, $_.name, $_.refuse })
        [System.Windows.MessageBox]::Show(
            ("No USB stick ready (need 1 GB+, under 32 GB, not this PC's boot disk). Plug one in and click PREP MEDIA again.`n`n{0}" -f ($ref -join "`n")),
            "Reclaim11 PREP MEDIA") | Out-Null
        return $null
    }
    $pick = $null
    if ($ok.Count -eq 1) {
        $pick = $ok[0]
    } else {
        $lines = @($ok | ForEach-Object {
                $lett = if (@($_.letters).Count -gt 0) { ($_.letters -join ",") } else { "-" }
                "disk {0}  {1}  {2:N1} GB  letter={3}" -f $_.number, $_.name, ($_.size / 1GB), $lett
            })
        Add-Type -AssemblyName Microsoft.VisualBasic
        $typed = [Microsoft.VisualBasic.Interaction]::InputBox(
            ("Several USB sticks.`n`n{0}`n`nDisk number to FORMAT:" -f ($lines -join "`n")),
            "Reclaim11 USB",
            "")
        if ([string]::IsNullOrWhiteSpace($typed)) { return $null }
        $n = 0
        if (-not [int]::TryParse($typed.Trim(), [ref]$n)) {
            [System.Windows.MessageBox]::Show("Not a disk number.", "Reclaim11 PREP MEDIA") | Out-Null
            return $null
        }
        $pick = @($ok | Where-Object { $_.number -eq $n }) | Select-Object -First 1
        if (-not $pick) {
            [System.Windows.MessageBox]::Show("Disk $n is not a USB stick we can use (1 GB+, under 32 GB, not the boot disk).", "Reclaim11 PREP MEDIA") | Out-Null
            return $null
        }
    }
    $lett = if (@($pick.letters).Count -gt 0) { ($pick.letters -join ",") } else { "-" }
    $q = [System.Windows.MessageBox]::Show(
        ("FORMAT USB disk {0} ({1}, {2:N1} GB, letter {3})? This ERASES the stick. Not this PC's boot disk.`n`nBoot the stick on the target (VM recommended, not required)." -f $pick.number, $pick.name, ($pick.size / 1GB), $lett),
        "Reclaim11 PREP MEDIA",
        "YesNo",
        "Warning")
    if ($q -ne "Yes") { return $null }
    [int]$pick.number
}

$btnPrep.Add_Click({
    if ($script:ProcessRunning) { return }
    $build = Get-Reclaim11PrepScript "New-Reclaim11WinPeIso.ps1"
    $usbBuild = Get-Reclaim11PrepScript "New-Reclaim11WinPeUsb.ps1"
    if (-not $build) {
        [System.Windows.MessageBox]::Show(
            "MUST: WinPE ISO builder missing. Use a Reclaim11 kit zip (scripts\New-Reclaim11WinPeIso.ps1) or the GodBrain repo.",
            "Reclaim11 prep media") | Out-Null
        return
    }
    $isoInfo = Get-Reclaim11PrepIsoPath
    $want = [string]$isoInfo.want
    if (-not [bool]$isoInfo.have) {
        $q = [System.Windows.MessageBox]::Show(
            ("Build WinPE ISO to:`n{0}`n`nNeeds ADK + WinPE addon 10.1.26100.2454 (not 28000). Several minutes. DISM only against the WinPE image, not this Windows.`n`nThen PREP MEDIA writes a USB. VM recommended, not required." -f $want),
            "Reclaim11 PREP MEDIA",
            "YesNo",
            "Warning")
        if ($q -ne "Yes") { return }
    }
    $script:ProcessRunning = $true
    $btnPrep.IsEnabled = $false
    $btnScan.IsEnabled = $false
    $btnRun.IsEnabled = $false
    $btnTest.IsEnabled = $false
    try {
        if (-not [bool]$isoInfo.have) {
            Add-Log ("PREP MEDIA building {0}" -f $want)
            $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$build`" -OutIso `"$want`""
            try {
                $null = Invoke-Reclaim11PrepProcess -Arg $arg -FailName "ISO builder" -Status "Building WinPE ISO"
            } catch {
                $adkMiss = (Get-Reclaim11PlainText $_.Exception.Message) -match "Windows ADK WinPE is missing"
                if (-not $adkMiss) { throw }
                Set-Reclaim11Busy ""
                if (-not (Confirm-Reclaim11PrepAdkInstall)) {
                    Add-Log "PREP MEDIA aborted (ADK install)"
                    return
                }
                Add-Log "PREP MEDIA installing ADK + WinPE addon 10.1.26100.2454"
                $argInstall = "-NoProfile -ExecutionPolicy Bypass -File `"$build`" -OutIso `"$want`" -InstallAdk"
                $null = Invoke-Reclaim11PrepProcess -Arg $argInstall -FailName "ISO builder" -Status "Installing ADK + WinPE addon"
            }
            if (-not (Test-Path -LiteralPath $want)) {
                throw "ISO missing after build: $want"
            }
            Add-Log ("PREP MEDIA iso {0}" -f $want)
        } else {
            Add-Log ("PREP MEDIA iso exists {0}" -f $isoInfo.iso)
        }
        if (-not $usbBuild) {
            [System.Windows.MessageBox]::Show(
                ("ISO ready:`n{0}`n`nUSB writer missing (scripts\New-Reclaim11WinPeUsb.ps1). Boot the ISO on the target (VM recommended). Without that boot this GUI is bloat only." -f $(if ([bool]$isoInfo.have) { $isoInfo.iso } else { $want })),
                "Reclaim11 PREP MEDIA") | Out-Null
            return
        }
        $cands = @(Get-Reclaim11PrepUsbCandidates -UsbScript $usbBuild)
        Set-Reclaim11Busy ""
        $disk = Select-Reclaim11PrepUsbDisk -Candidates $cands
        if ($null -eq $disk) { return }
        Add-Log ("PREP MEDIA USB disk {0}" -f $disk)
        $usbArg = "-NoProfile -ExecutionPolicy Bypass -File `"$usbBuild`" -DiskNumber $disk -Go"
        try {
            $null = Invoke-Reclaim11PrepProcess -Arg $usbArg -FailName "USB writer" -Status "Writing USB"
        } catch {
            if ($_.Exception.Message -match "boot\.wim") {
                Add-Log "PREP MEDIA workdir missing; rebuilding ISO payload"
                $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$build`" -OutIso `"$want`""
                $null = Invoke-Reclaim11PrepProcess -Arg $arg -FailName "ISO builder" -Status "Building WinPE ISO"
                $null = Invoke-Reclaim11PrepProcess -Arg $usbArg -FailName "USB writer" -Status "Writing USB"
            } else {
                throw
            }
        }
        Add-Log ("PREP MEDIA USB ok disk {0}" -f $disk)
        Set-Reclaim11Busy ""
        [System.Windows.MessageBox]::Show(
            "USB ready. Boot the stick on the target to remove Defender. VM recommended first, not required. Without that boot this GUI is bloat only.",
            "Reclaim11 PREP MEDIA") | Out-Null
    } catch {
        $prepFail = Get-Reclaim11PrepFailText $_.Exception.Message
        Add-Log ("PREP FAIL  {0}" -f $prepFail)
        Set-Reclaim11Busy ""
        [System.Windows.MessageBox]::Show($prepFail, "Reclaim11 PREP MEDIA") | Out-Null
    } finally {
        Set-Reclaim11Busy ""
        $script:ProcessRunning = $false
        $btnPrep.IsEnabled = $true
        $btnScan.IsEnabled = $true
        $btnRun.IsEnabled = $true
        $btnTest.IsEnabled = $true
    }
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
