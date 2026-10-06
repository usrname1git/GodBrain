[CmdletBinding()]
param()
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
$helper = Join-Path $repo "GodBrain-Cs2.ps1"
$fixture = Join-Path ([System.IO.Path]::GetTempPath()) ("GodBrain-Cs2-test-" + [guid]::NewGuid().ToString("N"))
$null = New-Item -ItemType Directory -Path $fixture

function Assert-Equal($Actual, $Expected) {
    if ($Actual -cne $Expected) { throw "Expected '$Expected', got '$Actual'." }
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    try { & $Action } catch {
        if ($_.Exception.Message -notlike $Message) { throw }
        return
    }
    throw "Expected failure: $Message"
}
function Read-TestAst([string]$Path) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors -join "`n") }
    return $ast
}

& {
    . $helper
    $child = Start-Process -FilePath "C:\pwsh\pwsh.exe" -ArgumentList @(
        "-NoProfile", "-Command", "Start-Sleep -Seconds 60"
    ) -WindowStyle Hidden -PassThru
    try {
        $owned = Get-CimInstance Win32_Process -Filter "ProcessId=$($child.Id)" -ErrorAction Stop
        if (-not $owned) { throw "Owned-process fixture did not start." }
        $wrong = [pscustomobject]@{
            ProcessId = $owned.ProcessId
            CreationDate = $owned.CreationDate
            CommandLine = "not the owned command"
        }
        Assert-Throws { Stop-Cs2OwnedProcess $wrong } "*changed identity*"
        Assert-Equal $child.HasExited $false
        Stop-Cs2OwnedProcess $owned
        if (-not $child.WaitForExit(5000)) { throw "Owned-process fixture was not released." }
    } finally {
        if (-not $child.HasExited) { Stop-Process -Id $child.Id -Force }
        $child.Dispose()
    }
}

try {
    foreach ($path in @("Start-CS2.ps1", "GodBrain-Cs2.ps1", "Watch-Cs2Pause.ps1",
        "Install-GodBrainWatch.ps1", "Install-GodBrainCs2Pause.ps1",
        "Watch-GodBrain.ps1", "Heal-GodBrain.ps1", "Start-GodBrain.ps1",
        "Test-GodBrainDesk.ps1", "scripts\Show-DeskMenu.ps1")) {
        $null = Read-TestAst (Join-Path $repo $path)
    }
    & {
        . $helper
        $script:gameRunning = $false
        function Test-Cs2Running { return $script:gameRunning }
        Assert-Equal (Test-GodBrainColiShouldSleep $fixture) $false
        $state = Read-Cs2PauseState $fixture
        $state.paused = $true
        $state.last_seen = "2000-01-01T00:00:00Z"
        $state.last_action = "pause-manual"
        Write-Cs2PauseState $fixture $state
        Assert-Equal (Test-GodBrainColiShouldSleep $fixture) $true
        $script:gameRunning = $true
        Assert-Throws { Clear-GodBrainCs2Pause $fixture } "*CS2 is running*"
        Assert-Equal (Read-Cs2PauseState $fixture).paused $true
        $script:gameRunning = $false
        function Set-GodBrainTaskEnabled { throw "Clearing the hold must not enable tasks." }
        function Set-TailscaleForCs2 { throw "Clearing the hold must not reconnect Tailscale." }
        function Start-Process { throw "Clearing the hold must not start a process." }
        Clear-GodBrainCs2Pause $fixture
        Assert-Equal (Read-Cs2PauseState $fixture).paused $false
        Assert-Equal (Read-Cs2PauseState $fixture).last_action "resume-now"
        Assert-Equal (Test-GodBrainColiShouldSleep $fixture) $false
        Clear-GodBrainCs2Pause $fixture

        $kit = "C:\nvme\Qwen3.8-27B-16gb"
        $python = "$kit\.venv\Scripts\python.exe"
        $process = [pscustomobject]@{
            Name = "python.exe"; ExecutablePath = $python
            CommandLine = "`"$python`" -u tools\serve_openai.py --port 8888"
        }
        Assert-Equal (Test-Cs2ModelProcess $process $repo) $true
        $process.ExecutablePath = "C:\Tools\Python\python.exe"
        Assert-Equal (Test-Cs2ModelProcess $process $repo) $true
        $process.CommandLine = '"C:\Tools\Python\python.exe" -u tools\serve_openai.py --port 8888'
        Assert-Equal (Test-Cs2ModelProcess $process $repo) $false
        $process.CommandLine = "python.exe -u `"$kit\tools\serve_openai.py`" --port 8888"
        Assert-Equal (Test-Cs2ModelProcess $process $repo) $true
        $process.CommandLine = "python.exe -u `"$kit\tools\serve_openai.py.backup`""
        Assert-Equal (Test-Cs2ModelProcess $process $repo) $false
        $process.CommandLine = "python.exe `"$repo\scripts\qwen_image_server.py`" --worker fixture"
        Assert-Equal (Test-Cs2ModelProcess $process $repo) $true
        $process.CommandLine = "python.exe `"$repo\scripts\qwen_image_server.py`""
        Assert-Equal (Test-Cs2ModelProcess $process $repo) $true
        $process.CommandLine = 'python.exe -m http.server 8000'
        Assert-Equal (Test-Cs2ModelProcess $process $repo) $false
        Assert-Equal (Test-Cs2CpuWebProcess $process) $true
        $process.CommandLine = 'python.exe -c "load_model(); # -m http.server"'
        Assert-Equal (Test-Cs2CpuWebProcess $process) $false
        $process.CommandLine = 'python.exe lyrics_loop.py'
        Assert-Equal (Test-Cs2ModelProcess $process $repo) $false
        $process.Name = "llama-server.exe"
        $process.CommandLine = 'llama-server.exe --port 8000'
        Assert-Equal (Test-Cs2ModelProcess $process $repo) $true
        $process.CommandLine = 'llama-server.exe --port 18000'
        Assert-Equal (Test-Cs2ModelProcess $process $repo) $false
        $process.Name = "python.exe"
        $process.CommandLine = "python.exe `"$repo\LLM\colibri_LLM\c\coli`" serve --port 8000"
        Assert-Equal (Test-Cs2ModelProcess $process $repo) $true
        $process.Name = "pwsh.exe"
        $process.CommandLine = "pwsh.exe -NoProfile -File `"$repo\scripts\Watch-FrontendGymOvernight.ps1`""
        Assert-Equal (Test-Cs2ScriptProcess $process "$repo\scripts\Watch-FrontendGymOvernight.ps1" -PowerShell) $true
        $process.CommandLine = "pwsh.exe -Command `"Get-Content '$repo\scripts\Watch-FrontendGymOvernight.ps1'`""
        Assert-Equal (Test-Cs2ScriptProcess $process "$repo\scripts\Watch-FrontendGymOvernight.ps1" -PowerShell) $false

        $gym = Join-Path $fixture "godbrain_core\skill_lab\work\gym"
        $null = New-Item -ItemType Directory -Path $gym -Force
        $pause = Join-Path $gym "training-pause.json"
        '{"paused":false,"stopQwen":true,"autoplay":false,"fixture":"keep"}' |
            Set-Content -LiteralPath $pause
        Suspend-Cs2GymTraining $fixture
        $control = Get-Content -LiteralPath $pause -Raw | ConvertFrom-Json
        Assert-Equal $control.paused $true
        Assert-Equal $control.stopQwen $false
        Assert-Equal $control.autoplay $false
        Assert-Equal $control.fixture "keep"
        Assert-Equal $control.reason "cs2_manual_pause"
        "{broken" | Set-Content -LiteralPath (Get-Cs2PauseStatePath $fixture)
        Assert-Throws { Test-GodBrainColiShouldSleep $fixture } "*pause state is invalid*"
        Assert-Equal (Read-Cs2PauseState $fixture -ForShutdown).suspended $false
        '{"paused":"false"}' | Set-Content -LiteralPath (Get-Cs2PauseStatePath $fixture)
        Assert-Throws { Test-GodBrainColiShouldSleep $fixture } "*pause state is invalid*"
        '{"paused":true,"last_action":"legacy"}' | Set-Content -LiteralPath (Get-Cs2PauseStatePath $fixture)
        Assert-Equal (Read-Cs2PauseState $fixture).suspended $false
    }

    & {
        . $helper
        $script:taskExit = 0
        $script:taskArgs = @()
        function schtasks.exe {
            param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
            $script:taskArgs += ,$Arguments
            $global:LASTEXITCODE = $script:taskExit
            if ($script:taskExit -ne 0) { "fixture access denied" }
        }
        Set-GodBrainTaskEnabled "GodBrainWatch" $false
        Assert-Equal ($script:taskArgs[-1] -join " ") "/Change /TN GodBrainWatch /DISABLE"
        function Test-GodBrainTaskExists { return $true }
        $script:taskExit = 5
        Assert-Throws { Set-GodBrainTaskEnabled "GodBrainWatch" $false } "*task GodBrainWatch /DISABLE failed*"
        Assert-Equal ((Get-GodBrainCs2PauseTasks) -join ",") "GodBrainWatch,GodBrainLogon,GodBrainCs2Pause,GodBrainGymWatch,GodBrainGymWorker,GodBrainQwen38,GodBrainCreationLab"

        $script:existing = [pscustomobject]@{
            ProcessId = 123; Name = "python.exe"; CommandLine = "fixture"; CreationDate = "original"
        }
        $script:stopped = @()
        $script:existingAlive = $true
        function Get-CimInstance { param($ClassName, $Filter, $ErrorAction)
            if ($script:existingAlive) { return $script:existing }
        }
        function Stop-Process { param($Id, [switch]$Force, $ErrorAction)
            $script:stopped += $Id; $script:existingAlive = $false
        }
        $snapshot = [pscustomobject]@{ ProcessId = 123; CommandLine = "fixture"; CreationDate = "older" }
        Assert-Throws { Stop-Cs2OwnedProcess $snapshot } "*changed identity*"
        Assert-Equal $script:stopped.Count 0
        $snapshot.CreationDate = "original"
        Stop-Cs2OwnedProcess $snapshot
        Assert-Equal ($script:stopped -join ",") "123"

        $script:existing = [pscustomobject]@{
            ProcessId = 456; Name = "pwsh.exe"; CreationDate = "original"
            CommandLine = "pwsh.exe -File `"$repo\Start-GodBrain.ps1`" -Only mouth"
        }
        $script:existingAlive = $true
        function Get-NetTCPConnection { param($State, $ErrorAction); return @() }
        Stop-Cs2GpuRuntimes $repo
        Assert-Equal ($script:stopped -join ",") "123,456"
        $script:existing.CommandLine = "pwsh.exe -File `"$repo\Start-GodBrain.ps1.backup`""
        $script:existingAlive = $true
        Stop-Cs2GpuRuntimes $repo
        Assert-Equal ($script:stopped -join ",") "123,456"
        $script:existing.Name = "python.exe"
        $script:existing.CommandLine = 'python.exe -m http.server 8000 --bind 127.0.0.1'
        function Get-NetTCPConnection { param($State, $ErrorAction); return @{ LocalPort = 8000; OwningProcess = 456 } }
        Stop-Cs2GpuRuntimes $repo
        $script:existing.CommandLine = 'python.exe unknown_model.py --port 8000'
        Assert-Throws { Stop-Cs2GpuRuntimes $repo } "*:8000*unknown listeners are never killed*"
        Assert-Equal ($script:stopped -join ",") "123,456"

        $script:now = [datetime]"2026-01-01T00:00:00Z"
        function Get-CimInstance { param($ClassName, $Filter, $ErrorAction); return @() }
        function Get-NetTCPConnection { param($State, $ErrorAction); return @{ LocalPort = 8888 } }
        function Get-Date { $script:now = $script:now.AddSeconds(30); return $script:now }
        function Start-Sleep { param($Milliseconds) }
        Assert-Throws { Stop-Cs2GpuRuntimes $repo } "*unknown listeners are never killed*"
        Assert-Equal ($script:stopped -join ",") "123,456"
    }

    & {
        . $helper
        $script:census = 0; $script:lateStopped = @()
        $script:lateLauncher = [pscustomobject]@{
            ProcessId = 610; Name = "pwsh.exe"
            CommandLine = 'pwsh.exe -File "C:\nvme\Qwen3.8-27B-16gb\paper-godbrain\Start-Qwen.ps1"'
            CreationDate = Get-Date
        }
        function Get-CimInstance { param($ClassName, $Filter, $ErrorAction)
            $script:census++
            if ($script:census -ge 2 -and $script:lateLauncher) { return $script:lateLauncher }
            return @()
        }
        function Stop-Cs2OwnedProcess { param($process)
            $script:lateStopped += $process.ProcessId
            $script:lateLauncher = $null
        }
        function Get-NetTCPConnection { param($State, $ErrorAction); return @() }
        function Start-Sleep { param($Milliseconds) }
        Stop-Cs2GpuRuntimes $repo
        Assert-Equal ($script:lateStopped -join ",") "610"
    }

    & {
        . $helper
        $fake = Join-Path $fixture "suspend"
        $null = New-Item -ItemType Directory -Path (Join-Path $fake "scripts") -Force
        Copy-Item -LiteralPath (Join-Path $repo "scripts\GodBrain-Mouth.ps1") -Destination (Join-Path $fake "scripts\GodBrain-Mouth.ps1")
        $script:events = @()
        function Suspend-Cs2GymTraining { param($RepoRoot); $script:events += "gym" }
        function Set-GodBrainTaskEnabled {
            param($Name, $Enable)
            if ($Enable) { throw "Suspend may not enable any task." }
            $script:events += "disable:$Name"
        }
        function Stop-Cs2GpuRuntimes {
            param($RepoRoot)
            Assert-Equal (Read-Cs2PauseState $RepoRoot).paused $true
            Assert-Equal ((Get-Content -LiteralPath (Join-Path $RepoRoot "logs\mouth-pause.txt") -Raw).Trim()) "on"
            $script:events += "stop"
        }
        function Set-TailscaleForCs2 {
            param($Up)
            if ($Up) { throw "Suspend may not reconnect Tailscale." }
            $script:events += "tail-down"
        }
        Suspend-GodBrainForCs2 $fake
        Assert-Equal ($script:events -join ",") "gym,disable:GodBrainWatch,disable:GodBrainLogon,disable:GodBrainGymWatch,disable:GodBrainGymWorker,disable:GodBrainQwen38,disable:GodBrainCreationLab,stop,tail-down,disable:GodBrainCs2Pause"
        Assert-Equal (Read-Cs2PauseState $fake).last_action "pause-manual"
        Assert-Equal (Read-Cs2PauseState $fake).suspended $true
        "{broken" | Set-Content -LiteralPath (Get-Cs2PauseStatePath $fake)
        Suspend-GodBrainForCs2 $fake
        Assert-Equal (Read-Cs2PauseState $fake).suspended $true
        $script:events = @()
        function Set-GodBrainTaskEnabled {
            param($Name, $Enable)
            $script:events += "disable:$Name"
            if ($Name -eq "GodBrainWatch") { throw "fixture disable denied" }
        }
        Assert-Throws { Suspend-GodBrainForCs2 $fake } "*incomplete*fixture disable denied*"
        Assert-Equal (Read-Cs2PauseState $fake).paused $true
        Assert-Equal (Read-Cs2PauseState $fake).suspended $false
        Assert-Equal ($script:events -contains "stop") $true
        Assert-Equal ($script:events -contains "tail-down") $true
        Assert-Equal ($script:events -contains "disable:GodBrainCs2Pause") $false
        function Set-GodBrainTaskEnabled {
            param($Name, $Enable)
            $script:events += "disable:$Name"
        }
        function Stop-Cs2GpuRuntimes { param($RepoRoot); throw "fixture GPU remains" }
        $script:events = @()
        Assert-Throws { Suspend-GodBrainForCs2 $fake } "*incomplete*GPU remains*"
        Assert-Equal (Read-Cs2PauseState $fake).suspended $false
        Assert-Equal ($script:events -contains "disable:GodBrainCs2Pause") $false
        function Stop-Cs2GpuRuntimes { param($RepoRoot); $script:events += "stop" }
        function Set-TailscaleForCs2 { param($Up); throw "fixture tail failed" }
        Assert-Throws { Suspend-GodBrainForCs2 $fake } "*incomplete*tail failed*"
        Assert-Equal (Read-Cs2PauseState $fake).suspended $false
        function Set-TailscaleForCs2 { param($Up); $script:events += "tail-down" }
        function Set-GodBrainTaskEnabled {
            param($Name, $Enable)
            if ($Name -eq "GodBrainCs2Pause") {
                Assert-Equal (Read-Cs2PauseState $fake).suspended $true
                throw "fixture backup disable failed"
            }
        }
        Assert-Throws { Suspend-GodBrainForCs2 $fake } "*incomplete*backup disable failed*"
        Assert-Equal (Read-Cs2PauseState $fake).suspended $false
        function Set-GodBrainTaskEnabled { param($Name, $Enable); $script:events += "disable:$Name" }
        $watchAst = Read-TestAst (Join-Path $repo "Watch-Cs2Pause.ps1")
        $shutdown = $watchAst.EndBlock.Statements | Where-Object { $_.Extent.Text.StartsWith('if ($cs2)') }
        # Run the real backup branch without its process-level exit.
        $branch = [scriptblock]::Create(($shutdown.Extent.Text -replace '\bexit 0\b', 'return'))
        $cs2 = $true
        $RepoRoot = $fake
        . $branch
        Assert-Equal (Read-Cs2PauseState $fake).suspended $true
        $script:events = @()
        . $branch
        Assert-Equal $script:events.Count 0
        "{broken" | Set-Content -LiteralPath (Get-Cs2PauseStatePath $fake)
        . $branch
        Assert-Equal (Read-Cs2PauseState $fake).suspended $true
    }

    & {
        $fake = Join-Path $fixture "launcher with spaces"
        $null = New-Item -ItemType Directory -Path $fake
        $fakeHelper = Join-Path $fake "GodBrain-Cs2.ps1"
        @'
function Suspend-GodBrainForCs2($RepoRoot) {
    $global:Cs2TestControl.events.Add("pause")
    if ($global:Cs2TestControl.pauseFails) { throw "fixture pause failed" }
}
function Test-Cs2Running { return $global:Cs2TestControl.gameRunning }
function Read-Cs2PauseState($RepoRoot) {
    return @{paused=$true;suspended=$true;last_seen="2000-01-01T00:00:00Z"}
}
function Start-Process {
    param($FilePath, $ArgumentList)
    $global:Cs2TestControl.events.Add("$FilePath / $($ArgumentList -join ' ')")
}
function Resume-GodBrainAfterCs2 { throw "Automatic resume is forbidden." }
'@ | Set-Content -LiteralPath $fakeHelper
        $steam = Join-Path $fake "steam fixture.exe"
        "" | Set-Content -LiteralPath $steam
        $global:Cs2TestControl = @{
            gameRunning = $false; pauseFails = $false
            events = [System.Collections.Generic.List[string]]::new()
        }
        & (Join-Path $repo "Start-CS2.ps1") -RepoRoot $fake -SteamExe $steam
        Assert-Equal ($global:Cs2TestControl.events -join ",") "pause,$steam / -applaunch 730"
        $global:Cs2TestControl.events.Clear()
        $global:Cs2TestControl.gameRunning = $true
        & (Join-Path $repo "Start-CS2.ps1") -RepoRoot $fake -SteamExe $steam
        Assert-Equal ($global:Cs2TestControl.events -join ",") "pause"
        $global:Cs2TestControl.gameRunning = $false
        $global:Cs2TestControl.pauseFails = $true
        $global:Cs2TestControl.events.Clear()
        Assert-Throws { & (Join-Path $repo "Start-CS2.ps1") -RepoRoot $fake -SteamExe $steam } "*pause failed*"
        Assert-Equal ($global:Cs2TestControl.events -join ",") "pause"
        $global:Cs2TestControl.events.Clear()
        Assert-Throws { & (Join-Path $repo "Start-CS2.ps1") -RepoRoot $fake -SteamExe "$fake\missing.exe" } "*Steam not at*"
        Assert-Equal $global:Cs2TestControl.events.Count 0
        & (Join-Path $repo "Watch-Cs2Pause.ps1") -RepoRoot $fake
        Assert-Equal $global:Cs2TestControl.events.Count 0
    }

    $install = Read-TestAst (Join-Path $repo "Install-GodBrainWatch.ps1")
    $settings = $install.EndBlock.Statements | Where-Object { $_.Extent.Text -like '$settings.Enabled =*' }
    if (@($settings).Count -ne 1) { throw "Watch installer must set its explicit enable state." }
    foreach ($Enable in @($false, $true)) {
        $settings = @{ Enabled = $true }
        $assignment = $install.EndBlock.Statements | Where-Object { $_.Extent.Text -like '$settings.Enabled =*' }
        . ([scriptblock]::Create($assignment.Extent.Text))
        Assert-Equal $settings.Enabled $Enable
    }
    $cmd = Get-Content -LiteralPath (Join-Path $repo "Start-CS2.cmd") -Raw
    if ($cmd -notmatch 'C:\\pwsh\\pwsh\.exe' -or $cmd -match 'start llama|10 minutes') {
        throw "The cmd door still advertises the legacy resume flow."
    }
    $desk = Read-TestAst (Join-Path $repo "scripts\Show-DeskMenu.ps1")
    & {
        . $helper
        $script:tailState = "Stopped"; $script:tailArgs = @()
        function Get-TailscaleExe { return "fixture-tailscale.exe" }
        function Get-Service { param($Name, $ErrorAction); return @{ Status = $script:tailState } }
        function Invoke-TailscaleCs2 { param($Exe, $TsArgs); $script:tailArgs += ,$TsArgs }
        Set-TailscaleForCs2 $false
        Assert-Equal $script:tailArgs.Count 0
        $script:tailState = "Running"
        Set-TailscaleForCs2 $false
        Assert-Equal ($script:tailArgs[0] -join ",") "down"
    }
    $tail = $desk.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Start-TailscaleDesk"
    }, $true)
    & {
        . ([scriptblock]::Create($tail.Extent.Text))
        $script:tailCalls = @()
        function Set-HostService { param($Name, $Action); $script:tailCalls += "$Name/$Action" }
        function Get-ServiceWord { param($Name); return "running" }
        function Set-TailscaleForCs2 { param($Up); $script:tailCalls += "reconnect:$Up" }
        function Update-Status {}
        Start-TailscaleDesk
        Assert-Equal ($script:tailCalls -join ",") "Tailscale/start,reconnect:True"
    }
    Write-Output "PASS: CS2 manual launch/hold, model identity, task failure, gym pause and Tailscale routing."
} finally {
    Remove-Variable -Name Cs2TestControl -Scope Global -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
