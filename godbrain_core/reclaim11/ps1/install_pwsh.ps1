# Offer official PowerShell 7 MSI when the GUI started on 5.1.
# GitHub MSI + msiexec ADD_PATH. Never irm|iex, never the Store stub.

function Get-Reclaim11PwshMsiAsset {
    $arch = [string]$env:PROCESSOR_ARCHITECTURE
    $tag = "win-x64.msi"
    if ($arch -eq "ARM64") { $tag = "win-arm64.msi" }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch { }
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add("User-Agent", "Reclaim11")
    $wc.Headers.Add("Accept", "application/vnd.github+json")
    $raw = $wc.DownloadString("https://api.github.com/repos/PowerShell/PowerShell/releases/latest")
    $rel = $raw | ConvertFrom-Json
    $rx = '^PowerShell-\d+\.\d+\.\d+-' + [regex]::Escape(($tag -replace '\.msi$', '')) + '\.msi$'
    foreach ($a in @($rel.assets)) {
        $n = [string]$a.name
        if ($n -match $rx) {
            return [pscustomobject]@{
                name = $n
                url  = [string]$a.browser_download_url
            }
        }
    }
    throw ("Install-Reclaim11PwshMsi: no stable {0} on latest GitHub release" -f $tag)
}

function Install-Reclaim11PwshMsi {
    if (Test-Path -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT") {
        throw "Install-Reclaim11PwshMsi: WinPE stays 5.1. Not the GUI host."
    }
    $have = Get-Reclaim11Pwsh7
    if ($have) { return $have }
    $asset = Get-Reclaim11PwshMsiAsset
    $dir = Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "Reclaim11\pwsh-msi"
    if (-not $dir) { $dir = Join-Path $env:TEMP "Reclaim11\pwsh-msi" }
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $msiPath = Join-Path $dir $asset.name
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add("User-Agent", "Reclaim11")
    $wc.DownloadFile([string]$asset.url, $msiPath)
    if (-not (Test-Path -LiteralPath $msiPath)) {
        throw "Install-Reclaim11PwshMsi: download missing $msiPath"
    }
    $msi = Join-Path $env:SystemRoot "System32\msiexec.exe"
    $arg = @(
        "/i", $msiPath, "/qn",
        "ADD_PATH=1", "REGISTER_MANIFEST=1", "ENABLE_MU=1", "USE_MU=1"
    )
    $p = Start-Process -FilePath $msi -ArgumentList $arg -Wait -PassThru
    $code = [int]$p.ExitCode
    if ($code -ne 0 -and $code -ne 3010) {
        throw ("Install-Reclaim11PwshMsi: msiexec exit {0}" -f $code)
    }
    $have = Get-Reclaim11Pwsh7
    if (-not $have) {
        throw "Install-Reclaim11PwshMsi: MSI ran but pwsh.exe not under Program Files\PowerShell"
    }
    $have
}

function Show-Reclaim11PwshOffer {
    if (Test-Path -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT") { return $null }
    if ($PSVersionTable.PSVersion.Major -ge 7) { return $null }
    $have = Get-Reclaim11Pwsh7
    if ($have) { return $have }
    Add-Type -AssemblyName PresentationFramework
    $q = [System.Windows.MessageBox]::Show(
        "You are on Windows PowerShell 5.1. Reclaim11 wants PowerShell 7.`n`nInstall the latest official PowerShell MSI now? Adds PATH. One click after Yes.",
        "Reclaim11 needs PowerShell 7",
        "YesNo",
        "Warning")
    if ($q -ne "Yes") { return $null }
    try {
        return (Install-Reclaim11PwshMsi)
    } catch {
        [System.Windows.MessageBox]::Show(
            ("PowerShell 7 MSI failed:`n{0}`n`nInstall from https://aka.ms/powershell then double-click Reclaim11.cmd again." -f $_.Exception.Message),
            "Reclaim11 PowerShell 7") | Out-Null
        $null
    }
}
