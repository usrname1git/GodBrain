# Reclaim11 Brave policy. Stock Brave + HKLM GPO. Not a forked browser.
[CmdletBinding()]
param(
    [switch]$LockdownOnly,
    [switch]$AllowDangerousDownloads,
    [switch]$Headless
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Test-Reclaim11Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal $id
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Reclaim11RegDwords([string]$Name) {
    $path = Join-Path $here $Name
    if (-not (Test-Path -LiteralPath $path)) { throw "missing $path" }
    $hive = $null
    $map = @{}
    foreach ($line in Get-Content -LiteralPath $path -Encoding UTF8) {
        if ($line -match '^\[HKEY_(LOCAL_MACHINE|CURRENT_USER)\\SOFTWARE\\Policies\\BraveSoftware\\Brave\]') {
            $hive = $Matches[1]
            if (-not $map.ContainsKey($hive)) { $map[$hive] = @{} }
            continue
        }
        if ($hive -and $line -match '^"([^"]+)"=dword:([0-9a-fA-F]+)') {
            $map[$hive][$Matches[1]] = [Convert]::ToInt32($Matches[2], 16)
        }
    }
    $map
}

function Set-Reclaim11BraveKey([string]$Root, $Dwords) {
    if (-not (Test-Path -LiteralPath $Root)) {
        New-Item -Path $Root -Force | Out-Null
    }
    foreach ($k in $Dwords.Keys) {
        New-ItemProperty -LiteralPath $Root -Name $k -Value $Dwords[$k] -PropertyType DWord -Force | Out-Null
    }
}

function Import-Reclaim11Reg([string]$Name) {
    $parsed = Get-Reclaim11RegDwords $Name
    $admin = Test-Reclaim11Admin
    if ($parsed.ContainsKey("CURRENT_USER")) {
        Set-Reclaim11BraveKey "HKCU:\SOFTWARE\Policies\BraveSoftware\Brave" $parsed["CURRENT_USER"]
        Write-Host "$Name HKCU ($($parsed['CURRENT_USER'].Count) values)"
    }
    if ($parsed.ContainsKey("LOCAL_MACHINE")) {
        if ($admin) {
            Set-Reclaim11BraveKey "HKLM:\SOFTWARE\Policies\BraveSoftware\Brave" $parsed["LOCAL_MACHINE"]
            Write-Host "$Name HKLM ($($parsed['LOCAL_MACHINE'].Count) values)"
        } else {
            Write-Host "$Name HKLM skipped (not admin). Home: HKCU is enough for this user. Machine-wide needs elevation."
        }
    }
}

function Set-Reclaim11DownloadLabs {
    param(
        [string]$PrefsPath = "",
        [switch]$NoKill
    )
    if (-not $PrefsPath) {
        $PrefsPath = Join-Path $env:LOCALAPPDATA "BraveSoftware\Brave-Browser\User Data\Local State"
    }
    if (-not (Test-Path -LiteralPath $PrefsPath)) {
        Write-Host "Brave Local State not found. GPO applied. Run Brave once, then re-run -AllowDangerousDownloads for the labs flag."
        return
    }
    $json = Get-Content -LiteralPath $PrefsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $json.PSObject.Properties['browser']) {
        $json | Add-Member -NotePropertyName browser -NotePropertyValue ([pscustomobject]@{})
    }
    $want = "brave-override-download-danger-level@1"
    $cur = @()
    if ($json.browser.PSObject.Properties['enabled_labs_experiments'] -and
        $null -ne $json.browser.enabled_labs_experiments) {
        $cur = @($json.browser.enabled_labs_experiments)
    }
    if ($cur -notcontains $want) { $cur += $want }
    $json.browser | Add-Member -NotePropertyName enabled_labs_experiments -NotePropertyValue $cur -Force
    $bak = $PrefsPath + ".reclaim11.bak"
    $tmp = $PrefsPath + ".reclaim11.tmp"
    Copy-Item -LiteralPath $PrefsPath -Destination $bak -Force
    $json | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $tmp -Encoding UTF8
    if (-not $NoKill) {
        $sid = [Diagnostics.Process]::GetCurrentProcess().SessionId
        Get-Process -Name brave -ErrorAction SilentlyContinue |
            Where-Object { $_.SessionId -eq $sid } |
            Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }
    Move-Item -LiteralPath $tmp -Destination $PrefsPath -Force
    Write-Host "labs: $want bak=$bak"
}

function Invoke-Reclaim11BraveApply([bool]$Danger) {
    Import-Reclaim11Reg "lockdown.reg"
    if ($Danger) {
        Import-Reclaim11Reg "allow-dangerous-downloads.reg"
        Set-Reclaim11DownloadLabs
        Write-Host "WARNING: download danger blocking is off (power user)."
    }
    Write-Host "done. Restart Brave. Home: no gpedit; registry is the policy."
}

if ($MyInvocation.InvocationName -eq '.') { return }

if ($Headless -or $LockdownOnly -or $AllowDangerousDownloads) {
    Invoke-Reclaim11BraveApply -Danger:([bool]$AllowDangerousDownloads)
    return
}

$sta = [Threading.Thread]::CurrentThread.GetApartmentState()
if ($sta -ne "STA") {
    $pwsh = Join-Path $PSHOME "pwsh.exe"
    if (-not (Test-Path -LiteralPath $pwsh)) { $pwsh = (Get-Command pwsh).Source }
    Start-Process -FilePath $pwsh -ArgumentList @("-STA", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $MyInvocation.MyCommand.Path)
    return
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="Reclaim11 Brave policy"
        Width="560" Height="340"
        Background="#12141A" Foreground="#E6E8EE"
        FontFamily="Segoe UI" FontSize="13"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize">
  <DockPanel Margin="16">
    <TextBlock DockPanel.Dock="Top" FontSize="20" FontWeight="SemiBold" Margin="0,0,0,8"
               Text="Brave policy"/>
    <TextBlock DockPanel.Dock="Top" Foreground="#9AA3B2" TextWrapping="Wrap" Margin="0,0,0,12"
               Text="Stock Brave from brave.com. Machine GPO only. Rewards/Wallet/VPN/Talk/News/Leo/Tor/metrics off. Not a modded browser."/>
    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,12,0,0">
      <Button x:Name="BtnApply" Content="Apply" Width="120" Height="32" Margin="0,0,8,0"/>
      <TextBlock x:Name="Status" VerticalAlignment="Center" Foreground="#7A8494" Text="HKCU always. HKLM if elevated. Home: no gpedit."/>
    </StackPanel>
    <StackPanel>
      <CheckBox IsChecked="True" IsEnabled="False" Foreground="#E6E8EE" Margin="0,0,0,12"
                Content="Lockdown (Rewards, Wallet, VPN, Talk, News, Leo, Tor, P3A)"/>
      <CheckBox x:Name="ChkDanger" Foreground="#E6E8EE" Margin="0,0,0,6">
        <TextBlock TextWrapping="Wrap">
          <Run Text="Disable download danger blocking"/>
        </TextBlock>
      </CheckBox>
      <TextBlock Foreground="#E0A106" TextWrapping="Wrap" Margin="24,0,0,0"
                 Text="WARNING DO NOT DISABLE IF YOU'RE NOT A POWER USER. Chromium will not nag on dangerous file types. Safe Browsing stays on."/>
    </StackPanel>
  </DockPanel>
</Window>
"@
$window = [Windows.Markup.XamlReader]::Parse($xaml)
$btn = $window.FindName("BtnApply")
$chk = $window.FindName("ChkDanger")
$st  = $window.FindName("Status")
$btn.Add_Click({
    try {
        Invoke-Reclaim11BraveApply -Danger:([bool]$chk.IsChecked)
        $st.Text = "applied"
        [System.Windows.MessageBox]::Show("Policy applied. Restart Brave.", "Reclaim11") | Out-Null
        $window.Close()
    } catch {
        $st.Text = $_.Exception.Message
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Reclaim11") | Out-Null
    }
})
[void]$window.ShowDialog()
