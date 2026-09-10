# Official RustDesk remote-support door. In-Windows only. Not Heal. Not WinPE.
# Pin + SHA256 from catalog.json. Public servers. Never irm, never iex. Never a custom rendezvous.
# Password is never logged, never written to restore.json, never in --get-id output.

[CmdletBinding()]
param(
    [ValidateSet("type", "generate", "one-time")]
    [string]$PasswordMode = "one-time",
    [switch]$InstallService,
    [Alias("T", "Test")]
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:Reclaim11Here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$invBoot = Join-Path $script:Reclaim11Here "inventory.ps1"
if (Test-Path -LiteralPath $invBoot) { . $invBoot }

function Test-Reclaim11RustDeskPeHost {
    Test-Path -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT"
}

function Assert-Reclaim11RustDeskInWindows {
    if (Test-Reclaim11RustDeskPeHost) {
        throw "Install-Reclaim11RustDesk: WinPE MiniNT refused. In-Windows only."
    }
}

function Get-Reclaim11RustDeskPlan {
    param([string]$Root = "")
    if ([string]::IsNullOrWhiteSpace($Root)) {
        $Root = Get-Reclaim11Root
    }
    $cat = Get-Reclaim11Catalog -Root $Root
    if (-not $cat.PSObject.Properties["rustdesk"]) {
        throw "Get-Reclaim11RustDeskPlan: catalog.json missing rustdesk pin"
    }
    $rd = $cat.rustdesk
    $repo = [string]$rd.github_repo
    $tag = [string]$rd.tag
    $asset = [string]$rd.asset
    $sha = ([string]$rd.sha256).ToLowerInvariant()
    $servers = [string]$rd.servers
    if ($repo -ne "rustdesk/rustdesk") {
        throw "Get-Reclaim11RustDeskPlan: github_repo must be rustdesk/rustdesk (official)"
    }
    if ([string]::IsNullOrWhiteSpace($tag) -or $tag -eq "latest") {
        throw "Get-Reclaim11RustDeskPlan: tag must be a named release, not latest"
    }
    if ($asset -notmatch '^rustdesk-.+-x86_64\.exe$') {
        throw "Get-Reclaim11RustDeskPlan: asset must be rustdesk-*-x86_64.exe"
    }
    if ($sha -notmatch '^[0-9a-f]{64}$') {
        throw "Get-Reclaim11RustDeskPlan: sha256 must be 64 hex chars"
    }
    if ($servers -ne "public-official") {
        throw "Get-Reclaim11RustDeskPlan: servers must be public-official"
    }
    $url = "https://github.com/{0}/releases/download/{1}/{2}" -f $repo, $tag, $asset
    [pscustomobject]@{
        github_repo = $repo
        tag         = $tag
        asset       = $asset
        sha256      = $sha
        size        = $(if ($rd.PSObject.Properties["size"]) { [int64]$rd.size } else { 0 })
        servers     = $servers
        url         = $url
    }
}

function Get-Reclaim11RustDeskCacheDir {
    $root = [Environment]::GetFolderPath("LocalApplicationData")
    if ([string]::IsNullOrWhiteSpace($root)) { $root = $env:TEMP }
    $dir = Join-Path $root "Reclaim11\rustdesk"
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $dir
}

function Get-Reclaim11RustDeskExe {
    $cands = @(
        (Join-Path ${env:ProgramFiles} "RustDesk\rustdesk.exe")
    )
    $x86 = ${env:ProgramFiles(x86)}
    if (-not [string]::IsNullOrWhiteSpace($x86)) {
        $cands += (Join-Path $x86 "RustDesk\rustdesk.exe")
    }
    foreach ($c in $cands) {
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        if (Test-Path -LiteralPath $c) { return (Get-Item -LiteralPath $c).FullName }
    }
    $null
}

function ConvertFrom-Reclaim11SecurePassword {
    param([Parameter(Mandatory)][securestring]$Password)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    try {
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function New-Reclaim11RustDeskPassword {
    $alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#%*+-="
    $bytes = New-Object byte[] 18
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    } finally {
        $rng.Dispose()
    }
    $chars = New-Object char[] $bytes.Length
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $chars[$i] = $alphabet[$bytes[$i] % $alphabet.Length]
    }
    -join $chars
}

function Invoke-Reclaim11RustDeskCli {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [switch]$SecretArgs
    )
    if (-not (Test-Path -LiteralPath $Exe)) {
        throw "Install-Reclaim11RustDesk: missing $Exe"
    }
    $out = & $Exe @ArgumentList 2>&1 | Out-String
    $code = [int]$LASTEXITCODE
    if ($code -ne 0) {
        if ($SecretArgs) {
            throw ("rustdesk.exe exit {0} (args not logged)" -f $code)
        }
        throw ("rustdesk.exe {0} exit {1}`n{2}" -f ($ArgumentList -join " "), $code, $out)
    }
    if ($SecretArgs) { return "" }
    ([string]$out).Trim()
}

function New-Reclaim11RustDeskResult {
    param(
        $Pin,
        [string]$PasswordMode,
        [bool]$InstallService,
        [bool]$WhatIf,
        [string]$Id = "",
        [string]$WouldRefuse = ""
    )
    $would = @(
        ("download {0}" -f $Pin.url),
        ("verify sha256 {0}" -f $Pin.sha256),
        "--silent-install"
    )
    if ($InstallService) { $would += "--install-service" }
    if ($PasswordMode -eq "one-time") {
        $would += "no --password (one-time only)"
    } else {
        $would += "--password (not logged)"
    }
    $would += "--get-id"
    $would += "servers=public-official (no custom rendezvous)"
    [pscustomobject]@{
        what_if          = [bool]$WhatIf
        mutate           = -not [bool]$WhatIf
        password_mode    = $PasswordMode
        install_service  = [bool]$InstallService
        servers          = [string]$Pin.servers
        tag              = [string]$Pin.tag
        asset            = [string]$Pin.asset
        sha256           = [string]$Pin.sha256
        url              = [string]$Pin.url
        github_repo      = [string]$Pin.github_repo
        id               = $Id
        checks           = @(
            [pscustomobject]@{ name = "pin"; ok = $true; detail = ("{0} {1}" -f $Pin.tag, $Pin.asset) }
            [pscustomobject]@{ name = "servers"; ok = ($Pin.servers -eq "public-official"); detail = $Pin.servers }
            [pscustomobject]@{ name = "sha256"; ok = ($Pin.sha256 -match '^[0-9a-f]{64}$'); detail = $Pin.sha256 }
            [pscustomobject]@{ name = "no_custom_config"; ok = $true; detail = "no custom rendezvous" }
        )
        would            = $would
        would_refuse     = $WouldRefuse
    }
}

function Install-Reclaim11RustDesk {
    param(
        [string]$Root = "",
        [ValidateSet("type", "generate", "one-time")]
        [string]$PasswordMode = "one-time",
        [securestring]$Password,
        [switch]$InstallService,
        [switch]$WhatIf
    )
    Assert-Reclaim11RustDeskInWindows
    if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Get-Reclaim11Root }
    $pin = Get-Reclaim11RustDeskPlan -Root $Root
    if ($env:PROCESSOR_ARCHITECTURE -ne "AMD64") {
        throw ("Install-Reclaim11RustDesk: pin is {0} (AMD64). This host is {1}." -f $pin.asset, $env:PROCESSOR_ARCHITECTURE)
    }
    if ($WhatIf) {
        return (New-Reclaim11RustDeskResult -Pin $pin -PasswordMode $PasswordMode -InstallService ([bool]$InstallService) -WhatIf $true)
    }
    if ($PasswordMode -ne "one-time") {
        if (-not $Password) {
            throw "Install-Reclaim11RustDesk: Password required for mode $PasswordMode"
        }
    }
    if (-not (Test-Reclaim11Admin)) {
        throw "Install-Reclaim11RustDesk: administrator required"
    }

    $cache = Get-Reclaim11RustDeskCacheDir
    $exePath = Join-Path $cache $pin.asset
    $needDl = $true
    if (Test-Path -LiteralPath $exePath) {
        $have = (Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($have -eq $pin.sha256) { $needDl = $false }
        else { Remove-Item -LiteralPath $exePath -Force }
    }
    if ($needDl) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        } catch { }
        $wc = New-Object System.Net.WebClient
        try {
            $wc.Headers.Add("User-Agent", "Reclaim11")
            $wc.DownloadFile([string]$pin.url, $exePath)
        } finally {
            $wc.Dispose()
        }
        if (-not (Test-Path -LiteralPath $exePath)) {
            throw "Install-Reclaim11RustDesk: download missing $exePath"
        }
        $got = (Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($got -ne $pin.sha256) {
            Remove-Item -LiteralPath $exePath -Force -ErrorAction SilentlyContinue
            throw ("Install-Reclaim11RustDesk: sha256 mismatch (got {0} want {1})" -f $got, $pin.sha256)
        }
        if ($pin.size -gt 0) {
            $len = [int64](Get-Item -LiteralPath $exePath).Length
            if ($len -ne $pin.size) {
                Remove-Item -LiteralPath $exePath -Force -ErrorAction SilentlyContinue
                throw ("Install-Reclaim11RustDesk: size mismatch (got {0} want {1})" -f $len, $pin.size)
            }
        }
    }

    $p = Start-Process -FilePath $exePath -ArgumentList @("--silent-install") -Wait -PassThru -WindowStyle Hidden
    $code = [int]$p.ExitCode
    if ($code -ne 0) {
        throw ("Install-Reclaim11RustDesk: --silent-install exit {0}" -f $code)
    }
    $deadline = [datetime]::UtcNow.AddSeconds(90)
    $installed = $null
    do {
        $installed = Get-Reclaim11RustDeskExe
        if ($installed) { break }
        Start-Sleep -Milliseconds 400
    } while ([datetime]::UtcNow -lt $deadline)
    if (-not $installed) {
        throw "Install-Reclaim11RustDesk: rustdesk.exe missing after --silent-install"
    }

    if ($InstallService) {
        Invoke-Reclaim11RustDeskCli -Exe $installed -ArgumentList @("--install-service") | Out-Null
    }

    if ($PasswordMode -ne "one-time") {
        $plain = ConvertFrom-Reclaim11SecurePassword -Password $Password
        try {
            Invoke-Reclaim11RustDeskCli -Exe $installed -ArgumentList @("--password", $plain) -SecretArgs | Out-Null
        } finally {
            $plain = $null
        }
    }

    $id = Invoke-Reclaim11RustDeskCli -Exe $installed -ArgumentList @("--get-id")
    if ([string]::IsNullOrWhiteSpace($id)) {
        throw "Install-Reclaim11RustDesk: --get-id returned empty"
    }
    New-Reclaim11RustDeskResult -Pin $pin -PasswordMode $PasswordMode -InstallService ([bool]$InstallService) -WhatIf $false -Id $id
}

function Show-Reclaim11RustDeskChooser {
    param($Owner = $null)
    Add-Type -AssemblyName PresentationFramework | Out-Null
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Reclaim11 RustDesk"
        Width="520" Height="430"
        MinWidth="480" MinHeight="400"
        Background="#0B0F16" Foreground="#E8F4FF"
        FontFamily="Segoe UI" FontSize="13"
        WindowStartupLocation="CenterOwner"
        ResizeMode="NoResize">
  <DockPanel Margin="16">
    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
      <Button x:Name="BtnCancel" Content="CANCEL" MinWidth="100" Margin="0,0,8,0" IsCancel="True"/>
      <Button x:Name="BtnOk" Content="INSTALL" MinWidth="120" IsDefault="True"/>
    </StackPanel>
    <StackPanel>
      <TextBlock Text="Official public RustDesk servers. Password is never logged." TextWrapping="Wrap" Foreground="#7A93A8" Margin="0,0,0,12"/>
      <RadioButton x:Name="RadType" Content="Permanent password: I type it" IsChecked="True" Margin="0,0,0,8" Foreground="#E8F4FF"/>
      <RadioButton x:Name="RadGen" Content="Generate a password and show it once" Margin="0,0,0,8" Foreground="#E8F4FF"/>
      <RadioButton x:Name="RadOnce" Content="No permanent password (one-time only)" Margin="0,0,0,12" Foreground="#E8F4FF"/>
      <TextBlock x:Name="PwdLabel" Text="Password / confirm" Foreground="#7A93A8" Margin="0,0,0,4"/>
      <PasswordBox x:Name="Pwd1" Margin="0,0,0,8" Height="28"/>
      <PasswordBox x:Name="Pwd2" Margin="0,0,0,12" Height="28"/>
      <CheckBox x:Name="ChkService" Content="Install unattended service (reconnect after reboot)" IsChecked="True" Foreground="#E8F4FF"/>
    </StackPanel>
  </DockPanel>
</Window>
"@
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $dlg = [Windows.Markup.XamlReader]::Load($reader)
    if ($Owner) { $dlg.Owner = $Owner }
    $radType = $dlg.FindName("RadType")
    $radGen = $dlg.FindName("RadGen")
    $radOnce = $dlg.FindName("RadOnce")
    $pwd1 = $dlg.FindName("Pwd1")
    $pwd2 = $dlg.FindName("Pwd2")
    $pwdLabel = $dlg.FindName("PwdLabel")
    $chkService = $dlg.FindName("ChkService")
    $btnOk = $dlg.FindName("BtnOk")
    $btnCancel = $dlg.FindName("BtnCancel")
    $script:RustDeskChoice = $null

    $syncPwd = {
        $on = [bool]$radType.IsChecked
        $pwd1.IsEnabled = $on
        $pwd2.IsEnabled = $on
        $pwdLabel.Opacity = $(if ($on) { 1 } else { 0.45 })
    }
    $radType.Add_Checked($syncPwd)
    $radGen.Add_Checked($syncPwd)
    $radOnce.Add_Checked($syncPwd)
    & $syncPwd

    $btnCancel.Add_Click({ $dlg.DialogResult = $false; $dlg.Close() })
    $btnOk.Add_Click({
        $mode = "type"
        if ([bool]$radGen.IsChecked) { $mode = "generate" }
        elseif ([bool]$radOnce.IsChecked) { $mode = "one-time" }
        $sec = $null
        if ($mode -eq "type") {
            $a = [string]$pwd1.Password
            $b = [string]$pwd2.Password
            if ($a.Length -lt 6) {
                [Windows.MessageBox]::Show("Type a password of at least 6 characters.", "Reclaim11 RustDesk") | Out-Null
                return
            }
            if ($a -cne $b) {
                [Windows.MessageBox]::Show("Password and confirm do not match.", "Reclaim11 RustDesk") | Out-Null
                return
            }
            $sec = $pwd1.SecurePassword
            $a = $null
            $b = $null
        } elseif ($mode -eq "generate") {
            $once = New-Reclaim11RustDeskPassword
            [Windows.MessageBox]::Show(
                ("Shown once. Write it down now.`n`n{0}" -f $once),
                "Reclaim11 RustDesk password") | Out-Null
            $sec = ConvertTo-SecureString $once -AsPlainText -Force
            $once = $null
        }
        $script:RustDeskChoice = [pscustomobject]@{
            password_mode   = $mode
            install_service = [bool]$chkService.IsChecked
            password        = $sec
        }
        $dlg.DialogResult = $true
        $dlg.Close()
    })
    $ok = $dlg.ShowDialog()
    if ($ok -ne $true) { return $null }
    $script:RustDeskChoice
}

if ($MyInvocation.InvocationName -ne ".") {
    $plan = Install-Reclaim11RustDesk -WhatIf:$WhatIf -PasswordMode $PasswordMode -InstallService:$InstallService
    if ($WhatIf) {
        Write-Host (Format-Reclaim11TestReport -Plan $plan -Title "rustdesk")
    }
    $plan | ConvertTo-Json -Depth 6
}
