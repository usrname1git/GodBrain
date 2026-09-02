# Reclaim11 WinPE entry. Runs on X: after wpeinit. Not a host wipe.
[CmdletBinding()]
param(
    [string]$CatalogPath = "",
    [string]$StubPath = "",
    [string]$WindowsRoot = "",
    $SecureBoot = $null
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "offline.ps1")

if ([string]::IsNullOrWhiteSpace($CatalogPath)) {
    $CatalogPath = Join-Path $here "catalog.json"
    if (-not (Test-Path -LiteralPath $CatalogPath)) {
        $CatalogPath = Join-Path (Split-Path -Parent $here) "catalog.json"
    }
}
if ([string]::IsNullOrWhiteSpace($StubPath)) {
    $StubPath = Join-Path $here "DefenderStub.exe"
    if (-not (Test-Path -LiteralPath $StubPath)) {
        $catProbe = Get-Content -LiteralPath $CatalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($catProbe.PSObject.Properties["stub_exe"]) { $StubPath = [string]$catProbe.stub_exe }
    }
}

$receipt = Invoke-Reclaim11OfflineApply -CatalogPath $CatalogPath -StubPath $StubPath -WindowsRoot $WindowsRoot -SecureBoot $SecureBoot
$receipt | ConvertTo-Json -Depth 8
Write-Host ("receipt {0}" -f $receipt.receipt_path)
Write-Host ("stubbed {0} skipped_elam {1} missing {2}" -f @($receipt.stubbed).Count, @($receipt.skipped_elam).Count, @($receipt.missing).Count)
Write-Host $receipt.reason_wdboot

if (Test-Reclaim11WinPeSession) {
    Write-Host "When finished: wpeutil reboot"
    cmd.exe /c pause
}
