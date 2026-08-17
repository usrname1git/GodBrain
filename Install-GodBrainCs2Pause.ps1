# Register the Steam-Play backup gate. Prefer Start-CS2.ps1 / Start-CS2.cmd.
# This 1-minute task only matters if CS2 is launched from Steam itself.

[CmdletBinding()]
param(
    [switch]$Unregister
)

$ErrorActionPreference = "Stop"
$taskName = "GodBrainCs2Pause"
$repo = $PSScriptRoot
$watch = Join-Path $repo "Watch-Cs2Pause.ps1"

if ($Unregister) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Removed scheduled task $taskName"
    return
}

if (-not (Test-Path -LiteralPath $watch)) {
    throw "Missing $watch"
}

$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue)
$shell = if ($pwsh) { $pwsh.Source } else { "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }

$tr = "`"$shell`" -NoProfile -WindowStyle Hidden -File `"$watch`" -RepoRoot `"$repo`""
& schtasks.exe /Create /TN $taskName /SC MINUTE /MO 1 /IT /F /RL LIMITED `
    /TR $tr | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "schtasks /Create failed with exit $LASTEXITCODE"
}

Write-Host "Registered $taskName for $env:USERNAME every 1 minute."
Write-Host "Pauses coli + Watch/Logon while CS2.exe is running."
Write-Host "Resumes 5 minutes after CS2.exe exits."
Write-Host "Remove with: .\Install-GodBrainCs2Pause.ps1 -Unregister"
