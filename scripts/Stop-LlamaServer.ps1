# Operator pause: persist mouth-pause and stop llama-server. Watch never kills.
# Resume: scripts\Start-LlamaServer.ps1 -Resume  (or Galaxy /mouth on)
[CmdletBinding()]
param([string]$RepoRoot = "")
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Resolve-GodBrainRoot.ps1")
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path $PSScriptRoot -Parent
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$logDir = Join-Path $RepoRoot "logs"
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}
$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText((Join-Path $logDir "mouth-pause.txt"), "on`n", $utf8)
Get-Process -Name "llama-server" -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host ("Stop-LlamaServer: stopping pid={0}" -f $_.Id)
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
}
$deadline = (Get-Date).AddSeconds(15)
while (Get-NetTCPConnection -LocalPort 8000 -State Listen -ErrorAction SilentlyContinue) {
    if ((Get-Date) -gt $deadline) { throw ":8000 still listening after stop" }
    Start-Sleep -Milliseconds 400
}
Write-Host "Stop-LlamaServer: paused. Watch/Heal/kernel will not restart llama. /mouth on or Start-LlamaServer.ps1 -Resume"
