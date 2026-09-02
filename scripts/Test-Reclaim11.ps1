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
foreach ($need in @("killing_blows.ps1", "Apply-KillingBlows.ps1", "inventory.ps1")) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $need))) { throw "Test-Reclaim11: missing $need" }
}
$isoBuild = Join-Path $RepoRoot "scripts\New-Reclaim11WinPeIso.ps1"
if (-not (Test-Path -LiteralPath $isoBuild)) { throw "Test-Reclaim11: missing New-Reclaim11WinPeIso.ps1" }
$isoSrc = Get-Content -LiteralPath $isoBuild -Raw -Encoding UTF8
if ($isoSrc -notmatch "10\.1\.26100\.2454") { throw "Test-Reclaim11: ISO builder must pin ADK 10.1.26100.2454" }
if ($isoSrc -notmatch "28000") { throw "Test-Reclaim11: ISO builder must warn against ADK 28000" }
if ($isoSrc -match "/UFD") { throw "Test-Reclaim11: ISO builder must not write a USB" }

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
if (-not (Test-Path -LiteralPath ($bootOffPath + ".reclaim11.bak"))) {
    throw "Test-Reclaim11: WdBoot.bak missing"
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
$ss = [IO.File]::ReadAllBytes((Join-Path $fx25Win "System32\smartscreen.exe"))
if ($ss[0] -ne 0x4D -or $ss[1] -ne 0x5A) {
    throw "Test-Reclaim11: PE must stub smartscreen.exe (usermode) offline"
}
Remove-Item -LiteralPath $fx, $fx25 -Recurse -Force

. (Join-Path $root "killing_blows.ps1")
foreach ($s in @($cat.services_pack_a)) {
    if (@($cat.never_touch_services) -contains $s) {
        throw "Test-Reclaim11: pack A collides never-touch $s"
    }
}
try {
    Invoke-Reclaim11KillingBlows -Root $root
    throw "Test-Reclaim11: killing blows must refuse this desk"
} catch {
    if ($_.Exception.Message -notmatch "Refuse: desk") {
        throw "Test-Reclaim11: expected desk refuse, got $($_.Exception.Message)"
    }
}

Write-Output ("Test-Reclaim11: ok catalog pack-A gates xaml brave-policy winpe blows os_pin={0} sb={1} stub_wdboot={2}" -f `
    $inv.os.os_pin, $inv.secure_boot.enabled, $inv.gates.stub_wdboot)
exit 0
