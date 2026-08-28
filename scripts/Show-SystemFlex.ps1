# Host chrome: Old Glory system glance. Not a kernel door. Heal does not call this.
# Usage: .\scripts\Show-SystemFlex.ps1
# Optional profile: Set-Alias flex (Join-Path $GodBrainRoot 'scripts\Show-SystemFlex.ps1')

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$os = Get-CimInstance Win32_OperatingSystem
$computer = Get-CimInstance Win32_ComputerSystem
$memoryModules = @(Get-CimInstance Win32_PhysicalMemory)
$processor = Get-CimInstance Win32_Processor | Select-Object -First 1
$board = Get-CimInstance Win32_BaseBoard | Select-Object -First 1
$video = Get-CimInstance Win32_VideoController |
    Where-Object CurrentHorizontalResolution |
    Select-Object -First 1

$displayModeApiAvailable = $true
if (-not ('SystemFlexDisplayMode' -as [type])) {
    try {
        Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;

public static class SystemFlexDisplayMode
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string dmDeviceName;
        public ushort dmSpecVersion;
        public ushort dmDriverVersion;
        public ushort dmSize;
        public ushort dmDriverExtra;
        public uint dmFields;
        public int dmPositionX;
        public int dmPositionY;
        public uint dmDisplayOrientation;
        public uint dmDisplayFixedOutput;
        public short dmColor;
        public short dmDuplex;
        public short dmYResolution;
        public short dmTTOption;
        public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string dmFormName;
        public ushort dmLogPixels;
        public uint dmBitsPerPel;
        public uint dmPelsWidth;
        public uint dmPelsHeight;
        public uint dmDisplayFlags;
        public uint dmDisplayFrequency;
        public uint dmICMMethod;
        public uint dmICMIntent;
        public uint dmMediaType;
        public uint dmDitherType;
        public uint dmReserved1;
        public uint dmReserved2;
        public uint dmPanningWidth;
        public uint dmPanningHeight;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumDisplaySettings(
        string deviceName,
        int modeNumber,
        ref DEVMODE mode
    );
}
'@
    } catch {
        $displayModeApiAvailable = $false
    }
}

$useAnsi = $null -ne $PSStyle
if ($useAnsi) {
    $red = $PSStyle.Foreground.FromRgb(200, 16, 46)
    $white = $PSStyle.Foreground.FromRgb(242, 244, 247)
    $blue = $PSStyle.Foreground.FromRgb(87, 148, 208)
    $reset = $PSStyle.Reset
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$trustedInstallerSid = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
$isTrustedInstaller = @($identity.Groups | ForEach-Object { $_.Value }) -contains $trustedInstallerSid
$principal = [Security.Principal.WindowsPrincipal]$identity
$isAdministrator = $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
$securityContext = if ($isTrustedInstaller) {
    'TrustedInstaller'
} elseif ($isAdministrator) {
    'Administrator'
} else {
    'Standard user'
}

$gpuName = $video.Name
$gpuDetail = $null
$gpuDriver = $video.DriverVersion
$nvidiaSmi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
if ($nvidiaSmi) {
    $gpuCsv = & $nvidiaSmi.Source `
        '--query-gpu=name,memory.total,driver_version,temperature.gpu' `
        '--format=csv,noheader,nounits' 2>$null |
        Select-Object -First 1

    if ($gpuCsv) {
        $gpuFields = @($gpuCsv -split ',' | ForEach-Object { $_.Trim() })
        if ($gpuFields.Count -ge 4) {
            $gpuName = $gpuFields[0]
            $gpuMemory = [math]::Round(([double]$gpuFields[1] / 1024), 1)
            $gpuDriver = $gpuFields[2]
            $gpuDetail = "$gpuMemory GiB VRAM | $($gpuFields[3]) C"
        }
    }
}

$memoryGiB = [math]::Round(($computer.TotalPhysicalMemory / 1GB), 1)
$memoryKitSpeed = @($memoryModules.PartNumber |
    ForEach-Object {
        if ($_ -match '(?<!\d)(\d{4,5})\s+Series') {
            $Matches[1]
        }
    } |
    Sort-Object -Unique) -join '/'
$memoryDetail = "$memoryGiB GiB"
if ($memoryKitSpeed) {
    $memoryDetail += " | Patriot Viper Xtreme DDR5-$memoryKitSpeed"
}
$uptime = (Get-Date) - $os.LastBootUpTime
$uptimeText = '{0}d {1}h {2}m' -f (
    [math]::Floor($uptime.TotalDays),
    $uptime.Hours,
    $uptime.Minutes
)
$display = $null
Add-Type -AssemblyName System.Windows.Forms
$screens = @([System.Windows.Forms.Screen]::AllScreens)
$primaryScreen = $screens | Where-Object Primary | Select-Object -First 1
if ($primaryScreen) {
    if ($displayModeApiAvailable) {
        $displayMode = New-Object SystemFlexDisplayMode+DEVMODE
        $displayMode.dmSize = [Runtime.InteropServices.Marshal]::SizeOf($displayMode)
        if ([SystemFlexDisplayMode]::EnumDisplaySettings(
                $primaryScreen.DeviceName,
                -1,
                [ref]$displayMode
            )) {
            $display = 'Primary {0}x{1} @ {2} Hz | {3} active' -f
                $displayMode.dmPelsWidth,
                $displayMode.dmPelsHeight,
                $displayMode.dmDisplayFrequency,
                $screens.Count
        }
    }
    if (-not $display) {
        $display = 'Primary {0}x{1} | {2} active' -f
            $primaryScreen.Bounds.Width,
            $primaryScreen.Bounds.Height,
            $screens.Count
    }
}

$writeRow = {
    param([string]$Label, [string]$Value)
    if ($useAnsi) {
        Write-Host "  $blue$($Label.PadRight(11))$reset $white$Value$reset"
    } else {
        Write-Host ('  {0} ' -f $Label.PadRight(11)) -ForegroundColor Blue -NoNewline
        Write-Host $Value -ForegroundColor White
    }
}

$writeRule = {
    if ($useAnsi) {
        Write-Host "  $red================$white================$blue================$reset"
    } else {
        Write-Host '  ================' -ForegroundColor Red -NoNewline
        Write-Host '================' -ForegroundColor White -NoNewline
        Write-Host '================' -ForegroundColor Blue
    }
}

Write-Host
& $writeRule
if ($useAnsi) {
    Write-Host "  $red OLD$white GLORY$blue // WINDOWS COMMAND CENTER$reset"
} else {
    Write-Host '   OLD' -ForegroundColor Red -NoNewline
    Write-Host ' GLORY' -ForegroundColor White -NoNewline
    Write-Host ' // WINDOWS COMMAND CENTER' -ForegroundColor Blue
}
& $writeRule
& $writeRow 'OS' $os.Caption
& $writeRow 'Build' "$($os.Version) | $($os.BuildNumber)"
& $writeRow 'Installed' $os.InstallDate.ToString('yyyy-MM-dd')
& $writeRow 'Host' $env:COMPUTERNAME
& $writeRow 'Privilege' $securityContext
& $writeRow 'Board' "$($board.Manufacturer) $($board.Product)"
& $writeRow 'CPU' "$($processor.Name) | $($processor.NumberOfCores)C / $($processor.NumberOfLogicalProcessors)T"
& $writeRow 'Memory' $memoryDetail
& $writeRow 'GPU' $gpuName
if ($gpuDetail) {
    & $writeRow 'Graphics' $gpuDetail
}
& $writeRow 'Driver' $gpuDriver
if ($display) {
    & $writeRow 'Display' $display
}
& $writeRow 'PowerShell' "$($PSVersionTable.PSVersion)"
& $writeRow 'Uptime' $uptimeText
& $writeRule
Write-Host
