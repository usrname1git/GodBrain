# Skip Windows Automatic Repair on an offline volume. Not pack A.
# Named bcdedit only. Not a servicing cocktail. Not GPU.
# Receipt does not unlock killing blows.
# PowerShell 5.1 (WinPE) and 7 (Test-Reclaim11).
[CmdletBinding()]
param(
    [string]$WindowsRoot = "",
    [string]$BcdStore = "",
    [Alias("T", "Test")]
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($here)) { $here = $PWD.Path }
. (Join-Path $here "offline.ps1")

function Test-Reclaim11PeMediaRoot {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) { return $true }
    $r = $Root.TrimEnd("\")
    if ($r -like "X:*") { return $true }
    if (Test-Path -LiteralPath (Join-Path $r "sources\boot.wim")) { return $true }
    $false
}

function Get-Reclaim11FreeDriveLetter {
    $used = @{}
    foreach ($d in @(Get-PSDrive -PSProvider FileSystem)) {
        $n = [string]$d.Name
        if ($n.Length -eq 1) { $used[$n.ToUpperInvariant()] = $true }
    }
    foreach ($c in @("S", "R", "Q", "P", "O", "N", "M", "L")) {
        if (-not $used.ContainsKey($c)) { return $c }
    }
    throw "Skip-Reclaim11WinRe: no free drive letter for ESP"
}

function Find-Reclaim11EspBcd {
    param(
        [string]$VolumeRoot,
        [switch]$AssignLetter
    )
    $found = New-Object System.Collections.Generic.List[string]
    $letter = $null
    if ($VolumeRoot -match "^([A-Za-z]):") { $letter = $Matches[1] }
    if ([string]::IsNullOrWhiteSpace($letter)) { return @() }
    $ntosOnLetter = Join-Path ($letter + ":\") "Windows\System32\ntoskrnl.exe"
    $ntosOnVol = Join-Path $VolumeRoot "Windows\System32\ntoskrnl.exe"
    if (-not ((Test-Path -LiteralPath $ntosOnLetter) -or (Test-Path -LiteralPath $ntosOnVol))) {
        return @()
    }
    try {
        $winPart = @(Get-Partition -DriveLetter $letter -ErrorAction Stop)
        if ($winPart.Count -lt 1) { return @() }
        $diskN = [int]$winPart[0].DiskNumber
        $esps = @(Get-Partition -DiskNumber $diskN -ErrorAction Stop | Where-Object {
            ([string]$_.GptType) -eq "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}"
        })
        foreach ($esp in $esps) {
            $el = [string]$esp.DriveLetter
            if ([string]::IsNullOrWhiteSpace($el)) {
                if (-not $AssignLetter) { continue }
                $el = Get-Reclaim11FreeDriveLetter
                Set-Partition -DiskNumber $diskN -PartitionNumber $esp.PartitionNumber -NewDriveLetter $el -ErrorAction Stop
            }
            $bcd = Join-Path ($el + ":\") "EFI\Microsoft\Boot\BCD"
            if (Test-Path -LiteralPath $bcd) {
                [void]$found.Add([IO.Path]::GetFullPath($bcd))
            }
        }
    } catch {
        return @()
    }
    @($found)
}

function Find-Reclaim11BcdStores {
    param(
        [string]$VolumeRoot = "",
        [switch]$AssignEspLetter
    )
    $out = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    $cands = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($VolumeRoot)) {
        if (-not (Test-Reclaim11PeMediaRoot -Root $VolumeRoot)) {
            [void]$cands.Add((Join-Path $VolumeRoot "Boot\BCD"))
            [void]$cands.Add((Join-Path $VolumeRoot "EFI\Microsoft\Boot\BCD"))
        }
        foreach ($s in @(Find-Reclaim11EspBcd -VolumeRoot $VolumeRoot -AssignLetter:$AssignEspLetter)) {
            [void]$cands.Add($s)
        }
    }
    foreach ($p in @($cands)) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $full = [IO.Path]::GetFullPath($p)
        if ($full -like "X:\*") { continue }
        $vol = [IO.Path]::GetPathRoot($full)
        if (Test-Reclaim11PeMediaRoot -Root $vol) { continue }
        $key = $full.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        [void]$out.Add($full)
    }
    @($out)
}

function Invoke-Reclaim11BcdEdit {
    param([Parameter(Mandatory)][string[]]$BcdArgs)
    $exe = Join-Path $env:SystemRoot "System32\bcdedit.exe"
    if (-not (Test-Path -LiteralPath $exe)) {
        throw "Skip-Reclaim11WinRe: missing $exe"
    }
    $stamp = [guid]::NewGuid().ToString("N").Substring(0, 8)
    $outFile = Join-Path $env:TEMP ("reclaim11-bcd-" + $stamp + ".out")
    $errFile = Join-Path $env:TEMP ("reclaim11-bcd-" + $stamp + ".err")
    try {
        $p = Start-Process -FilePath $exe -ArgumentList $BcdArgs -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $chunks = @()
        if (Test-Path -LiteralPath $outFile) {
            $chunks += Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $errFile) {
            $chunks += Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue
        }
        $text = ($chunks -join "`n")
        if ([int]$p.ExitCode -ne 0) {
            throw ("bcdedit exit {0}`n{1}" -f $p.ExitCode, $text)
        }
        $text
    } finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Reclaim11WinReSkip {
    param(
        [string]$WindowsRoot = "",
        [string]$BcdStore = "",
        [switch]$WhatIf
    )
    if ((-not $WhatIf) -and -not (Test-Reclaim11WinPeSession)) {
        throw "Refuse: this is a full Windows session. Boot the Reclaim11 WinPE ISO."
    }
    if ([string]::IsNullOrWhiteSpace($WindowsRoot)) {
        $vols = @(Find-Reclaim11WindowsVolumes)
        if ($vols.Count -lt 1) {
            throw "Skip-Reclaim11WinRe: no offline Windows volume (BitLocker locked?)"
        }
        if ($vols.Count -gt 1) {
            throw ("Skip-Reclaim11WinRe: multiple Windows volumes: {0}" -f (($vols | ForEach-Object { $_.VolumeRoot }) -join ", "))
        }
        $WindowsRoot = $vols[0].WindowsRoot
    }
    $winResolved = [IO.Path]::GetFullPath($WindowsRoot).TrimEnd("\")
    if (-not (Test-Path -LiteralPath $winResolved)) {
        throw "Skip-Reclaim11WinRe: missing WindowsRoot $winResolved"
    }
    $volumeRoot = Split-Path -Parent $winResolved
    $stores = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($BcdStore)) {
        $bcdRoot = [IO.Path]::GetPathRoot($BcdStore)
        if ((-not $WhatIf) -and (Test-Reclaim11PeMediaRoot -Root $bcdRoot)) {
            throw "Refuse: BCD is on WinPE media, not the Windows disk."
        }
        [void]$stores.Add($BcdStore)
    } else {
        foreach ($s in @(Find-Reclaim11BcdStores -VolumeRoot $volumeRoot -AssignEspLetter:(-not $WhatIf))) {
            [void]$stores.Add($s)
        }
    }
    $srt = Join-Path $winResolved "System32\LogFiles\Srt\SrtTrail.txt"
    $srtPresent = Test-Path -LiteralPath $srt
    $srtDest = Join-Path $winResolved "reclaim11-winre-skip.srt.txt"
    $dumps = New-Object System.Collections.Generic.List[string]
    $md = Join-Path $winResolved "Minidump"
    if (Test-Path -LiteralPath $md) {
        foreach ($f in @(Get-ChildItem -LiteralPath $md -Filter "*.dmp" -ErrorAction SilentlyContinue)) {
            [void]$dumps.Add($f.Name)
        }
    }
    if (Test-Path -LiteralPath (Join-Path $winResolved "MEMORY.DMP")) {
        [void]$dumps.Add("MEMORY.DMP")
    }
    $commands = @(
        "/set {default} recoveryenabled No",
        "/set {default} bootstatuspolicy IgnoreAllFailures"
    )
    $receiptPath = Join-Path $winResolved "reclaim11-winre-skip.log"
    $plan = [pscustomobject]@{
        id              = "reclaim11-winre-skip-v1"
        at              = [datetime]::UtcNow.ToString("o")
        what_if         = [bool]$WhatIf
        mutate          = $false
        windows_root    = $winResolved
        volume_root     = $volumeRoot
        bcd_stores      = @($stores)
        commands        = $commands
        srt_trail       = $(if ($srtPresent) { $srt } else { $null })
        srt_copied      = $false
        dumps           = @($dumps)
        receipt_path    = $receiptPath
        killing_blows   = $false
    }
    if ($WhatIf) {
        Write-Host "TEST ONLY. mutate=false. No bcdedit /set."
        return $plan
    }
    if ($stores.Count -lt 1) {
        throw "Skip-Reclaim11WinRe: no BCD store (EFI unmounted? BitLocker?)"
    }
    $edited = New-Object System.Collections.Generic.List[string]
    foreach ($store in @($stores)) {
        $storeRoot = [IO.Path]::GetPathRoot($store)
        if (Test-Reclaim11PeMediaRoot -Root $storeRoot) { continue }
        if (-not (Test-Path -LiteralPath $store)) {
            throw "Skip-Reclaim11WinRe: missing BCD $store"
        }
        $null = Invoke-Reclaim11BcdEdit -BcdArgs @("/store", $store, "/set", "{default}", "recoveryenabled", "No")
        $null = Invoke-Reclaim11BcdEdit -BcdArgs @("/store", $store, "/set", "{default}", "bootstatuspolicy", "IgnoreAllFailures")
        [void]$edited.Add($store)
    }
    if ($edited.Count -lt 1) {
        throw "Skip-Reclaim11WinRe: no Windows BCD edited (refused WinPE media store)"
    }
    $plan.bcd_stores = @($edited)
    if ($srtPresent) {
        Copy-Item -LiteralPath $srt -Destination $srtDest -Force
        $plan.srt_copied = $true
    }
    $plan.mutate = $true
    $plan.what_if = $false
    $json = $plan | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $receiptPath -Value $json -Encoding UTF8
    $plan
}

$script:SkipReceipt = Invoke-Reclaim11WinReSkip -WindowsRoot $WindowsRoot -BcdStore $BcdStore -WhatIf:$WhatIf
$script:SkipReceipt | ConvertTo-Json -Depth 8
Write-Host ("receipt {0}" -f $script:SkipReceipt.receipt_path)
if ($script:SkipReceipt.srt_trail) {
    Write-Host ("SrtTrail {0}" -f $script:SkipReceipt.srt_trail)
}
Write-Host "Disconnect the ISO, then wpeutil reboot."
