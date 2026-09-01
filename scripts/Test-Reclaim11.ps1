# Offline + live-read inventory check for Reclaim11. No wipe. Not Heal.
[CmdletBinding()]
param(
    [string]$RepoRoot = $PSScriptRoot
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Resolve-GodBrainRoot.ps1")

$root = Join-Path $RepoRoot "godbrain_core\reclaim11"
$catPath = Join-Path $root "catalog.json"
$xamlPath = Join-Path $root "ui\MainWindow.xaml"
$invPath = Join-Path $root "inventory.ps1"
$launch = Join-Path $root "Reclaim11.ps1"

foreach ($p in @($catPath, $xamlPath, $invPath, $launch)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "Test-Reclaim11: missing $p" }
}

$cat = Get-Content -LiteralPath $catPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($cat.id -ne "reclaim11-pack-a-v1") { throw "Test-Reclaim11: catalog id" }
if ($cat.pack -ne "A") { throw "Test-Reclaim11: pack A" }
if ($cat.trust -ne "candidate" -or $cat.auto_verify -ne "never") {
    throw "Test-Reclaim11: catalog must stay candidate"
}
if (-not $cat.not_heal -or -not $cat.not_galaxy) { throw "Test-Reclaim11: not_heal / not_galaxy" }
if ($cat.never_touch_services -notcontains "BFE") { throw "Test-Reclaim11: BFE must be never-touch" }
if ($cat.never_touch_services -notcontains "mpssvc") { throw "Test-Reclaim11: mpssvc must be never-touch" }
if ($cat.never_touch_services -notcontains "FltMgr") { throw "Test-Reclaim11: FltMgr must be never-touch" }
if ($cat.ppl_offline -notcontains "WdBoot.sys") { throw "Test-Reclaim11: WdBoot is PPL/ELAM" }
if ($cat.elam -notcontains "WdBoot.sys") { throw "Test-Reclaim11: elam list" }
if ($cat.gates.stub_wdboot_if_secure_boot -ne "refuse") {
    throw "Test-Reclaim11: SB gate must refuse WdBoot"
}

. $invPath

$sbOn = [pscustomobject]@{
    secure_boot    = [pscustomobject]@{ enabled = $true; available = $true }
    never_touch_ok = $true
}
$gOn = Get-Reclaim11Gates -Inventory $sbOn
if ($gOn.stub_wdboot) { throw "Test-Reclaim11: SB on must refuse WdBoot stub" }
if (-not $gOn.prep_media) { throw "Test-Reclaim11: prep media still allowed when SB on" }
if ($gOn.killing_blows) { throw "Test-Reclaim11: killing blows locked without log" }

$sbOff = [pscustomobject]@{
    secure_boot    = [pscustomobject]@{ enabled = $false; available = $true }
    never_touch_ok = $true
}
$gOff = Get-Reclaim11Gates -Inventory $sbOff
if (-not $gOff.stub_wdboot) { throw "Test-Reclaim11: SB off must allow WdBoot stub" }

$tmpLog = Join-Path $env:TEMP "reclaim11-winpe-test.log"
Set-Content -LiteralPath $tmpLog -Value "winpe ok" -Encoding ASCII
$gLog = Get-Reclaim11Gates -Inventory $sbOff -WinPeLog $tmpLog
if (-not $gLog.killing_blows) { throw "Test-Reclaim11: WinPE log must unlock killing blows" }
Remove-Item -LiteralPath $tmpLog -Force

# XAML load in STA (no ShowDialog).
$xamlTest = @"
Add-Type -AssemblyName PresentationFramework
[xml]`$x = Get-Content -LiteralPath '$($xamlPath.Replace("'", "''"))' -Raw -Encoding UTF8
`$r = New-Object System.Xml.XmlNodeReader `$x
`$w = [Windows.Markup.XamlReader]::Load(`$r)
if (-not `$w.FindName('BtnScan')) { throw 'no BtnScan' }
if (-not `$w.FindName('BtnPrep')) { throw 'no BtnPrep' }
if (-not `$w.FindName('BtnKill')) { throw 'no BtnKill' }
`$w.Close()
'xaml-ok'
"@
$p = Start-Process -FilePath (Join-Path $PSHOME "pwsh.exe") -ArgumentList @(
    "-STA", "-NoProfile", "-Command", $xamlTest
) -Wait -PassThru -NoNewWindow
if ($p.ExitCode -ne 0) { throw "Test-Reclaim11: XAML load failed (exit $($p.ExitCode))" }

$inv = Get-Reclaim11Inventory -Root $root
if ($inv.mutate) { throw "Test-Reclaim11: inventory must not mutate" }
if (-not $inv.os.os_pin) { throw "Test-Reclaim11: missing os_pin" }
if ($inv.os.os_pin -notmatch "26100") { throw "Test-Reclaim11: unexpected os_pin $($inv.os.os_pin)" }
if (-not $inv.never_touch_ok) { throw "Test-Reclaim11: BFE/mpssvc must be RUNNING on this host" }
if ($inv.gates.killing_blows) { throw "Test-Reclaim11: live host has no WinPE log; blows must stay locked" }

$braveDir = Join-Path $root "brave-policy"
$lock = Get-Content -LiteralPath (Join-Path $braveDir "lockdown.reg") -Raw -Encoding UTF8
$dang = Get-Content -LiteralPath (Join-Path $braveDir "allow-dangerous-downloads.reg") -Raw -Encoding UTF8
if ($lock -notmatch 'BraveRewardsDisabled') { throw "Test-Reclaim11: lockdown missing Rewards" }
if ($lock -notmatch 'BraveWebDiscoveryEnabled') { throw "Test-Reclaim11: lockdown missing WebDiscovery" }
if ($lock -notmatch 'ShowHomeButton') { throw "Test-Reclaim11: lockdown missing ShowHomeButton" }
if (-not (Test-Path -LiteralPath (Join-Path $braveDir "SOURCE.txt"))) { throw "Test-Reclaim11: missing SOURCE.txt" }
if ($lock -notmatch 'DefaultBraveAdblockSetting') { throw "Test-Reclaim11: lockdown missing Shields adblock" }
if ($lock -notmatch 'DefaultJavaScriptSetting') { throw "Test-Reclaim11: lockdown missing JS allow" }
if ($lock -notmatch 'HKEY_CURRENT_USER\\SOFTWARE\\Policies\\BraveSoftware\\Brave') {
    throw "Test-Reclaim11: lockdown missing HKCU for Home"
}
if ($lock -match 'DownloadRestrictions') { throw "Test-Reclaim11: lockdown must not touch downloads" }
if ($lock -match 'override-download-danger') { throw "Test-Reclaim11: lockdown must not set labs flags" }
if ($dang -notmatch 'WARNING DO NOT DISABLE') { throw "Test-Reclaim11: danger reg missing warning" }
if ($dang -notmatch 'DownloadRestrictions') { throw "Test-Reclaim11: danger reg missing DownloadRestrictions" }
if (-not (Test-Path -LiteralPath (Join-Path $braveDir "Apply-BravePolicy.ps1"))) {
    throw "Test-Reclaim11: missing Apply-BravePolicy.ps1"
}

Write-Output ("Test-Reclaim11: ok catalog pack-A gates xaml brave-policy os_pin={0} sb={1} stub_wdboot={2}" -f `
    $inv.os.os_pin, $inv.secure_boot.enabled, $inv.gates.stub_wdboot)
exit 0
