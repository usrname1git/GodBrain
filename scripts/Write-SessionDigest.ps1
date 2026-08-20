# Pointer for the next loop. Not a wiki recap. Not a second brain.
# Writes logs/where-we-are.md. Optional /api/remember so Galaxy can see it.
# Usage:
#   .\scripts\Write-SessionDigest.ps1 -Now "..." -Next "..." [-Blocked "..."] [-Remember]

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Now,
    [Parameter(Mandatory = $true)]
    [string]$Next,
    [string]$Blocked = "",
    [string]$RepoRoot = $PSScriptRoot,
    [switch]$Remember
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Resolve-GodBrainRoot.ps1")
$logDir = Join-Path $RepoRoot "logs"
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}

$branch = ""
try {
    $branch = (& git -C $RepoRoot rev-parse --abbrev-ref HEAD 2>$null)
    if ($branch) { $branch = $branch.Trim() }
} catch { }

$at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm") + "Z"
$lines = @(
    "# Where we are",
    "",
    "at: $at",
    "branch: $branch",
    "",
    "## This session",
    $Now.Trim(),
    "",
    "## Next",
    $Next.Trim()
)
if (-not [string]::IsNullOrWhiteSpace($Blocked)) {
    $lines += @("", "## Blocked / later", $Blocked.Trim())
}
$lines += @(
    "",
    "Read this before inventing a new plan. Then git status, Heal last, Golden Records."
)

$body = ($lines -join "`n") + "`n"
$path = Join-Path $logDir "where-we-are.md"
$tmp = $path + ".tmp"
$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($tmp, $body, $utf8)
Move-Item -LiteralPath $tmp -Destination $path -Force
Write-Host "wrote $path"
try {
    Invoke-RestMethod -Uri "http://127.0.0.1:8083/api/brief" -TimeoutSec 3 | Out-Null
} catch { }

if ($Remember -and $env:GODBRAIN_API_TOKEN) {
    try {
        $headers = @{
            "Content-Type"  = "application/json"
            "Authorization" = "Bearer $($env:GODBRAIN_API_TOKEN)"
        }
        $payload = @{
            text   = "Session digest (candidate)`n$body"
            sector = "operator"
        } | ConvertTo-Json
        Invoke-RestMethod -Uri "http://127.0.0.1:8083/api/remember" `
            -Method POST -Headers $headers -Body $payload | Out-Null
        Write-Host "remembered"
    } catch {
        Write-Host "remember skipped: $_"
    }
}
