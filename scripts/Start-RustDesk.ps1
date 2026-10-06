[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
$receiptPath = Join-Path $repo "logs\last-rustdesk-start.json"
. (Join-Path $PSScriptRoot "GodBrain-HostServices.ps1")

function Assert-RustDeskGameStopped {
    if (Get-Process -Name CS2 -ErrorAction SilentlyContinue) {
        throw "CS2 is running; RustDesk launch is blocked."
    }
}

function Write-RustDeskLaunchReceipt {
    param([hashtable]$Receipt)
    $null = New-Item -ItemType Directory -Path (Split-Path $receiptPath -Parent) -Force
    $tmp = $receiptPath + "." + [guid]::NewGuid().ToString("N") + ".tmp"
    try {
        [IO.File]::WriteAllText($tmp, ($Receipt | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination $receiptPath -Force
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    }
}

function Invoke-RustDeskShortcutLaunch {
    $receipt = @{
        at = [DateTimeOffset]::UtcNow.ToString("o")
        status = "running"
        backend_ready = $false
        message = ""
    }
    try {
        Assert-RustDeskGameStopped
        Write-RustDeskLaunchReceipt $receipt
        Start-GodBrainRustDeskBackend -RegisterIfMissing
        Assert-RustDeskGameStopped
        if (-not (Test-GodBrainRustDeskBackend) -or (Invoke-GodBrainRustDeskStopOption) -eq "Y") {
            throw "RustDesk remote-desktop backend is not ready."
        }
        Set-Content -LiteralPath (Join-Path $repo "logs\rustdesk-pause.txt") -Value "off"
        $receipt.status = "ok"
        $receipt.backend_ready = $true
        $receipt.message = "RustDesk remote-desktop service ready."
        $receipt.at = [DateTimeOffset]::UtcNow.ToString("o")
        Write-RustDeskLaunchReceipt $receipt
        return $receipt.message
    } catch {
        $receipt.status = "failed"
        $receipt.message = $_.Exception.Message
        $receipt.at = [DateTimeOffset]::UtcNow.ToString("o")
        Write-RustDeskLaunchReceipt $receipt
        throw
    }
}

Invoke-RustDeskShortcutLaunch
