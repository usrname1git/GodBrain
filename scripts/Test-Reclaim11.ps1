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
$xamlSrc = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
if ($xamlSrc -match 'Chris-style|christitus') {
    throw "Test-Reclaim11: door copy must not mention CTT"
}
if ($xamlSrc -notmatch "Grim Reaper") {
    throw "Test-Reclaim11: door must say Grim Reaper"
}
if ($xamlSrc -notmatch "YOU BETTER KNOW WTF") {
    throw "Test-Reclaim11: expert door must warn WTF"
}

$launchSrc = Get-Content -LiteralPath $launch -Raw -Encoding UTF8
if ($launchSrc -notmatch 'LanguageMode -ne "FullLanguage"') {
    throw "Test-Reclaim11: Reclaim11.ps1 must refuse ConstrainedLanguage"
}
if ($launchSrc -notmatch '-Verb RunAs') {
    throw "Test-Reclaim11: GUI path must UAC-relaunch"
}
$testAt = $launchSrc.IndexOf('if ($Test)')
$runAsAt2 = $launchSrc.IndexOf('-Verb RunAs')
if ($testAt -lt 0 -or $testAt -gt $runAsAt2) {
    throw "Test-Reclaim11: -T must skip UAC"
}
if ($launchSrc -notmatch 'Start-Transcript') {
    throw "Test-Reclaim11: GUI path must transcript"
}
if ($launchSrc -notmatch '(?s)killing blows applied.*manifest') {
    throw "Test-Reclaim11: GUI must log killing-blows restore.json path"
}
if ($launchSrc -notmatch 'ProcessRunning') {
    throw "Test-Reclaim11: GUI path must lock RUN SELECTED"
}
if ($launchSrc -match 'irm https|Invoke-RestMethod|Invoke-Expression|\bwt\.exe\b|\bwinget\b|\bchoco\b') {
    throw "Test-Reclaim11: Reclaim11.ps1 must not irm/iex/wt/winget/choco"
}
$invOnlyAt = $launchSrc.IndexOf('if ($InventoryOnly)')
$runAsAt = $launchSrc.IndexOf('-Verb RunAs')
if ($invOnlyAt -lt 0 -or $runAsAt -lt 0 -or $invOnlyAt -gt $runAsAt) {
    throw "Test-Reclaim11: -InventoryOnly must skip UAC"
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
if ($cat.gates.prep_media -ne "winpe-iso") { throw "Test-Reclaim11: prep_media is winpe-iso" }
if ($cat.winpe_receipt -ne "Windows\reclaim11-winpe.log") { throw "Test-Reclaim11: winpe receipt path" }

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

$sbNa = [pscustomobject]@{
    secure_boot    = [pscustomobject]@{ enabled = $false; available = $false; error = "probe failed" }
    never_touch_ok = $true
}
$gNa = Get-Reclaim11Gates -Inventory $sbNa
if ($gNa.stub_wdboot) { throw "Test-Reclaim11: SB n/a must refuse WdBoot stub" }
if ($gNa.reason_wdboot -notmatch 'n/a') { throw "Test-Reclaim11: SB n/a reason" }

$tmpLog = Join-Path $env:TEMP "reclaim11-winpe-test.log"
Set-Content -LiteralPath $tmpLog -Value '{"id":"reclaim11-winpe-v1","catalog":"reclaim11-pack-a-v1"}' -Encoding UTF8
$gLog = Get-Reclaim11Gates -Inventory $sbOff -WinPeLog $tmpLog
if (-not $gLog.killing_blows) { throw "Test-Reclaim11: WinPE log must unlock killing blows" }
$junkLog = Join-Path $env:TEMP "reclaim11-winpe-junk.log"
Set-Content -LiteralPath $junkLog -Value "winpe ok" -Encoding ASCII
$gJunk = Get-Reclaim11Gates -Inventory $sbOff -WinPeLog $junkLog
if ($gJunk.killing_blows) { throw "Test-Reclaim11: non-JSON log must not unlock killing blows" }
Remove-Item -LiteralPath $tmpLog, $junkLog -Force

# XAML load in STA (no ShowDialog).
$xamlTest = @"
Add-Type -AssemblyName PresentationFramework
[xml]`$x = Get-Content -LiteralPath '$($xamlPath.Replace("'", "''"))' -Raw -Encoding UTF8
`$r = New-Object System.Xml.XmlNodeReader `$x
`$w = [Windows.Markup.XamlReader]::Load(`$r)
if (-not `$w.FindName('BtnScan')) { throw 'no BtnScan' }
if (-not `$w.FindName('BtnPrep')) { throw 'no BtnPrep' }
if (-not `$w.FindName('BtnKill')) { throw 'no BtnKill' }
if (-not `$w.FindName('BtnSafe')) { throw 'no BtnSafe' }
if (-not `$w.FindName('BtnXbox')) { throw 'no BtnXbox' }
if (-not `$w.FindName('BtnRun')) { throw 'no BtnRun' }
if (-not `$w.FindName('BtnTest')) { throw 'no BtnTest' }
if (-not `$w.FindName('TogHideCaptures')) { throw 'no TogHideCaptures' }
if (-not `$w.FindName('BtnTelemetry')) { throw 'no BtnTelemetry' }
if (-not `$w.FindName('BtnNic')) { throw 'no BtnNic' }
if (-not `$w.FindName('BtnDoorNoob')) { throw 'no BtnDoorNoob' }
if (-not `$w.FindName('BtnDoorExpert')) { throw 'no BtnDoorExpert' }
if (-not `$w.FindName('PanelDoor')) { throw 'no PanelDoor' }
if (-not `$w.FindName('PanelNoob')) { throw 'no PanelNoob' }
if (-not `$w.FindName('PanelExpert')) { throw 'no PanelExpert' }
if (`$w.FindName('PanelDoor').Visibility.ToString() -ne 'Visible') { throw 'door must be the open screen' }
if (`$w.FindName('PanelExpert').Visibility.ToString() -eq 'Visible') { throw 'expert panel must start collapsed' }
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
# Host is IoT LTSC 26100; the stated VM bench is 25H2 Pro 26200.
if ($inv.os.os_pin -notmatch '^[^/]+/(26100|26200)\.\d+$') {
    throw "Test-Reclaim11: unexpected os_pin $($inv.os.os_pin) (want EditionID/26100.x or 26200.x)"
}
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
$applyPath = Join-Path $braveDir "Apply-BravePolicy.ps1"
if (-not (Test-Path -LiteralPath $applyPath)) {
    throw "Test-Reclaim11: missing Apply-BravePolicy.ps1"
}
. $applyPath
$labDir = Join-Path $env:TEMP "reclaim11-labs-test"
New-Item -ItemType Directory -Force -Path $labDir | Out-Null
$emptyBrowser = Join-Path $labDir "empty-browser.json"
$noBrowser = Join-Path $labDir "no-browser.json"
Set-Content -LiteralPath $emptyBrowser -Value '{"browser":{}}' -Encoding UTF8
Set-Content -LiteralPath $noBrowser -Value '{"os_crypt":{"encrypted_key":"x"}}' -Encoding UTF8
Set-Reclaim11DownloadLabs -PrefsPath $emptyBrowser -NoKill
Set-Reclaim11DownloadLabs -PrefsPath $noBrowser -NoKill
foreach ($f in @($emptyBrowser, $noBrowser)) {
    $got = Get-Content -LiteralPath $f -Raw -Encoding UTF8
    if ($got -notmatch 'brave-override-download-danger-level@1') {
        throw "Test-Reclaim11: labs flag missing in $f"
    }
}

$winpe = Join-Path $root "winpe"
foreach ($need in @("offline.ps1", "Apply-Reclaim11Offline.ps1", "startnet.cmd", "stub.c")) {
    if (-not (Test-Path -LiteralPath (Join-Path $winpe $need))) { throw "Test-Reclaim11: missing winpe\$need" }
}
foreach ($need in @("killing_blows.ps1", "Apply-KillingBlows.ps1", "inventory.ps1", "noob_cleanse.ps1", "Apply-NoobCleanse.ps1", "Restore-Reclaim11Noob.ps1", "NuclearDefenderWipe-V6_3.ps1", "xbox_cleanse.ps1", "telemetry_cleanse.ps1", "nic_tune.ps1", "elevate.ps1")) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $need))) { throw "Test-Reclaim11: missing $need" }
}
$nukeSelf = Join-Path $root "NuclearDefenderWipe-V6_3.ps1"
$nukeOut = & (Join-Path $PSHOME "pwsh.exe") -NoProfile -File $nukeSelf -SelfTest
if ($LASTEXITCODE -ne 0) { throw "Test-Reclaim11: Nuclear v6.3 -SelfTest failed" }
if (($nukeOut | Out-String) -notmatch "SELFTEST v6.3 ok") {
    throw "Test-Reclaim11: Nuclear v6.3 self-test did not print ok"
}
$isoBuild = Join-Path $RepoRoot "scripts\New-Reclaim11WinPeIso.ps1"
if (-not (Test-Path -LiteralPath $isoBuild)) { throw "Test-Reclaim11: missing New-Reclaim11WinPeIso.ps1" }
$isoSrc = Get-Content -LiteralPath $isoBuild -Raw -Encoding UTF8
if ($isoSrc -notmatch "10\.1\.26100\.2454") { throw "Test-Reclaim11: ISO builder must pin ADK 10.1.26100.2454" }
if ($isoSrc -notmatch "28000") { throw "Test-Reclaim11: ISO builder must warn against ADK 28000" }
if ($isoSrc -match "/UFD") { throw "Test-Reclaim11: ISO builder must not write a USB" }
$usbBuild = Join-Path $RepoRoot "scripts\New-Reclaim11WinPeUsb.ps1"
if (-not (Test-Path -LiteralPath $usbBuild)) { throw "Test-Reclaim11: missing New-Reclaim11WinPeUsb.ps1" }
$usbSrc = Get-Content -LiteralPath $usbBuild -Raw -Encoding UTF8
if ($usbSrc -notmatch "/UFD") { throw "Test-Reclaim11: USB writer is the /UFD door" }
if ($usbSrc -notmatch "UsbMaxBytes") { throw "Test-Reclaim11: USB writer must cap stick size" }
if ($usbSrc -notmatch "IsBoot") { throw "Test-Reclaim11: USB writer must refuse boot disk" }
if ($usbSrc -notmatch "M1ABRAMS") { throw "Test-Reclaim11: USB writer must warn not to boot the desk" }
if ($usbSrc -notmatch "32GB") { throw "Test-Reclaim11: USB writer 32GiB cap protects USB HDD" }

. (Join-Path $winpe "offline.ps1")
$fx = Join-Path $env:TEMP "reclaim11-winpe-fx"
if (Test-Path -LiteralPath $fx) { Remove-Item -LiteralPath $fx -Recurse -Force }
$fxWin = Join-Path $fx "Windows"
$fxWd = Join-Path $fxWin "System32\drivers\wd"
$fxDef = Join-Path $fx "Program Files\Windows Defender"
New-Item -ItemType Directory -Force -Path $fxWd | Out-Null
New-Item -ItemType Directory -Force -Path $fxDef | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $fxWin "System32\drivers") | Out-Null
$payload = New-Object byte[] 64
$payload[0] = 0x4D; $payload[1] = 0x5A
$stubFx = Join-Path $fx "stub.exe"
[IO.File]::WriteAllBytes($stubFx, $payload)
try {
    Invoke-Reclaim11OfflineApply -CatalogPath $catPath -StubPath $stubFx -WindowsRoot $env:SystemRoot
    throw "Test-Reclaim11: host WindowsRoot must be refused"
} catch {
    if ($_.Exception.Message -notmatch "Refuse") {
        throw "Test-Reclaim11: expected host refuse, got $($_.Exception.Message)"
    }
}
foreach ($n in @("WdBoot.sys", "WdFilter.sys", "WdNisDrv.sys", "WdDevFlt.sys")) {
    [IO.File]::WriteAllBytes((Join-Path $fxWd $n), ([byte[]](1, 2, 3, 4)))
}
[IO.File]::WriteAllBytes((Join-Path $fxDef "MsMpEng.exe"), ([byte[]](1, 2, 3, 4)))
[IO.File]::WriteAllBytes((Join-Path $fxDef "NisSrv.exe"), ([byte[]](1, 2, 3, 4)))
[IO.File]::WriteAllBytes((Join-Path $fxWin "System32\drivers\fltmgr.sys"), ([byte[]](9, 9, 9, 9)))
$fltBefore = Get-FileHash -LiteralPath (Join-Path $fxWin "System32\drivers\fltmgr.sys") -Algorithm SHA256

$sbOnFx = [pscustomobject]@{ available = $true; enabled = $true; error = $null }
$rOn = Invoke-Reclaim11OfflineApply -CatalogPath $catPath -StubPath $stubFx -WindowsRoot $fxWin -SecureBoot $sbOnFx
if ($rOn.id -ne "reclaim11-winpe-v1") { throw "Test-Reclaim11: receipt id" }
if ($rOn.stub_wdboot) { throw "Test-Reclaim11: SB on must not stub WdBoot" }
if (@($rOn.skipped_elam).Count -lt 1) { throw "Test-Reclaim11: SB on must skip ELAM" }
if (@($rOn.parked | Where-Object { $_ -match "WdFilter" }).Count -lt 1) {
    throw "Test-Reclaim11: SB on still parks WdFilter"
}
if (Test-Path -LiteralPath (Join-Path $fxWd "WdFilter.sys")) {
    throw "Test-Reclaim11: WdFilter must be parked (not a usermode stub)"
}
$bootOn = [IO.File]::ReadAllBytes((Join-Path $fxWd "WdBoot.sys"))
if ($bootOn[0] -eq 0x4D) { throw "Test-Reclaim11: WdBoot must stay original when SB on" }
$fltAfterOn = Get-FileHash -LiteralPath (Join-Path $fxWin "System32\drivers\fltmgr.sys") -Algorithm SHA256
if ($fltAfterOn.Hash -ne $fltBefore.Hash) { throw "Test-Reclaim11: fltmgr.sys must not change" }
if (-not (Test-Path -LiteralPath (Join-Path $fxWin "reclaim11-winpe.log"))) {
    throw "Test-Reclaim11: missing Windows\\reclaim11-winpe.log"
}

# Reset WdFilter to a non-MZ so the second pass is visible, keep receipt path.
[IO.File]::WriteAllBytes((Join-Path $fxWd "WdFilter.sys"), ([byte[]](1, 2, 3, 4)))
[IO.File]::WriteAllBytes((Join-Path $fxWd "WdBoot.sys"), ([byte[]](1, 2, 3, 4)))
$sbOffFx = [pscustomobject]@{ available = $true; enabled = $false; error = $null }
$rOff = Invoke-Reclaim11OfflineApply -CatalogPath $catPath -StubPath $stubFx -WindowsRoot $fxWin -SecureBoot $sbOffFx
if (-not $rOff.stub_wdboot) { throw "Test-Reclaim11: SB off must allow WdBoot park" }
$bootOffPath = Join-Path $fxWd "WdBoot.sys"
if (Test-Path -LiteralPath $bootOffPath) {
    throw "Test-Reclaim11: SB off must park WdBoot (do not copy usermode EXE over .sys)"
}
if (Test-Path -LiteralPath ($bootOffPath + ".reclaim11.bak")) {
    throw "Test-Reclaim11: operator PE must not leave sidecar .bak in drivers"
}
$fltAfterOff = Get-FileHash -LiteralPath (Join-Path $fxWin "System32\drivers\fltmgr.sys") -Algorithm SHA256
if ($fltAfterOff.Hash -ne $fltBefore.Hash) { throw "Test-Reclaim11: fltmgr.sys must not change after SB-off apply" }

$gFx = Get-Reclaim11Gates -Inventory $sbOff -WinPeLog (Join-Path $fxWin "reclaim11-winpe.log")
if (-not $gFx.killing_blows) { throw "Test-Reclaim11: fixture receipt must unlock killing blows" }

# 25H2: drivers\wd empty, WdFilter.sys lives in drivers\ (not a Wd* glob).
$fx25 = Join-Path $env:TEMP "reclaim11-winpe-fx25"
if (Test-Path -LiteralPath $fx25) { Remove-Item -LiteralPath $fx25 -Recurse -Force }
$fx25Win = Join-Path $fx25 "Windows"
$fx25Drv = Join-Path $fx25Win "System32\drivers"
$fx25Wd = Join-Path $fx25Drv "wd"
$fx25Def = Join-Path $fx25 "Program Files\Windows Defender"
New-Item -ItemType Directory -Force -Path $fx25Wd | Out-Null
New-Item -ItemType Directory -Force -Path $fx25Def | Out-Null
foreach ($n in @("WdBoot.sys", "WdFilter.sys", "WdNisDrv.sys", "WdDevFlt.sys")) {
    [IO.File]::WriteAllBytes((Join-Path $fx25Drv $n), ([byte[]](1, 2, 3, 4)))
}
[IO.File]::WriteAllBytes((Join-Path $fx25Drv "wdf01000.sys"), ([byte[]](9, 9, 9, 9)))
[IO.File]::WriteAllBytes((Join-Path $fx25Def "MsMpEng.exe"), ([byte[]](1, 2, 3, 4)))
New-Item -ItemType Directory -Force -Path (Join-Path $fx25Win "System32") | Out-Null
[IO.File]::WriteAllBytes((Join-Path $fx25Win "System32\smartscreen.exe"), ([byte[]](1, 2, 3, 4)))
$wdfBefore = Get-FileHash -LiteralPath (Join-Path $fx25Drv "wdf01000.sys") -Algorithm SHA256
$r25 = Invoke-Reclaim11OfflineApply -CatalogPath $catPath -StubPath $stubFx -WindowsRoot $fx25Win -SecureBoot $sbOffFx
foreach ($n in @("WdBoot.sys", "WdFilter.sys", "WdNisDrv.sys", "WdDevFlt.sys")) {
    if (@($r25.missing) -contains $n) { throw "Test-Reclaim11: 25H2 flat drivers\ missing $n" }
}
if (@($r25.parked | Where-Object { $_ -match "WdFilter\.sys$" }).Count -lt 1) {
    throw "Test-Reclaim11: 25H2 must park drivers\WdFilter.sys"
}
if (Test-Path -LiteralPath (Join-Path $fx25Drv "WdFilter.sys")) {
    throw "Test-Reclaim11: 25H2 WdFilter.sys must not remain as a loadable driver"
}
$wdfAfter = Get-FileHash -LiteralPath (Join-Path $fx25Drv "wdf01000.sys") -Algorithm SHA256
if ($wdfAfter.Hash -ne $wdfBefore.Hash) { throw "Test-Reclaim11: wdf01000.sys must not be stubbed" }
if (-not (Test-Path -LiteralPath (Join-Path $fx25Win "reclaim11-stub.exe"))) {
    throw "Test-Reclaim11: PE must copy reclaim11-stub.exe onto the Windows volume"
}
if (-not (Test-Path -LiteralPath (Join-Path $fx25 "reclaim11\Apply-KillingBlows.ps1"))) {
    throw "Test-Reclaim11: PE must drop C:\\reclaim11\\Apply-KillingBlows.ps1"
}
if (-not (Test-Path -LiteralPath (Join-Path $fx25 "reclaim11\telemetry_cleanse.ps1"))) {
    throw "Test-Reclaim11: PE must drop C:\\reclaim11\\telemetry_cleanse.ps1"
}
$ss = [IO.File]::ReadAllBytes((Join-Path $fx25Win "System32\smartscreen.exe"))
if ($ss[0] -ne 0x4D -or $ss[1] -ne 0x5A) {
    throw "Test-Reclaim11: PE must stub smartscreen.exe (usermode) offline"
}
[IO.File]::WriteAllBytes((Join-Path $fx25Drv "WdFilter.sys.reclaim11.bak"), ([byte[]](1, 2, 3, 4)))
$r25b = Invoke-Reclaim11OfflineApply -CatalogPath $catPath -StubPath $stubFx -WindowsRoot $fx25Win -SecureBoot $sbOffFx
if (@($r25b.missing) -contains "WdFilter.sys") {
    throw "Test-Reclaim11: existing .bak must count as parked, not missing"
}

. (Join-Path $root "noob_cleanse.ps1")
$fxNoob = Join-Path $env:TEMP "reclaim11-noob-fx"
if (Test-Path -LiteralPath $fxNoob) { Remove-Item -LiteralPath $fxNoob -Recurse -Force }
$fxNoobWin = Join-Path $fxNoob "Windows"
$fxNoobDrv = Join-Path $fxNoobWin "System32\drivers"
New-Item -ItemType Directory -Force -Path $fxNoobDrv | Out-Null
[IO.File]::WriteAllBytes((Join-Path $fxNoobDrv "WdFilter.sys.reclaim11.bak"), ([byte[]](1, 2, 3, 4)))
[IO.File]::WriteAllBytes((Join-Path $fxNoobDrv "wdf01000.sys"), ([byte[]](9, 9, 9, 9)))
$noob = Invoke-Reclaim11NoobCleanse -Root $root -VolumeRoot $fxNoob
if (@($noob.items).Count -lt 1) { throw "Test-Reclaim11: safe cleanse must move the bak" }
if (Test-Path -LiteralPath (Join-Path $fxNoobDrv "WdFilter.sys.reclaim11.bak")) {
    throw "Test-Reclaim11: safe cleanse must move, not leave, the bak"
}
if (-not (Test-Path -LiteralPath (Join-Path $fxNoobDrv "wdf01000.sys"))) {
    throw "Test-Reclaim11: safe cleanse must not touch wdf01000.sys"
}
if (-not (Test-Path -LiteralPath $noob.manifest_path)) {
    throw "Test-Reclaim11: noob restore.json missing"
}
$man = Get-Content -LiteralPath $noob.manifest_path -Raw -Encoding UTF8 | ConvertFrom-Json
if ($man.id -ne "reclaim11-noob-v1") { throw "Test-Reclaim11: restore.json id" }
$row = @($man.items) | Where-Object { $_.relative -like "*WdFilter.sys.reclaim11.bak" } | Select-Object -First 1
if (-not $row) { throw "Test-Reclaim11: restore.json missing bak path" }
foreach ($k in @("original", "backup", "relative", "sha256", "length")) {
    if (-not $row.PSObject.Properties[$k]) { throw "Test-Reclaim11: restore.json missing $k" }
}
if ([string]$row.sha256.Length -ne 64) { throw "Test-Reclaim11: restore.json sha256" }
$rst = Restore-Reclaim11NoobBackup -Manifest $noob.manifest_path
if (-not (Test-Path -LiteralPath (Join-Path $fxNoobDrv "WdFilter.sys.reclaim11.bak"))) {
    throw "Test-Reclaim11: noob restore must put the file back"
}
try {
    Invoke-Reclaim11NoobCleanse -Root $root
    throw "Test-Reclaim11: safe cleanse must refuse this desk"
} catch {
    if ($_.Exception.Message -notmatch "Refuse: desk") {
        throw "Test-Reclaim11: expected safe-cleanse desk refuse, got $($_.Exception.Message)"
    }
}
Remove-Item -LiteralPath $fx, $fx25, $fxNoob -Recurse -Force

. (Join-Path $root "killing_blows.ps1")
foreach ($s in @($cat.services_pack_a)) {
    if (@($cat.never_touch_services) -contains $s) {
        throw "Test-Reclaim11: pack A collides never-touch $s"
    }
}
$taskPaths = @($cat.scheduled_task_paths_pack_a)
if ($taskPaths -notcontains "\Microsoft\Windows\Windows Defender\") {
    throw "Test-Reclaim11: catalog missing Defender task folder"
}
if ($taskPaths -notcontains "\Microsoft\Windows\ExploitGuard\") {
    throw "Test-Reclaim11: catalog missing ExploitGuard task folder"
}
if (@($taskPaths | Where-Object { $_ -eq "\" -or $_ -eq "\Microsoft\Windows\" }).Count -gt 0) {
    throw "Test-Reclaim11: scheduled-task paths must stay named folders"
}
$regLock = @($cat.registry_lock_pack_a)
if ($regLock -notcontains "HKLM:\SOFTWARE\Microsoft\Windows Defender") {
    throw "Test-Reclaim11: catalog missing Defender software key lock"
}
if (@($regLock | Where-Object { $_ -like "*\Policies\Microsoft\Windows Defender*" }).Count -gt 0) {
    throw "Test-Reclaim11: GPO DisableAntiSpyware key must not be deleted"
}
if (-not (Test-Reclaim11PackATaskPath -Catalog $cat -Path "\Microsoft\Windows\Windows Defender\")) {
    throw "Test-Reclaim11: Defender task path must match"
}
if (Test-Reclaim11PackATaskPath -Catalog $cat -Path "\Microsoft\Windows\") {
    throw "Test-Reclaim11: must not match all Microsoft\Windows tasks"
}
$kbSrc = Get-Content -LiteralPath (Join-Path $root "killing_blows.ps1") -Raw -Encoding UTF8
if ($kbSrc -notmatch "Export-ScheduledTask") { throw "Test-Reclaim11: killing blows must snapshot task XML" }
$nukeSrc = Get-Content -LiteralPath (Join-Path $root "NuclearDefenderWipe-V6_3.ps1") -Raw -Encoding UTF8
if ($nukeSrc -notmatch "ExploitGuard") { throw "Test-Reclaim11: Nuclear must delete ExploitGuard tasks" }
if ($nukeSrc -match '\.\s+\$invPath') {
    throw "Test-Reclaim11: Nuclear must not dotsource inventory.ps1 into wipe scope"
}
if ($nukeSrc -notmatch '(?s)& \{\s*\.\s+\$el') {
    throw "Test-Reclaim11: Nuclear TI hop must dotsource elevate.ps1 in a child scope"
}
foreach ($wu in @("wuauserv", "UsoSvc", "WaaSMedicSvc", "UsoCoreWorker.exe", "MoUsoCoreWorker.exe")) {
    if ($nukeSrc -notmatch [regex]::Escape($wu)) {
        throw "Test-Reclaim11: Nuclear remainder must name WU $wu"
    }
}
if ($nukeSrc -notmatch "usosvc\.dll") {
    throw "Test-Reclaim11: Nuclear must never-stub usosvc.dll"
}
$catJson = Get-Content -LiteralPath $catPath -Raw -Encoding UTF8
foreach ($wu in @("wuauserv", "UsoSvc", "WaaSMedicSvc")) {
    if ($catJson -match $wu) {
        throw "Test-Reclaim11: pack A catalog must not list WU $wu (26H1 Update stays until Nuclear)"
    }
}
if ($kbSrc -match "wuauserv") {
    throw "Test-Reclaim11: killing blows must not sc delete wuauserv"
}
try {
    Invoke-Reclaim11KillingBlows -Root $root
    throw "Test-Reclaim11: killing blows must refuse this desk"
} catch {
    if ($_.Exception.Message -notmatch "Refuse: desk") {
        throw "Test-Reclaim11: expected desk refuse, got $($_.Exception.Message)"
    }
}
$dryKill = Invoke-Reclaim11KillingBlows -Root $root -WhatIf
if (-not [bool]$dryKill.what_if) { throw "Test-Reclaim11: killing -T must set what_if" }
if ([string]$dryKill.would_refuse -notmatch "desk") { throw "Test-Reclaim11: killing -T must report desk refuse" }
if (@($dryKill.would).Count -lt 1) { throw "Test-Reclaim11: killing -T must list would-do" }

. (Join-Path $root "xbox_cleanse.ps1")
$hid = Merge-Reclaim11HidePages -Current "" -Hide @("gaming-gamebar", "gaming-gamedvr", "gaming-trueplay", "gaming-broadcasting", "gaming-captures")
if ($hid -notmatch "^hide:gaming-gamebar;") { throw "Test-Reclaim11: xbox hide gamebar" }
if ($hid -notmatch ";gaming-gamedvr;") { throw "Test-Reclaim11: xbox hide gamedvr (Captures page)" }
if ($hid -notmatch ";gaming-captures") { throw "Test-Reclaim11: xbox hide captures token" }
if ($hid -match ";hide:") { throw "Test-Reclaim11: GPO hide: must not repeat per page" }
$xbSrc = Get-Content -LiteralPath (Join-Path $root "xbox_cleanse.ps1") -Raw -Encoding UTF8
if ($xbSrc -notmatch 'HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer') {
    throw "Test-Reclaim11: Settings hide must write HKCU as well as HKLM"
}
if ($xbSrc -notmatch "SystemSettings") {
    throw "Test-Reclaim11: must kill SystemSettings.exe after hide"
}
if ($hid -match "gamemode") {
    throw "Test-Reclaim11: xbox hide must not hide Game Mode"
}
$hid2 = Merge-Reclaim11HidePages -Current "hide:foo" -Hide @("gaming-gamebar")
if ($hid2 -ne "hide:foo;gaming-gamebar") { throw "Test-Reclaim11: xbox hide must keep existing pages as GPO list" }
$hid3 = Merge-Reclaim11HidePages -Current "hide:gaming-gamebar;hide:gaming-gamedvr" -Hide @("gaming-captures")
if ($hid3 -match ";hide:") { throw "Test-Reclaim11: must rewrite old per-token hide: lists" }
if ($hid3 -notmatch "^hide:gaming-gamebar;gaming-gamedvr;gaming-captures$") {
    throw "Test-Reclaim11: rewrite old hide list, got $hid3"
}
if ($xbSrc -notmatch '(?s)if \(\$KeepCaptures\).*gaming-gamedvr') {
    throw "Test-Reclaim11: KeepCaptures must skip gaming-gamedvr (Captures page), not only gaming-captures"
}
if ($xbSrc -match '& sc\.exe create \$name binPath= \$bin') {
    throw "Test-Reclaim11: xbox restore must quote sc create binPath= (svchost -k)"
}
if ($xbSrc -notmatch 'LASTEXITCODE -eq 0') {
    throw "Test-Reclaim11: xbox restore must only count sc create exit 0"
}
$applyKill = Get-Content -LiteralPath (Join-Path $root "Apply-KillingBlows.ps1") -Raw -Encoding UTF8
if ($applyKill -notmatch 'RECLAIM11_AS_TI') {
    throw "Test-Reclaim11: Apply-KillingBlows must omit Write-Host on TI stdout"
}
try {
    Merge-Reclaim11HidePages -Current "" -Hide @("gaming-gamemode") | Out-Null
    throw "Test-Reclaim11: hide gamemode must refuse"
} catch {
    if ($_.Exception.Message -notmatch "refuse hide") {
        throw "Test-Reclaim11: expected gamemode refuse, got $($_.Exception.Message)"
    }
}
$cands = @(Get-Reclaim11XboxServiceCandidates)
if ($cands -contains "xboxgip") { throw "Test-Reclaim11: xboxgip is the controller driver" }
if ($cands -contains "BFE") { throw "Test-Reclaim11: Xbox list hit BFE" }
try {
    Invoke-Reclaim11XboxCleanse -Root $root
    throw "Test-Reclaim11: xbox hide must refuse this desk"
} catch {
    if ($_.Exception.Message -notmatch "Refuse: desk") {
        throw "Test-Reclaim11: expected xbox desk refuse, got $($_.Exception.Message)"
    }
}
$dryXbox = Invoke-Reclaim11XboxCleanse -Root $root -WhatIf
if (-not [bool]$dryXbox.what_if) { throw "Test-Reclaim11: xbox -T must set what_if" }
if ([bool]$dryXbox.mutate) { throw "Test-Reclaim11: xbox -T must not mutate" }
if ([string]$dryXbox.would_refuse -notmatch "desk") { throw "Test-Reclaim11: xbox -T must report desk refuse" }
if (-not (Test-Path -LiteralPath (Join-Path $root "catalog.json"))) { throw "Test-Reclaim11: catalog vanished after xbox -T" }
if ($script:XboxAppx -notcontains "Microsoft.BingNews") { throw "Test-Reclaim11: bloat list missing BingNews" }
if ($script:XboxAppx -notcontains "Microsoft.WindowsFeedbackHub") { throw "Test-Reclaim11: bloat list missing FeedbackHub" }
if ($script:XboxAppx -notcontains "Microsoft.GamingServices") { throw "Test-Reclaim11: bloat list missing GamingServices" }
if ($script:XboxAppx -contains "Microsoft.XboxGameCallableUI") { throw "Test-Reclaim11: XboxGameCallableUI must stay" }
$gbOff = @($script:XboxGameBarOff | ForEach-Object { $_.Name })
if ($gbOff -notcontains "EnableGameBar") { throw "Test-Reclaim11: GameBar.reg EnableGameBar missing" }
if ($gbOff -notcontains "ShowBroadcastPanel") { throw "Test-Reclaim11: GameBar.reg ShowBroadcastPanel missing" }
if ($gbOff -contains "AllowAutoGameMode") { throw "Test-Reclaim11: Game Mode Auto must stay" }
if ($gbOff -contains "AutoGameModeEnabled") { throw "Test-Reclaim11: Game Mode Enabled must stay" }
if ($script:XboxGameBarNever -notcontains "AllowAutoGameMode") {
    throw "Test-Reclaim11: must refuse AllowAutoGameMode"
}
if (@($script:XboxAppx | Where-Object { $_ -match '\*' }).Count -gt 0) {
    throw "Test-Reclaim11: xbox Appx list must be named, not a wildcard"
}
$bare = [pscustomobject]@{ Start = 3 }
if ($null -ne (Get-Reclaim11OptionalText -Object $bare -Name "ObjectName")) {
    throw "Test-Reclaim11: missing ObjectName must be null, not throw"
}
if ((Get-Reclaim11OptionalDword -Object $bare -Name "Start") -ne 3) {
    throw "Test-Reclaim11: optional Start dword"
}
$xbSrc = Get-Content -LiteralPath (Join-Path $root "xbox_cleanse.ps1") -Raw -Encoding UTF8
if ($xbSrc -match "Invoke-Reclaim11AsTrustedInstaller") {
    throw "Test-Reclaim11: xbox_cleanse must not TI-hop (admin is enough)"
}
$badMan = Join-Path $env:TEMP "reclaim11-xbox-bad.json"
Set-Content -LiteralPath $badMan -Value '{"id":"nope"}' -Encoding UTF8
try {
    Restore-Reclaim11XboxBackup -Manifest $badMan
    throw "Test-Reclaim11: bad xbox manifest must throw"
} catch {
    if ($_.Exception.Message -notmatch "not an Xbox") {
        throw "Test-Reclaim11: expected xbox manifest refuse, got $($_.Exception.Message)"
    }
}
$okMan = Join-Path $env:TEMP "reclaim11-xbox-ok.json"
Set-Content -LiteralPath $okMan -Value '{"id":"reclaim11-xbox-v1","settings_page_visibility":{"before":"","after":""},"services":[],"appx":[]}' -Encoding UTF8
try {
    Restore-Reclaim11XboxBackup -Manifest $okMan
    throw "Test-Reclaim11: xbox restore must refuse this desk"
} catch {
    if ($_.Exception.Message -notmatch "Refuse: desk") {
        throw "Test-Reclaim11: expected xbox restore desk refuse, got $($_.Exception.Message)"
    }
}
Remove-Item -LiteralPath $badMan, $okMan -Force

. (Join-Path $root "telemetry_cleanse.ps1")
if (Test-Path -LiteralPath (Join-Path $root "ctt")) {
    throw "Test-Reclaim11: ctt folder must not ship"
}
if ($script:TelemetryServices -notcontains "DiagTrack") { throw "Test-Reclaim11: telemetry missing DiagTrack" }
if ($script:TelemetryServices -notcontains "dmwappushservice") { throw "Test-Reclaim11: telemetry missing dmwappushservice" }
if ($script:TelemetryServices -contains "BFE") { throw "Test-Reclaim11: telemetry hit BFE" }
if ($script:TelemetryServices -contains "EventLog") { throw "Test-Reclaim11: telemetry hit EventLog" }
$telSrc = Get-Content -LiteralPath (Join-Path $root "telemetry_cleanse.ps1") -Raw -Encoding UTF8
if ($telSrc -match "WPFTweaks|christitus|Chris Titus|Set-MpPreference") {
    throw "Test-Reclaim11: telemetry_cleanse must not carry third-party tweak ids"
}
try {
    Invoke-Reclaim11TelemetryCleanse -Root $root
    throw "Test-Reclaim11: telemetry must refuse this desk"
} catch {
    if ($_.Exception.Message -notmatch "Refuse: desk") {
        throw "Test-Reclaim11: expected telemetry desk refuse, got $($_.Exception.Message)"
    }
}
$dryTel = Invoke-Reclaim11TelemetryCleanse -Root $root -WhatIf
if (-not [bool]$dryTel.what_if) { throw "Test-Reclaim11: telemetry -T must set what_if" }
if ([string]$dryTel.would_refuse -notmatch "desk") { throw "Test-Reclaim11: telemetry -T must report desk refuse" }

. (Join-Path $root "nic_tune.ps1")
$vmx = [pscustomobject]@{ Name = "Ethernet0"; InterfaceDescription = "vmxnet3 Ethernet Adapter"; PhysicalMediaType = "802.3"; Status = "Up" }
if (Test-Reclaim11NicSkipAdapter -Adapter $vmx) { throw "Test-Reclaim11: must tune guest vmxnet3" }
$vmnet = [pscustomobject]@{ Name = "VMware Network Adapter VMnet8"; InterfaceDescription = "VMware Virtual Ethernet Adapter for VMnet8"; PhysicalMediaType = "802.3"; Status = "Up" }
if (-not (Test-Reclaim11NicSkipAdapter -Adapter $vmnet)) { throw "Test-Reclaim11: must skip host VMnet" }
$intelProps = @(
    [pscustomobject]@{ DisplayName = "Energy Efficient Ethernet"; RegistryKeyword = "*EEE"; RegistryValue = @("1"); ValidRegistryValues = @("0", "1") },
    [pscustomobject]@{ DisplayName = "Receive Side Scaling"; RegistryKeyword = "*RSS"; RegistryValue = @("0"); ValidRegistryValues = @("0", "1") },
    [pscustomobject]@{ DisplayName = "Receive Buffers"; RegistryKeyword = "*ReceiveBuffers"; RegistryValue = @("256"); ValidRegistryValues = @("128", "256", "512", "1024", "2048", "4096") },
    [pscustomobject]@{ DisplayName = "Transmit Buffers"; RegistryKeyword = "*TransmitBuffers"; RegistryValue = @("256"); ValidRegistryValues = @("128", "256", "512", "1024", "2048") }
)
$nicPlan = Resolve-Reclaim11NicPlan -AdapterName "Ethernet" -Props $intelProps
$eee = @($nicPlan | Where-Object { $_.keyword -eq "*EEE" } | Select-Object -First 1)
if (-not $eee -or $eee.wanted -ne "0") { throw "Test-Reclaim11: NIC map must disable *EEE" }
$rss = @($nicPlan | Where-Object { $_.keyword -eq "*RSS" } | Select-Object -First 1)
if (-not $rss -or $rss.wanted -ne "1") { throw "Test-Reclaim11: NIC map must enable *RSS" }
$rx = @($nicPlan | Where-Object { $_.keyword -eq "*ReceiveBuffers" } | Select-Object -First 1)
if (-not $rx -or $rx.wanted -ne "256") { throw "Test-Reclaim11: NIC Rx already 256 stays in CS2 band" }
$fatProps = @(
    [pscustomobject]@{ DisplayName = "Receive Buffers"; RegistryKeyword = "*ReceiveBuffers"; RegistryValue = @("4096"); ValidRegistryValues = @("256", "512", "1024", "2048", "4096") }
)
$fatPlan = Resolve-Reclaim11NicPlan -AdapterName "Ethernet" -Props $fatProps
$fatRx = @($fatPlan | Where-Object { $_.keyword -eq "*ReceiveBuffers" } | Select-Object -First 1)
if (-not $fatRx -or $fatRx.wanted -ne "512") { throw "Test-Reclaim11: NIC Rx 4096 must drop to 512 for CS2" }
$rtlProps = @(
    [pscustomobject]@{ DisplayName = "Green Ethernet"; RegistryKeyword = "GreenEthernet"; RegistryValue = @("1"); ValidRegistryValues = @("0", "1") }
)
$rtlPlan = Resolve-Reclaim11NicPlan -AdapterName "Ethernet" -Props $rtlProps
if (-not (@($rtlPlan | Where-Object { $_.keyword -eq "GreenEthernet" -and $_.wanted -eq "0" }))) {
    throw "Test-Reclaim11: NIC map must disable Realtek GreenEthernet"
}
$dryNic = Invoke-Reclaim11NicTune -Root $root -WhatIf
if (-not [bool]$dryNic.what_if) { throw "Test-Reclaim11: nic -T must set what_if" }
if ([bool]$dryNic.mutate) { throw "Test-Reclaim11: nic -T must not mutate" }
if ([string]$dryNic.would_refuse -notmatch "desk") { throw "Test-Reclaim11: nic -T must report desk refuse" }
$nicSrc = Get-Content -LiteralPath (Join-Path $root "nic_tune.ps1") -Raw -Encoding UTF8
if ($nicSrc -match "BFE|mpssvc") {
    if ($nicSrc -notmatch "Never BFE") { throw "Test-Reclaim11: nic_tune hit BFE without never" }
}
$telMan = Join-Path $env:TEMP "reclaim11-tel-ok.json"
Set-Content -LiteralPath $telMan -Value '{"id":"reclaim11-telemetry-v1","allow":{"present":false},"services":[]}' -Encoding UTF8
try {
    Restore-Reclaim11TelemetryBackup -Manifest $telMan -Root $root
    throw "Test-Reclaim11: telemetry restore must refuse this desk"
} catch {
    if ($_.Exception.Message -notmatch "Refuse: desk") {
        throw "Test-Reclaim11: expected telemetry restore desk refuse, got $($_.Exception.Message)"
    }
}
$telBad = Join-Path $env:TEMP "reclaim11-tel-bad.json"
Set-Content -LiteralPath $telBad -Value '{"id":"nope"}' -Encoding UTF8
try {
    Restore-Reclaim11TelemetryBackup -Manifest $telBad -Root $root
    throw "Test-Reclaim11: bad telemetry manifest must throw"
} catch {
    if ($_.Exception.Message -notmatch "not a telemetry") {
        throw "Test-Reclaim11: expected telemetry manifest refuse, got $($_.Exception.Message)"
    }
}
Remove-Item -LiteralPath $telMan, $telBad -Force

if ($isoSrc -notmatch "telemetry_cleanse\.ps1") {
    throw "Test-Reclaim11: ISO builder must copy telemetry_cleanse.ps1"
}
if ($isoSrc -match "\\ctt") { throw "Test-Reclaim11: ISO builder must not copy a ctt folder" }

. (Join-Path $root "elevate.ps1")
$elSrc = Get-Content -LiteralPath (Join-Path $root "elevate.ps1") -Raw -Encoding UTF8
if ($elSrc -match "TeamM2|wsudo\.exe|MinSudo\.exe") { throw "Test-Reclaim11: elevate.ps1 must not call wsudo/MinSudo" }
if ($elSrc -notmatch "NT SERVICE\\TrustedInstaller") { throw "Test-Reclaim11: elevate.ps1 missing TI principal" }
if ($elSrc -match "/SD 01/01/2099") {
    throw "Test-Reclaim11: SYSTEM hop must not use locale schtasks /SD (E_FAIL on sv-SE)"
}
if ($elSrc -notmatch "NT AUTHORITY\\SYSTEM") {
    throw "Test-Reclaim11: SYSTEM hop must register via Task Scheduler COM"
}
if (Test-Reclaim11TrustedInstaller) { throw "Test-Reclaim11: test host should not already be TI" }
$run = New-Reclaim11TiRunnerScript -PayloadFile (Join-Path $root "xbox_cleanse.ps1") -LogFile (Join-Path $env:TEMP "reclaim11-ti-test.log") -DoneFile (Join-Path $env:TEMP "reclaim11-ti-test.done")
try {
    $rt = Get-Content -LiteralPath $run -Raw -Encoding UTF8
    if ($rt -notmatch "RECLAIM11_AS_TI") { throw "Test-Reclaim11: TI runner missing env flag" }
} finally {
    Remove-Item -LiteralPath $run -Force -ErrorAction SilentlyContinue
}

Write-Output ("Test-Reclaim11: ok catalog pack-A gates xaml brave-policy winpe blows os_pin={0} sb={1} stub_wdboot={2}" -f `
    $inv.os.os_pin, $inv.secure_boot.enabled, $inv.gates.stub_wdboot)
exit 0
