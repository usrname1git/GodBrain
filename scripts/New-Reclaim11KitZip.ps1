# Pack a standalone Reclaim11 download (GitHub Releases). Not the GodBrain tree.
# Includes the WinPE ISO builder so PREP MEDIA works without the repo.
# Does not include a 600 MB ISO. Does not irm|iex.
[CmdletBinding()]
param(
    [string]$RepoRoot = $PSScriptRoot,
    [string]$OutZip = "C:\nvme\reclaim11\Reclaim11-kit-v10.zip"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Resolve-Reclaim11Kit.ps1")

$kit = $Reclaim11Root
$cat = Get-Content -LiteralPath (Join-Path $kit "catalog.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$ver = "10"
if ($cat.PSObject.Properties["kit_version"] -and -not [string]::IsNullOrWhiteSpace([string]$cat.kit_version)) {
    $ver = [string]$cat.kit_version
}
if ($OutZip -match 'Reclaim11-kit-v\d+\.zip$' -and $OutZip -notmatch ("Reclaim11-kit-v{0}\.zip$" -f [regex]::Escape($ver))) {
    $OutZip = Join-Path (Split-Path -Parent $OutZip) ("Reclaim11-kit-v{0}.zip" -f $ver)
}

$need = @(
    (Join-Path $kit "Reclaim11.cmd"),
    (Join-Path $kit "catalog.json"),
    (Join-Path $kit "README.md"),
    (Join-Path $kit "ps1\Reclaim11.ps1"),
    (Join-Path $kit "ps1\xbox_cleanse.ps1"),
    (Join-Path $kit "ui\MainWindow.xaml"),
    (Join-Path $kit "winpe\offline.ps1"),
    (Join-Path $kit "winpe\Apply-Reclaim11Offline.ps1"),
    (Join-Path $kit "winpe\Start-Reclaim11Pe.ps1"),
    (Join-Path $kit "winpe\Skip-Reclaim11WinRe.ps1"),
    (Join-Path $kit "winpe\startnet.cmd"),
    (Join-Path $kit "winpe\stub.c"),
    (Join-Path $PSScriptRoot "New-Reclaim11WinPeIso.ps1"),
    (Join-Path $PSScriptRoot "Resolve-Reclaim11Kit.ps1")
)
foreach ($p in $need) {
    if (-not (Test-Path -LiteralPath $p)) { throw "New-Reclaim11KitZip: missing $p" }
}

$stageRoot = Join-Path $env:TEMP ("reclaim11-kit-stage-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$stage = Join-Path $stageRoot "Reclaim11"
New-Item -ItemType Directory -Path (Join-Path $stage "ps1") | Out-Null
New-Item -ItemType Directory -Path (Join-Path $stage "ui") | Out-Null
New-Item -ItemType Directory -Path (Join-Path $stage "winpe") | Out-Null
New-Item -ItemType Directory -Path (Join-Path $stage "scripts") | Out-Null
New-Item -ItemType Directory -Path (Join-Path $stage "brave-policy") | Out-Null

Copy-Item -LiteralPath (Join-Path $kit "Reclaim11.cmd") -Destination (Join-Path $stage "Reclaim11.cmd") -Force
Copy-Item -LiteralPath (Join-Path $kit "catalog.json") -Destination (Join-Path $stage "catalog.json") -Force
Copy-Item -LiteralPath (Join-Path $kit "README.md") -Destination (Join-Path $stage "README.md") -Force
Get-ChildItem -LiteralPath (Join-Path $kit "ps1") -Filter *.ps1 | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $stage "ps1\$($_.Name)") -Force
}
foreach ($n in @("MainWindow.xaml", "DoorChooser.jpg", "ExpertPanel.jpg")) {
    $s = Join-Path $kit "ui\$n"
    if (Test-Path -LiteralPath $s) {
        Copy-Item -LiteralPath $s -Destination (Join-Path $stage "ui\$n") -Force
    }
}
foreach ($n in @("offline.ps1", "Apply-Reclaim11Offline.ps1", "Start-Reclaim11Pe.ps1", "Skip-Reclaim11WinRe.ps1", "startnet.cmd", "stub.c")) {
    Copy-Item -LiteralPath (Join-Path $kit "winpe\$n") -Destination (Join-Path $stage "winpe\$n") -Force
}
foreach ($n in @("New-Reclaim11WinPeIso.ps1", "New-Reclaim11WinPeUsb.ps1", "Resolve-Reclaim11Kit.ps1")) {
    $s = Join-Path $PSScriptRoot $n
    if (Test-Path -LiteralPath $s) {
        Copy-Item -LiteralPath $s -Destination (Join-Path $stage "scripts\$n") -Force
    }
}
$brave = Join-Path $kit "brave-policy"
if (Test-Path -LiteralPath $brave) {
    Get-ChildItem -LiteralPath $brave -File | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $stage "brave-policy\$($_.Name)") -Force
    }
}

$outParent = Split-Path -Parent $OutZip
if ($outParent -and -not (Test-Path -LiteralPath $outParent)) {
    New-Item -ItemType Directory -Path $outParent | Out-Null
}
if (Test-Path -LiteralPath $OutZip) { Remove-Item -LiteralPath $OutZip -Force }

Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($stageRoot, $OutZip)
Remove-Item -LiteralPath $stageRoot -Recurse -Force

$hash = (Get-FileHash -LiteralPath $OutZip -Algorithm SHA256).Hash.ToLowerInvariant()
$shaPath = $OutZip + ".sha256"
Set-Content -LiteralPath $shaPath -Value ("{0}  {1}" -f $hash, (Split-Path -Leaf $OutZip)) -Encoding ASCII

[pscustomobject]@{
    zip         = $OutZip
    sha256      = $hash
    sha_file    = $shaPath
    kit_version = $ver
    bytes       = (Get-Item -LiteralPath $OutZip).Length
} | ConvertTo-Json -Compress
Write-Host ("Reclaim11 kit zip: {0} ({1:N0} bytes) sha256={2}" -f $OutZip, (Get-Item -LiteralPath $OutZip).Length, $hash)
