# Jarvis loop score. Default is no GPU (tools + hop + edit + browser evidence).
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
function Invoke-KernelTest([string]$Name, [string]$ExeName) {
    $exe = Join-Path $kernelDir $ExeName
    if (-not (Test-Path -LiteralPath $exe)) {
        Add-Task $Name $false 0 "missing $exe (build it)"
        return
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $exe -WorkingDirectory $kernelDir -Wait -PassThru -NoNewWindow
    $sw.Stop()
    Add-Task $Name ($p.ExitCode -eq 0) $sw.ElapsedMilliseconds $(
        if ($p.ExitCode -eq 0) { "ok" } else { "exit $($p.ExitCode)" }
    )
}
Invoke-KernelTest "local_tools_test" "local_tools_test.exe"
Invoke-KernelTest "tool_round_test" "tool_round_test.exe"
Invoke-KernelTest "local_edit_test" "local_edit_test.exe"
Invoke-KernelTest "browser_evidence_test" "browser_evidence_test.exe"
Invoke-KernelTest "unused49_test" "unused49_test.exe"

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
