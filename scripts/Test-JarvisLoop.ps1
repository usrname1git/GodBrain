# Jarvis loop score. Default is no GPU (tools + hop + edit + browser evidence).
# Each offline test is compiled from the current sources. Objects go to
# %TEMP%. The exe runs from cpp_kernel so repo_root() is this repo, then
# the exe is removed. A leftover exe is not the score.
# -LiveMouth is the shredder gauntlet: a small prompt must get a real reply.
# -LiveJarvis is the analysis ask (one GPU slot, ~10s).
#
#   .\scripts\Test-JarvisLoop.ps1
#   .\scripts\Test-JarvisLoop.ps1 -LiveMouth
#   .\scripts\Test-JarvisLoop.ps1 -LiveMouth -LiveJarvis
#
# Score is verified completion, not eloquence. Fail on dir dump, unused49,
# CUDA abort, raw tool_call tags, or empty "No response." Offline cases
# also prove hop-2 still advertises tools and a missing edit verifier
# rolls the write back.

[CmdletBinding()]
param(
    [string]$RepoRoot = $PSScriptRoot,
    [string]$Base = "http://127.0.0.1:8083",
    [switch]$LiveMouth,
    [switch]$LiveJarvis
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Resolve-GodBrainRoot.ps1")

$fails = [System.Collections.Generic.List[string]]::new()
$tasks = [System.Collections.Generic.List[object]]::new()

function Add-Task([string]$Name, [bool]$Ok, [int]$Ms, [string]$Note) {
    $tasks.Add([pscustomobject]@{
        name = $Name
        ok   = $Ok
        ms   = $Ms
        note = $Note
    })
    if (-not $Ok) { $fails.Add("$Name : $Note") }
}

function Test-BadReply([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return "empty" }
    if ($Text -match 'CUDA abort') { return "cuda-abort" }
    if ($Text -match 'unused49') { return "unused49" }
    if ($Text -match '(?i)no response') { return "no-response" }
    if ($Text -match '<\|tool_call\|>' -or $Text -match '(?m)^(?:github_)?tool_call') {
        return "tool-call-tags"
    }
    if ($Text -match '(?m)^list_local_dir ') { return "dir-dump" }
    if ($Text -match 'Ask again in about a minute') { return "ask-again" }
    return $null
}

$kernelDir = Join-Path $RepoRoot "godbrain_core\cpp_kernel"

function Get-ClPrefix([string]$TaskName) {
    if (Get-Command cl.exe -ErrorAction SilentlyContinue) {
        return ""
    }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path -LiteralPath $vswhere)) {
        Add-Task $TaskName $false 0 "cl.exe is not on PATH"
        return $null
    }
    $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ([string]::IsNullOrWhiteSpace($vsPath)) {
        Add-Task $TaskName $false 0 "Visual Studio x64 tools were not found"
        return $null
    }
    $vcvars = Join-Path $vsPath "VC\Auxiliary\Build\vcvars64.bat"
    return "call `"$vcvars`" >nul && "
}

function Invoke-CompiledTest([string]$Name, [string[]]$Sources) {
    $objDir = Join-Path $env:TEMP ("GodBrain-" + $Name)
    if (-not (Test-Path -LiteralPath $objDir)) {
        New-Item -ItemType Directory -Path $objDir | Out-Null
    }
    $prefix = Get-ClPrefix $Name
    if ($null -eq $prefix) { return }
    $quoted = @(foreach ($src in $Sources) {
        '"' + (Join-Path $kernelDir $src) + '"'
    })
    # repo_root() is two directories above the module. local_edit writes its
    # fixture beside the exe and applies godbrain_core\cpp_kernel\<file>.
    # The exe therefore runs from cpp_kernel, then this function removes it.
    $exe = Join-Path $kernelDir ($Name + ".exe")
    $fixture = Join-Path $kernelDir "local_edit_fixture.txt"
    $savedFixture = $null
    if ($Name -eq "local_edit_test" -and (Test-Path -LiteralPath $fixture)) {
        $savedFixture = [System.IO.File]::ReadAllBytes($fixture)
    }
    $command = $prefix + "cl /nologo /std:c++17 /EHsc /W4 /Fo`"$objDir\\`" /Fe:`"$exe`" " + ($quoted -join " ")
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        & (Join-Path $env:SystemRoot "System32\cmd.exe") /c $command
        if ($LASTEXITCODE -ne 0) {
            $sw.Stop()
            Add-Task $Name $false $sw.ElapsedMilliseconds "compile exit $LASTEXITCODE"
            return
        }
        $p = Start-Process -FilePath $exe -WorkingDirectory $kernelDir -Wait -PassThru -NoNewWindow
        $sw.Stop()
        Add-Task $Name ($p.ExitCode -eq 0) $sw.ElapsedMilliseconds $(
            if ($p.ExitCode -eq 0) { "ok" } else { "exit $($p.ExitCode)" }
        )
    } finally {
        Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue
        foreach ($ext in @(".ilk", ".pdb")) {
            $side = [System.IO.Path]::ChangeExtension($exe, $ext)
            Remove-Item -LiteralPath $side -Force -ErrorAction SilentlyContinue
        }
        if ($null -ne $savedFixture) {
            [System.IO.File]::WriteAllBytes($fixture, $savedFixture)
        }
    }
}

Invoke-CompiledTest "surgery_outcome_test" @("surgery_outcome_test.cpp", "surgery.cpp")
Invoke-CompiledTest "jarvis_job_test" @("jarvis_job_test.cpp", "jarvis_job.cpp")
Invoke-CompiledTest "mouth_select_test" @("mouth_select_test.cpp")
Invoke-CompiledTest "local_tools_test" @("local_tools_test.cpp", "local_tools.cpp")
Invoke-CompiledTest "tool_round_test" @("tool_round_test.cpp")
Invoke-CompiledTest "local_edit_test" @("local_edit_test.cpp", "local_edit.cpp")
Invoke-CompiledTest "browser_evidence_test" @("browser_evidence_test.cpp")
Invoke-CompiledTest "unused49_test" @("unused49_test.cpp")

if ($LiveMouth) {
    $ask = Join-Path $RepoRoot "scripts\Ask-GodBrain.ps1"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $out = & $ask -Base $Base "No tools. What is 2+2?"
        $sw.Stop()
        $bad = Test-BadReply ([string]$out)
        $ok = (-not $bad) -and ([string]$out -match '4')
        Add-Task "small-prompt-2+2" $ok $sw.ElapsedMilliseconds $(
            if ($ok) { "ok" } elseif ($bad) { $bad } else { "no 4 in: $out" }
        )
    } catch {
        $sw.Stop()
        Add-Task "small-prompt-2+2" $false $sw.ElapsedMilliseconds "$_"
    }
}

if ($LiveJarvis) {
    $ask = Join-Path $RepoRoot "scripts\Ask-GodBrain.ps1"
    $q = "Can you find anything apparent in $RepoRoot repo that needs fixing for you to become Jarvis?"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $out = & $ask -Base $Base $q
        $sw.Stop()
        $text = [string]$out
        $bad = Test-BadReply $text
        $writeup = ($text -match 'Repo map') -or ($text -match 'Leftovers')
        $named = ($text -match 'copilot-instructions') -or ($text -match 'temp_hermes')
        $ok = (-not $bad) -and $writeup -and $named -and ($text.Length -gt 800)
        Add-Task "jarvis-repo-ask" $ok $sw.ElapsedMilliseconds $(
            if ($ok) { "ok bytes=$($text.Length)" }
            elseif ($bad) { $bad }
            else { "truncated bytes=$($text.Length)" }
        )
    } catch {
        $sw.Stop()
        Add-Task "jarvis-repo-ask" $false $sw.ElapsedMilliseconds "$_"
    }
}

$completed = @($tasks | Where-Object { $_.ok }).Count
$result = [ordered]@{
    at         = (Get-Date).ToUniversalTime().ToString("o")
    ok         = ($fails.Count -eq 0)
    completed  = $completed
    total      = $tasks.Count
    rate       = $(if ($tasks.Count -gt 0) { [math]::Round($completed / $tasks.Count, 2) } else { 0 })
    live_mouth = [bool]$LiveMouth
    live_jarvis = [bool]$LiveJarvis
    tasks      = @($tasks)
    fails      = @($fails)
}
$logDir = Join-Path $RepoRoot "logs"
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}
$outFile = Join-Path $logDir "last-jarvis-loop.json"
$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($outFile, ($result | ConvertTo-Json -Depth 6 -Compress), $utf8)

if ($fails.Count -gt 0) {
    Write-Host ("jarvis-loop FAIL rate={0} {1}" -f $result.rate, ($fails -join "; "))
    exit 1
}
Write-Host ("jarvis-loop ok rate={0} completed={1}/{2}" -f $result.rate, $completed, $tasks.Count)
exit 0
