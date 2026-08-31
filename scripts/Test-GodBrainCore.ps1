# Unified no-GPU core gate. Desk doors plus Jarvis offline tests.
# Writes logs/last-core-gate.json.
#
#   .\scripts\Test-GodBrainCore.ps1
#   .\scripts\Test-GodBrainCore.ps1 -LiveMouth

[CmdletBinding()]
param(
    [string]$RepoRoot = $PSScriptRoot,
    [string]$Base = "http://127.0.0.1:8083",
    [switch]$LiveMouth,
    [switch]$LiveJarvis
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Resolve-GodBrainRoot.ps1")

$fails = [System.Collections.Generic.List[string]]::new()
$parts = [System.Collections.Generic.List[object]]::new()

function Add-Part([string]$Name, [bool]$Ok, [string]$Note) {
    $parts.Add([pscustomobject]@{ name = $Name; ok = $Ok; note = $Note })
    if (-not $Ok) { $fails.Add("$Name : $Note") }
}

$hostExe = (Get-Process -Id $PID).Path
$desk = Join-Path $RepoRoot "Test-GodBrainDesk.ps1"
$jarvis = Join-Path $RepoRoot "scripts\Test-JarvisLoop.ps1"
if (-not (Test-Path -LiteralPath $desk)) {
    Add-Part "desk" $false "missing Test-GodBrainDesk.ps1"
} else {
    $p = Start-Process -FilePath $hostExe -ArgumentList @(
        "-NoProfile", "-File", $desk, "-RepoRoot", $RepoRoot, "-Base", $Base
    ) -Wait -PassThru -NoNewWindow
    Add-Part "desk" ($p.ExitCode -eq 0) $(if ($p.ExitCode -eq 0) { "ok" } else { "exit $($p.ExitCode)" })
}

if (-not (Test-Path -LiteralPath $jarvis)) {
    Add-Part "jarvis" $false "missing Test-JarvisLoop.ps1"
} else {
    $jarvisArgs = @("-NoProfile", "-File", $jarvis, "-RepoRoot", $RepoRoot, "-Base", $Base)
    if ($LiveMouth) { $jarvisArgs += "-LiveMouth" }
    if ($LiveJarvis) { $jarvisArgs += "-LiveJarvis" }
    $p = Start-Process -FilePath $hostExe -ArgumentList $jarvisArgs -Wait -PassThru -NoNewWindow
    Add-Part "jarvis" ($p.ExitCode -eq 0) $(if ($p.ExitCode -eq 0) { "ok" } else { "exit $($p.ExitCode)" })
}

$ok = ($fails.Count -eq 0)
$result = [ordered]@{
    at     = (Get-Date).ToUniversalTime().ToString("o")
    ok     = $ok
    parts  = @($parts)
    fails  = @($fails)
}
$logDir = Join-Path $RepoRoot "logs"
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}
$outFile = Join-Path $logDir "last-core-gate.json"
$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($outFile, ($result | ConvertTo-Json -Depth 6 -Compress), $utf8)

if (-not $ok) {
    Write-Host ("core-gate FAIL " + ($fails -join "; "))
    exit 1
}
Write-Host "core-gate ok desk+jarvis"
exit 0
