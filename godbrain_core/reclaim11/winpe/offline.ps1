# Offline pack-A apply for Reclaim11 WinPE. Mutates an offline Windows volume
# only. Never BFE / mpssvc / FltMgr / mscoree. Not Heal. Not a live wipe.
# PowerShell 5.1 (WinPE) and 7 (Test-Reclaim11).

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-Reclaim11WinPeSession {
    Test-Path -LiteralPath "X:\Windows\System32\wpeutil.exe"
}

function Test-Reclaim11PeMz {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $fs = [IO.File]::OpenRead($Path)
    try {
        $b = New-Object byte[] 2
        $n = $fs.Read($b, 0, 2)
        return ($n -eq 2 -and $b[0] -eq 0x4D -and $b[1] -eq 0x5A)
    } finally {
        $fs.Close()
    }
}

function Get-Reclaim11WinPeReceipt {
    param(
        [string]$Path = "",
        [string]$WindowsRoot = ""
    )
    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($Path)) { [void]$candidates.Add($Path) }
    $root = $WindowsRoot
    if ([string]::IsNullOrWhiteSpace($root)) { $root = $env:SystemRoot }
    if (-not [string]::IsNullOrWhiteSpace($root)) {
        [void]$candidates.Add((Join-Path $root "reclaim11-winpe.log"))
        $parent = Split-Path -Parent $root
        if ($parent) { [void]$candidates.Add((Join-Path $parent "reclaim11-winpe.log")) }
    }
    foreach ($c in $candidates) {
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        if (-not (Test-Path -LiteralPath $c)) { continue }
        try {
            $j = Get-Content -LiteralPath $c -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.PSObject.Properties["id"] -and ([string]$j.id -like "reclaim11-winpe*")) {
                return (Get-Item -LiteralPath $c).FullName
            }
        } catch {
            continue
        }
    }
    $null
}

function Get-Reclaim11NeverTouchRelPaths {
    @(
        "Windows\System32\drivers\fltmgr.sys",
        "Windows\System32\drivers\mpsdrv.sys",
        "Windows\System32\bfe.dll",
        "Windows\System32\mpssvc.dll",
        "Windows\System32\mscoree.dll"
    )
}

function Get-Reclaim11PplOfflineRelPaths {
    # 25H2 Pro keeps Wd*.sys in drivers\ (wd\ is often empty).
    # Older layouts use drivers\wd\. Exact catalog names only —
    # never Wd*.sys (that would hit wdf01000.sys / WdfLdr.sys / WdiWiFi.sys).
    @(
        "Windows\System32\drivers\WdBoot.sys",
        "Windows\System32\drivers\WdFilter.sys",
        "Windows\System32\drivers\WdNisDrv.sys",
        "Windows\System32\drivers\WdDevFlt.sys",
        "Windows\System32\drivers\wd\WdBoot.sys",
        "Windows\System32\drivers\wd\WdFilter.sys",
        "Windows\System32\drivers\wd\WdNisDrv.sys",
        "Windows\System32\drivers\wd\WdDevFlt.sys",
        "Program Files\Windows Defender\MsMpEng.exe",
        "Program Files\Windows Defender\NisSrv.exe"
    )
}

function Test-Reclaim11NeverTouchPath {
    param(
        [string]$VolumeRoot,
        [string]$Path
    )
    $leaf = [IO.Path]::GetFileName($Path)
    if ($leaf -eq "mscoree.dll" -or $leaf -eq "fltmgr.sys" -or $leaf -eq "mpsdrv.sys" -or $leaf -eq "bfe.dll" -or $leaf -eq "mpssvc.dll" -or $leaf -eq "wdf01000.sys" -or $leaf -eq "WdfLdr.sys" -or $leaf -eq "WdiWiFi.sys") {
        return $true
    }
    $norm = $Path.ToLowerInvariant()
    foreach ($rel in Get-Reclaim11NeverTouchRelPaths) {
        $full = (Join-Path $VolumeRoot $rel).ToLowerInvariant()
        if ($norm -eq $full) { return $true }
    }
    $false
}

function Get-Reclaim11OfflineSecureBoot {
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State"
    try {
        $v = Get-ItemProperty -LiteralPath $regPath -Name UEFISecureBootEnabled -ErrorAction Stop
        return [pscustomobject]@{
            available = $true
            enabled   = [bool]$v.UEFISecureBootEnabled
            error     = $null
        }
    } catch {
        # fall through
    }
    try {
        $on = Confirm-SecureBootUEFI
        return [pscustomobject]@{
            available = $true
            enabled   = [bool]$on
            error     = $null
        }
    } catch {
        return [pscustomobject]@{
            available = $false
            enabled   = $false
            error     = [string]$_.Exception.Message
        }
    }
}

function Get-Reclaim11OfflineEditionId {
    param([string]$WindowsRoot)
    $hive = Join-Path $WindowsRoot "System32\config\SOFTWARE"
    if (-not (Test-Path -LiteralPath $hive)) {
        throw "Refuse: cannot read EditionID (needed to refuse desk). missing SOFTWARE hive."
    }
    $key = "HKLM\R11EDITION"
    $null = & reg.exe unload $key 2>&1
    $loaded = $false
    try {
        & reg.exe load $key $hive | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Refuse: cannot read EditionID (needed to refuse desk). reg load failed."
        }
        $loaded = $true
        $p = "HKLM:\R11EDITION\Microsoft\Windows NT\CurrentVersion"
        if (-not (Test-Path -LiteralPath $p)) {
            throw "Refuse: cannot read EditionID (needed to refuse desk). missing CurrentVersion."
        }
        $id = [string](Get-ItemProperty -LiteralPath $p).EditionID
        if ([string]::IsNullOrWhiteSpace($id)) {
            throw "Refuse: cannot read EditionID (needed to refuse desk)."
        }
        $id
    } finally {
        if ($loaded) {
            & reg.exe unload $key | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Refuse: cannot unload SOFTWARE hive after EditionID read."
            }
        }
    }
}

function Find-Reclaim11WindowsVolumes {
    $rows = @()
    foreach ($d in @(Get-PSDrive -PSProvider FileSystem)) {
        $root = [string]$d.Root
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        if ($root -like "X:\*") { continue }
        $ntos = Join-Path $root "Windows\System32\ntoskrnl.exe"
        if (Test-Path -LiteralPath $ntos) {
            $vol = $root.TrimEnd("\")
            $rows += [pscustomobject]@{
                VolumeRoot  = $vol
                WindowsRoot = (Join-Path $vol "Windows")
            }
        }
    }
    $rows
}

function Get-Reclaim11UsermodeRelPaths {
    @(
        "Windows\System32\smartscreen.exe",
        "Windows\SysWOW64\smartscreen.exe",
        "Windows\System32\SecurityHealthHost.exe",
        "Windows\System32\SecurityHealthService.exe",
        "Windows\System32\SecurityHealthSystray.exe",
        "Program Files\Windows Defender\MsMpEng.exe",
        "Program Files\Windows Defender\NisSrv.exe",
        "Program Files\Windows Defender\MpDefenderCoreService.exe",
        "Program Files\Windows Defender Advanced Threat Protection\MsSense.exe"
    )
}

function Find-Reclaim11UsermodeFiles {
    param(
        [string]$VolumeRoot,
        $Catalog
    )
    $names = @($Catalog.usermode_ifeo)
    $hits = @()
    foreach ($rel in Get-Reclaim11UsermodeRelPaths) {
        $leaf = Split-Path -Leaf $rel
        if ($names -notcontains $leaf) { continue }
        $full = Join-Path $VolumeRoot $rel
        if (Test-Path -LiteralPath $full) {
            $hits += [pscustomobject]@{ name = $leaf; path = $full }
        }
    }
    $plat = Join-Path $VolumeRoot "ProgramData\Microsoft\Windows Defender\Platform"
    if (Test-Path -LiteralPath $plat) {
        foreach ($n in $names) {
            if ($n -notlike "*.exe") { continue }
            $found = @(Get-ChildItem -LiteralPath $plat -Recurse -File -Filter $n -ErrorAction SilentlyContinue)
            foreach ($f in $found) {
                $hits += [pscustomobject]@{ name = $n; path = $f.FullName }
            }
        }
    }
    $hits
}

function Find-Reclaim11PplFiles {
    param(
        [string]$VolumeRoot,
        $Catalog
    )
    $names = @($Catalog.ppl_offline)
    $hits = @()
    foreach ($rel in Get-Reclaim11PplOfflineRelPaths) {
        $leaf = Split-Path -Leaf $rel
        if ($names -notcontains $leaf) { continue }
        $full = Join-Path $VolumeRoot $rel
        if (Test-Path -LiteralPath $full) {
            $hits += [pscustomobject]@{
                name = $leaf
                path = $full
                elam = ($leaf -eq "WdBoot.sys")
            }
        }
    }
    $plat = Join-Path $VolumeRoot "ProgramData\Microsoft\Windows Defender\Platform"
    if (Test-Path -LiteralPath $plat) {
        foreach ($n in @("MsMpEng.exe", "NisSrv.exe")) {
            if ($names -notcontains $n) { continue }
            $found = @(Get-ChildItem -LiteralPath $plat -Recurse -File -Filter $n -ErrorAction SilentlyContinue)
            foreach ($f in $found) {
                $hits += [pscustomobject]@{
                    name = $n
                    path = $f.FullName
                    elam = $false
                }
            }
        }
    }
    $hits
}

function Unlock-Reclaim11OfflineFile {
    param([string]$Path)
    & takeown.exe /F $Path /A | Out-Null
    & icacls.exe $Path /grant:r "Administrators:F" | Out-Null
}

function Set-Reclaim11OfflineStub {
    param(
        [string]$Path,
        [string]$StubPath
    )
    if (-not (Test-Reclaim11PeMz -Path $StubPath)) {
        throw "Set-Reclaim11OfflineStub: stub is not MZ: $StubPath"
    }
    try {
        Copy-Item -LiteralPath $StubPath -Destination $Path -Force
    } catch {
        Unlock-Reclaim11OfflineFile -Path $Path
        Copy-Item -LiteralPath $StubPath -Destination $Path -Force
    }
    if (-not (Test-Reclaim11PeMz -Path $Path)) {
        throw "Set-Reclaim11OfflineStub: target is not MZ after copy: $Path"
    }
    [pscustomobject]@{ path = $Path; action = "stubbed" }
}

function Set-Reclaim11OfflineDriver {
    # Kernel .sys cannot be replaced with the usermode IFEO stub (that bootlooped).
    # Operator PE: delete. No sidecar .bak in drivers\ (Safe cleanse GUI keeps a catalog).
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ path = $Path; action = "already-gone" }
    }
    try {
        Remove-Item -LiteralPath $Path -Force
    } catch {
        Unlock-Reclaim11OfflineFile -Path $Path
        Remove-Item -LiteralPath $Path -Force
    }
    if (Test-Path -LiteralPath $Path) {
        throw "Set-Reclaim11OfflineDriver: still present $Path"
    }
    [pscustomobject]@{ path = $Path; action = "deleted" }
}

function Disable-Reclaim11OfflineDriverServices {
    param(
        [string]$WindowsRoot,
        [string[]]$ServiceNames
    )
    $hive = Join-Path $WindowsRoot "System32\config\SYSTEM"
    if (-not (Test-Path -LiteralPath $hive)) { return @() }
    $key = "HKLM\R11SYS"
    $loaded = $false
    $done = New-Object System.Collections.Generic.List[string]
    try {
        & reg.exe load $key $hive | Out-Null
        if ($LASTEXITCODE -ne 0) { return @() }
        $loaded = $true
        $current = 1
        $sel = "HKLM:\R11SYS\Select"
        if (Test-Path -LiteralPath $sel) {
            $current = [int](Get-ItemProperty -LiteralPath $sel).Current
        }
        $cs = ("ControlSet{0:D3}" -f $current)
        foreach ($n in $ServiceNames) {
            if ([string]::IsNullOrWhiteSpace($n)) { continue }
            $regPath = "$key\$cs\Services\$n"
            & reg.exe delete $regPath /f | Out-Null
            if ($LASTEXITCODE -eq 0) {
                [void]$done.Add($n)
                continue
            }
            & reg.exe add $regPath /v Start /t REG_DWORD /d 4 /f | Out-Null
            if ($LASTEXITCODE -eq 0) { [void]$done.Add($n) }
        }
    } finally {
        if ($loaded) { & reg.exe unload $key | Out-Null }
    }
    @($done)
}

function Set-Reclaim11OfflineSoftwareHive {
    param(
        [string]$WindowsRoot,
        [string]$StubWinPath,
        [string[]]$IfeoNames
    )
    $hive = Join-Path $WindowsRoot "System32\config\SOFTWARE"
    if (-not (Test-Path -LiteralPath $hive)) {
        return [pscustomobject]@{ ifeo = @(); policy = $false }
    }
    $key = "HKLM\R11SOFT"
    $loaded = $false
    $ifeo = New-Object System.Collections.Generic.List[string]
    $policy = $false
    try {
        & reg.exe load $key $hive | Out-Null
        if ($LASTEXITCODE -ne 0) {
            return [pscustomobject]@{ ifeo = @(); policy = $false }
        }
        $loaded = $true
        foreach ($img in $IfeoNames) {
            if ([string]::IsNullOrWhiteSpace($img)) { continue }
            if ($img -eq "mscoree.dll") { continue }
            $sub = "$key\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$img"
            & reg.exe add $sub /v Debugger /t REG_SZ /d $StubWinPath /f | Out-Null
            if ($LASTEXITCODE -eq 0) { [void]$ifeo.Add($img) }
        }
        $pol = "$key\Policies\Microsoft\Windows Defender"
        & reg.exe add $pol /v DisableAntiSpyware /t REG_DWORD /d 1 /f | Out-Null
        $policy = ($LASTEXITCODE -eq 0)
    } finally {
        if ($loaded) { & reg.exe unload $key | Out-Null }
    }
    [pscustomobject]@{ ifeo = @($ifeo); policy = $policy }
}

function Write-Reclaim11WinPeReceipt {
    param(
        $Receipt,
        [string]$WindowsRoot
    )
    $path = Join-Path $WindowsRoot "reclaim11-winpe.log"
    $json = $Receipt | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $path -Value $json -Encoding UTF8
    $path
}

function Invoke-Reclaim11OfflineApply {
    param(
        [string]$CatalogPath,
        [string]$StubPath,
        [string]$WindowsRoot = "",
        [string]$EditionId = "",
        $SecureBoot = $null
    )
    if (-not (Test-Path -LiteralPath $CatalogPath)) {
        throw "Invoke-Reclaim11OfflineApply: missing catalog $CatalogPath"
    }
    $cat = Get-Content -LiteralPath $CatalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$cat.id -ne "reclaim11-pack-a-v1") {
        throw "Invoke-Reclaim11OfflineApply: catalog id"
    }
    if (-not (Test-Reclaim11PeMz -Path $StubPath)) {
        throw "Invoke-Reclaim11OfflineApply: stub is not a PE (MZ): $StubPath"
    }

    $inPe = Test-Reclaim11WinPeSession
    if ([string]::IsNullOrWhiteSpace($WindowsRoot)) {
        if (-not $inPe) {
            throw "Refuse: this is a full Windows session. Boot the Reclaim11 WinPE ISO (not M1ABRAMS)."
        }
        $vols = @(Find-Reclaim11WindowsVolumes)
        if ($vols.Count -lt 1) {
            throw "Invoke-Reclaim11OfflineApply: no offline Windows volume (BitLocker locked?)"
        }
        if ($vols.Count -gt 1) {
            throw ("Invoke-Reclaim11OfflineApply: multiple Windows volumes: {0}" -f (($vols | ForEach-Object { $_.VolumeRoot }) -join ", "))
        }
        $WindowsRoot = $vols[0].WindowsRoot
    }

    $winResolved = [IO.Path]::GetFullPath($WindowsRoot).TrimEnd("\")
    $sysResolved = [IO.Path]::GetFullPath($env:SystemRoot).TrimEnd("\")
    if (-not $inPe -and $winResolved -eq $sysResolved) {
        throw "Refuse: -WindowsRoot is this session's Windows. Boot the ISO."
    }
    $sku = $EditionId
    if ([string]::IsNullOrWhiteSpace($sku)) {
        $sku = Get-Reclaim11OfflineEditionId -WindowsRoot $winResolved
    }
    if ($sku -eq "IoTEnterpriseS") {
        throw "Refuse: desk (IoTEnterpriseS). Offline pack A is VM-only. Not M1ABRAMS."
    }

    $volumeRoot = Split-Path -Parent $winResolved
    if ([string]::IsNullOrWhiteSpace($volumeRoot)) {
        throw "Invoke-Reclaim11OfflineApply: WindowsRoot has no parent volume"
    }

    $sb = $SecureBoot
    if ($null -eq $sb) { $sb = Get-Reclaim11OfflineSecureBoot }
    $avail = [bool]$sb.available
    $enabled = [bool]$sb.enabled
    $allowElam = $avail -and -not $enabled

    $stubOnVol = Join-Path $winResolved "reclaim11-stub.exe"
    Copy-Item -LiteralPath $StubPath -Destination $stubOnVol -Force
    $stubWinPath = Join-Path $volumeRoot "Windows\reclaim11-stub.exe"

    $stubbed = New-Object System.Collections.Generic.List[string]
    $parked = New-Object System.Collections.Generic.List[string]
    $skippedElam = New-Object System.Collections.Generic.List[string]
    $skippedNever = New-Object System.Collections.Generic.List[string]
    $missing = New-Object System.Collections.Generic.List[string]
    $named = @($cat.ppl_offline)
    $seen = @{}

    $hits = @(Find-Reclaim11PplFiles -VolumeRoot $volumeRoot -Catalog $cat)
    foreach ($h in $hits) {
        $seen[$h.name] = $true
        if (Test-Reclaim11NeverTouchPath -VolumeRoot $volumeRoot -Path $h.path) {
            [void]$skippedNever.Add($h.path)
            continue
        }
        if ($h.elam -and -not $allowElam) {
            [void]$skippedElam.Add($h.path)
            continue
        }
        $ext = [IO.Path]::GetExtension($h.path)
        if ($ext -eq ".sys") {
            $null = Set-Reclaim11OfflineDriver -Path $h.path
            [void]$parked.Add($h.path)
        } else {
            $null = Set-Reclaim11OfflineStub -Path $h.path -StubPath $StubPath
            [void]$stubbed.Add($h.path)
        }
    }
    foreach ($u in @(Find-Reclaim11UsermodeFiles -VolumeRoot $volumeRoot -Catalog $cat)) {
        if (Test-Reclaim11NeverTouchPath -VolumeRoot $volumeRoot -Path $u.path) { continue }
        $null = Set-Reclaim11OfflineStub -Path $u.path -StubPath $StubPath
        if (@($stubbed) -notcontains $u.path) { [void]$stubbed.Add($u.path) }
    }
    foreach ($n in $named) {
        if (-not $seen.ContainsKey($n)) { [void]$missing.Add($n) }
    }
    foreach ($n in @($missing.ToArray())) {
        if ($n -notlike "*.sys") { continue }
        $foundBak = $false
        foreach ($rel in Get-Reclaim11PplOfflineRelPaths) {
            if ((Split-Path -Leaf $rel) -ne $n) { continue }
            $orig = Join-Path $volumeRoot $rel
            $bak = $orig + ".reclaim11.bak"
            if (Test-Path -LiteralPath $bak) {
                [void]$parked.Add($orig)
                $foundBak = $true
            }
        }
        if ($foundBak) { [void]$missing.Remove($n) }
    }
    $svcAll = @()
    foreach ($s in @($cat.services_pack_a)) {
        if (@($cat.never_touch_services) -contains $s) { continue }
        $svcAll += $s
    }
    $disabled = @(Disable-Reclaim11OfflineDriverServices -WindowsRoot $winResolved -ServiceNames $svcAll)
    $soft = Set-Reclaim11OfflineSoftwareHive -WindowsRoot $winResolved -StubWinPath $stubWinPath -IfeoNames @($cat.usermode_ifeo)

    $reasonWd = if (-not $avail) {
        "Secure Boot n/a: refuse WdBoot stub (ELAM)."
    } elseif ($enabled) {
        "Secure Boot on: refuse WdBoot stub (ELAM)."
    } else {
        "Secure Boot off: WdBoot parked on the offline volume (not a usermode stub)."
    }

    $receipt = [pscustomobject]@{
        id             = "reclaim11-winpe-v1"
        at             = [datetime]::UtcNow.ToString("o")
        catalog        = [string]$cat.id
        windows_root   = $winResolved
        volume_root    = $volumeRoot
        secure_boot    = $sb
        stub_wdboot    = [bool]$allowElam
        reason_wdboot  = $reasonWd
        stubbed        = @($stubbed)
        parked         = @($parked)
        services_start4 = @($disabled)
        ifeo_offline   = @($soft.ifeo)
        policy_offline = [bool]$soft.policy
        skipped_elam   = @($skippedElam)
        skipped_never  = @($skippedNever)
        missing        = @($missing)
        never_touch_ok = ($skippedNever.Count -eq 0)
        mutate         = $true
        live_wipe      = $false
    }
    $kitFrom = Split-Path -Parent $CatalogPath
    $kitDst = Join-Path $volumeRoot "reclaim11"
    if (-not (Test-Path -LiteralPath $kitDst)) {
        New-Item -ItemType Directory -Path $kitDst | Out-Null
    }
    foreach ($n in @("catalog.json", "inventory.ps1", "killing_blows.ps1", "Apply-KillingBlows.ps1", "noob_cleanse.ps1", "Apply-NoobCleanse.ps1", "Restore-Reclaim11Noob.ps1", "grim_reaper.ps1", "NuclearDefenderWipe-V6_3.ps1", "xbox_cleanse.ps1", "telemetry_cleanse.ps1", "nic_tune.ps1", "latency_bake.ps1", "elevate.ps1", "offline.ps1")) {
        $s = $null
        foreach ($cand in @(
                (Join-Path $kitFrom $n),
                (Join-Path $kitFrom "ps1\$n"),
                (Join-Path $kitFrom "winpe\$n"),
                (Join-Path (Split-Path -Parent $kitFrom) $n)
            )) {
            if (Test-Path -LiteralPath $cand) { $s = $cand; break }
        }
        if ($s) {
            Copy-Item -LiteralPath $s -Destination (Join-Path $kitDst $n) -Force
        }
    }
    $receiptPath = Write-Reclaim11WinPeReceipt -Receipt $receipt -WindowsRoot $winResolved
    $receipt | Add-Member -NotePropertyName receipt_path -NotePropertyValue $receiptPath
    $receipt | Add-Member -NotePropertyName stub_on_volume -NotePropertyValue $stubOnVol
    $receipt
}
