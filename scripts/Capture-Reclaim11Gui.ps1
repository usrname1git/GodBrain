# One-shot STA capture of the Reclaim11 WPF window. Not Heal.
[CmdletBinding()]
param(
    [string]$OutPng = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$sta = [Threading.Thread]::CurrentThread.GetApartmentState()
if ($sta -ne "STA") {
    $pwsh = Join-Path $PSHOME "pwsh.exe"
    $arg = @("-STA", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $MyInvocation.MyCommand.Path)
    if ($OutPng) { $arg += @("-OutPng", $OutPng) }
    $p = Start-Process -FilePath $pwsh -ArgumentList $arg -Wait -PassThru -NoNewWindow
    exit $p.ExitCode
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$repo = Split-Path -Parent $PSScriptRoot
$here = Join-Path $repo "godbrain_core\reclaim11"
if (-not $OutPng) {
    $OutPng = Join-Path $here "ui\MainWindow.png"
}
. (Join-Path $here "inventory.ps1")

[xml]$xaml = Get-Content -LiteralPath (Join-Path $here "ui\MainWindow.xaml") -Raw -Encoding UTF8
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

function Get-Ui([string]$Name) { $window.FindName($Name) }

$inv = Get-Reclaim11Inventory -Root $here
(Get-Ui OsPin).Text = $inv.os.os_pin
$sb = $inv.secure_boot
(Get-Ui SecureBoot).Text = if ($sb.available) {
    if ($sb.enabled) { "ON  (WdBoot stub refused)" } else { "off  (WdBoot stub allowed offline)" }
} else { "n/a  $($sb.error)" }
$bl = $inv.bitlocker_c
(Get-Ui BitLocker).Text = if ($bl.present) { "$($bl.protection) / $($bl.volume_status)" } else { "not present / $($bl.error)" }
(Get-Ui NeverTouch).Text = if ($inv.never_touch_ok) { "BFE + mpssvc RUNNING" } else { "FAIL  do not continue" }
(Get-Ui WdBootGate).Text = $inv.gates.reason_wdboot
(Get-Ui BtnPrep).IsEnabled = [bool]$inv.gates.prep_media
(Get-Ui BtnSafe).IsEnabled = [bool]$inv.gates.killing_blows
if (Get-Ui BtnXbox) { (Get-Ui BtnXbox).IsEnabled = $true }
(Get-Ui BtnKill).IsEnabled = [bool]$inv.gates.killing_blows
$log = Get-Ui LogBox
$lines = @(
    ("at        {0}" -f $inv.at),
    ("catalog   {0}" -f $inv.catalog),
    ("os_pin    {0}" -f $inv.os.os_pin),
    ("sku       {0}" -f $inv.os.edition_id),
    ("firmware  {0}" -f $inv.os.firmware),
    ("secure_boot enabled={0} available={1}" -f $inv.secure_boot.enabled, $inv.secure_boot.available),
    ("never_touch_ok {0}" -f $inv.never_touch_ok),
    ("prep_media={0} stub_wdboot={1} killing_blows={2}" -f $inv.gates.prep_media, $inv.gates.stub_wdboot, $inv.gates.killing_blows),
    $inv.gates.reason_wdboot,
    $inv.gates.reason_killing_blows,
    "--- services (pack A + never-touch) ---"
)
foreach ($s in $inv.services) {
    $lines += ("  {0,-24} present={1,-5} {2}" -f $s.name, $s.present, $s.status)
}
$lines += "scan is read-only. Safe cleanse / killing blows locked until WinPE receipt"
$log.Text = $lines -join [Environment]::NewLine

$window.Add_ContentRendered({
    $dpi = 96.0
    $w = [Math]::Max(1, [int]$window.ActualWidth)
    $h = [Math]::Max(1, [int]$window.ActualHeight)
    $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap $w, $h, $dpi, $dpi, ([Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($window)
    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $dir = Split-Path -Parent $OutPng
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir | Out-Null
    }
    $fs = [IO.File]::Create($OutPng)
    try { $enc.Save($fs) } finally { $fs.Close() }
    Write-Output $OutPng
    $window.Close()
})

[void]$window.ShowDialog()
exit 0
