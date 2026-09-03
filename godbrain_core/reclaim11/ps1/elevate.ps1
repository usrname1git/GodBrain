# Reclaim11 TI via Task Scheduler. No wsudo. No MinSudo.
# WinPE is already SYSTEM — skip. Live: Admin -> SYSTEM task -> TI task.
# Never Heal. Never BFE.

[CmdletBinding()]
param(
    [ValidateSet("Auto", "SpawnTi")]
    [string]$Stage = "Auto",
    [string]$PayloadFile = "",
    [string]$LogFile = "",
    [string]$DoneFile = "",
    [int]$TimeoutSec = 180
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# NT SERVICE\TrustedInstaller
$script:Reclaim11TiSid = "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464"

function Test-Reclaim11WinPeSession {
    Test-Path -LiteralPath "X:\Windows\System32\wpeutil.exe"
}

function Test-Reclaim11IsSystem {
    [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq "S-1-5-18"
}

function Test-Reclaim11TrustedInstaller {
    [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq $script:Reclaim11TiSid
}

function Test-Reclaim11Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal $id
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Reclaim11Pwsh {
    $pwsh = Join-Path $PSHOME "pwsh.exe"
    if (Test-Path -LiteralPath $pwsh) { return $pwsh }
    $ps = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (Test-Path -LiteralPath $ps) { return $ps }
    throw "Get-Reclaim11Pwsh: no powershell"
}

function New-Reclaim11TiId {
    ([guid]::NewGuid().ToString("N").Substring(0, 12))
}

function Wait-Reclaim11DoneFile {
    param([string]$Path, [int]$TimeoutSec)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $Path) { return }
        Start-Sleep -Milliseconds 400
    }
    throw "Wait-Reclaim11DoneFile: timeout $TimeoutSec s ($Path)"
}

function Unregister-Reclaim11Task {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return }
    & schtasks.exe /Delete /TN $Name /F 2>$null | Out-Null
}

function Register-Reclaim11SystemTask {
    param(
        [string]$Name,
        [string]$Exe,
        [string]$Arguments
    )
    # COM, not schtasks /SD — locale date (sv-SE) returns E_FAIL 0x80004005.
    $svc = New-Object -ComObject "Schedule.Service"
    $svc.Connect()
    $folder = $svc.GetFolder("\")
    $task = $svc.NewTask(0)
    $task.Settings.Enabled = $true
    $task.Settings.Hidden = $true
    $task.Settings.AllowDemandStart = $true
    $task.Settings.StopIfGoingOnBatteries = $false
    $task.Settings.DisallowStartIfOnBatteries = $false
    $task.Settings.StartWhenAvailable = $true
    $task.Principal.UserId = "NT AUTHORITY\SYSTEM"
    $task.Principal.LogonType = 5
    $task.Principal.RunLevel = 1
    $act = $task.Actions.Create(0)
    $act.Path = $Exe
    $act.Arguments = $Arguments
    [void]$folder.RegisterTaskDefinition($Name, $task, 6, $null, $null, 5)
    $registered = $folder.GetTask($Name)
    [void]$registered.Run($null)
}

function Register-Reclaim11TiTask {
    param(
        [string]$Name,
        [string]$Exe,
        [string]$Arguments
    )
    $svc = New-Object -ComObject "Schedule.Service"
    $svc.Connect()
    $folder = $svc.GetFolder("\")
    $task = $svc.NewTask(0)
    $task.Settings.Enabled = $true
    $task.Settings.Hidden = $true
    $task.Settings.AllowDemandStart = $true
    $task.Settings.StopIfGoingOnBatteries = $false
    $task.Settings.DisallowStartIfOnBatteries = $false
    $task.Settings.StartWhenAvailable = $true
    $task.Principal.UserId = "NT SERVICE\TrustedInstaller"
    $task.Principal.LogonType = 5
    $task.Principal.RunLevel = 1
    $act = $task.Actions.Create(0)
    $act.Path = $Exe
    $act.Arguments = $Arguments
    [void]$folder.RegisterTaskDefinition($Name, $task, 6, $null, $null, 5)
    $registered = $folder.GetTask($Name)
    [void]$registered.Run($null)
}

function New-Reclaim11TiRunnerScript {
    param(
        [string]$PayloadFile,
        [string]$LogFile,
        [string]$DoneFile
    )
    $pwsh = Get-Reclaim11Pwsh
    $id = New-Reclaim11TiId
    $runner = Join-Path $env:TEMP ("reclaim11-ti-run-" + $id + ".ps1")
    $pay = $PayloadFile.Replace("'", "''")
    $log = $LogFile.Replace("'", "''")
    $done = $DoneFile.Replace("'", "''")
    $exe = $pwsh.Replace("'", "''")
    @(
        "Set-StrictMode -Version Latest",
        "`$env:RECLAIM11_AS_TI = '1'",
        "`$p = Start-Process -FilePath '$exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','$pay') -Wait -PassThru -NoNewWindow -RedirectStandardOutput '$log' -RedirectStandardError '$log.err'",
        "Set-Content -LiteralPath '$done' -Value ([string]`$p.ExitCode) -Encoding ASCII"
    ) -join "`r`n" | Set-Content -LiteralPath $runner -Encoding UTF8
    $runner
}

function Invoke-Reclaim11SpawnTi {
    param(
        [string]$PayloadFile,
        [string]$LogFile,
        [string]$DoneFile,
        [int]$TimeoutSec = 180
    )
    if (-not (Test-Path -LiteralPath $PayloadFile)) {
        throw "Invoke-Reclaim11SpawnTi: missing $PayloadFile"
    }
    $pwsh = Get-Reclaim11Pwsh
    $runner = New-Reclaim11TiRunnerScript -PayloadFile $PayloadFile -LogFile $LogFile -DoneFile $DoneFile
    $tn = "Reclaim11-Ti-" + (New-Reclaim11TiId)
    try {
        $args = "-NoProfile -ExecutionPolicy Bypass -File `"$runner`""
        Register-Reclaim11TiTask -Name $tn -Exe $pwsh -Arguments $args
        Wait-Reclaim11DoneFile -Path $DoneFile -TimeoutSec $TimeoutSec
    } finally {
        Unregister-Reclaim11Task -Name $tn
        if (Test-Path -LiteralPath $runner) { Remove-Item -LiteralPath $runner -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-Reclaim11AsTrustedInstaller {
    param(
        [Parameter(Mandatory)]
        [string]$File,
        [int]$TimeoutSec = 180
    )
    if (Test-Reclaim11WinPeSession) {
        return [pscustomobject]@{ continue = $true; reason = "winpe-system" }
    }
    if ($env:RECLAIM11_AS_TI -eq "1" -or (Test-Reclaim11TrustedInstaller)) {
        return [pscustomobject]@{ continue = $true; reason = "already-ti" }
    }
    if (-not (Test-Reclaim11Admin) -and -not (Test-Reclaim11IsSystem)) {
        throw "Invoke-Reclaim11AsTrustedInstaller: needs elevation (Admin). No wsudo."
    }
    if (-not (Test-Path -LiteralPath $File)) {
        throw "Invoke-Reclaim11AsTrustedInstaller: missing $File"
    }

    $id = New-Reclaim11TiId
    $log = Join-Path $env:TEMP ("reclaim11-ti-" + $id + ".log")
    $done = Join-Path $env:TEMP ("reclaim11-ti-" + $id + ".done")
    $here = Split-Path -Parent $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($here)) { $here = Split-Path -Parent $File }
    $elevate = Join-Path $here "elevate.ps1"

    if (Test-Reclaim11IsSystem) {
        Invoke-Reclaim11SpawnTi -PayloadFile $File -LogFile $log -DoneFile $done -TimeoutSec $TimeoutSec
    } else {
        $pwsh = Get-Reclaim11Pwsh
        $sysRunner = Join-Path $env:TEMP ("reclaim11-sys-" + $id + ".ps1")
        $el = $elevate.Replace("'", "''")
        $pay = $File.Replace("'", "''")
        $lg = $log.Replace("'", "''")
        $dn = $done.Replace("'", "''")
        @(
            "Set-StrictMode -Version Latest",
            ". '$el'",
            "Invoke-Reclaim11SpawnTi -PayloadFile '$pay' -LogFile '$lg' -DoneFile '$dn' -TimeoutSec $TimeoutSec"
        ) -join "`r`n" | Set-Content -LiteralPath $sysRunner -Encoding UTF8
        $tn = "Reclaim11-Sys-" + $id
        $sysArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$sysRunner`""
        try {
            Register-Reclaim11SystemTask -Name $tn -Exe $pwsh -Arguments $sysArgs
            Wait-Reclaim11DoneFile -Path $done -TimeoutSec $TimeoutSec
        } finally {
            Unregister-Reclaim11Task -Name $tn
            if (Test-Path -LiteralPath $sysRunner) { Remove-Item -LiteralPath $sysRunner -Force -ErrorAction SilentlyContinue }
        }
    }

    $code = 1
    if (Test-Path -LiteralPath $done) {
        $code = [int]((Get-Content -LiteralPath $done -Raw).Trim())
    }
    $chunks = @()
    if (Test-Path -LiteralPath $log) {
        $chunks += Get-Content -LiteralPath $log -Raw -ErrorAction SilentlyContinue
    }
    $errLog = $log + ".err"
    if (Test-Path -LiteralPath $errLog) {
        $chunks += Get-Content -LiteralPath $errLog -Raw -ErrorAction SilentlyContinue
    }
    $out = (($chunks | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n")
    [pscustomobject]@{
        continue  = $false
        reason    = "spawned-ti"
        exit_code = $code
        log       = $log
        err_log   = $errLog
        output    = $out
    }
}

if ($MyInvocation.InvocationName -ne ".") {
    if ($Stage -eq "SpawnTi") {
        Invoke-Reclaim11SpawnTi -PayloadFile $PayloadFile -LogFile $LogFile -DoneFile $DoneFile -TimeoutSec $TimeoutSec
    }
}
