# Gym harness for godbrain_core/skill_lab. Off the GPU. Not Galaxy.
# npm ci + npm run build + README gate, then optional record_skill_run.
# A green build with no doc is a fail. Apply-only /edit cannot promote.

[CmdletBinding()]
param(
    [string]$RepoRoot = $PSScriptRoot,
    [string]$Profile = "frontend-spa-v1",
    [string]$Fixture = "dashboard-shell-v1",
    [string]$SkillName = "build-dashboard-shell",
    [string]$OriginNodeID = "",
    [string]$Reasoning = "skill lab npm run build",
    [switch]$Record
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Resolve-GodBrainRoot.ps1")

$allowed = @("frontend-spa-v1", "frontend-nextjs-v1")
if ($allowed -notcontains $Profile) {
    throw "Verify-SkillLab: profile $Profile is not a lab harness"
}
if ($Profile -eq "frontend-nextjs-v1") {
    throw "Verify-SkillLab: frontend-nextjs-v1 is reserved; v1 gym is frontend-spa-v1"
}

$fixtureDir = Join-Path $RepoRoot "godbrain_core\skill_lab\fixtures\$Fixture"
if (-not (Test-Path -LiteralPath (Join-Path $fixtureDir "package.json"))) {
    throw "Verify-SkillLab: missing fixture $fixtureDir"
}

function Test-FixtureReadme([string]$Dir) {
    $readme = Join-Path $Dir "README.md"
    if (-not (Test-Path -LiteralPath $readme)) {
        throw "Verify-SkillLab: missing README.md (build without docs is a fail)"
    }
    $text = Get-Content -LiteralPath $readme -Raw -ErrorAction Stop
    if ($null -eq $text -or $text.Trim().Length -lt 200) {
        throw "Verify-SkillLab: README.md is too short"
    }
    $needles = @("Brief", "Stack", "Run", "Check", "Not Galaxy", "frontend-spa-v1")
    foreach ($needle in $needles) {
        if ($text.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            throw "Verify-SkillLab: README.md missing section or marker '$needle'"
        }
    }
}

$npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
if (-not $npm) { $npm = Get-Command npm -ErrorAction SilentlyContinue }
if (-not $npm) { throw "Verify-SkillLab: npm is not on PATH" }

$logDir = Join-Path $RepoRoot "logs"
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}

function Invoke-Npm([string[]]$NpmArgs) {
    $p = Start-Process -FilePath $npm.Source -ArgumentList $NpmArgs -WorkingDirectory $fixtureDir `
        -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) {
        throw "npm $($NpmArgs -join ' ') exited $($p.ExitCode)"
    }
}

$result = "passed"
$err = ""
$doc = "failed"
$build = "failed"
try {
    Test-FixtureReadme $fixtureDir
    $doc = "passed"
    if (Test-Path -LiteralPath (Join-Path $fixtureDir "package-lock.json")) {
        Invoke-Npm @("ci", "--no-audit", "--no-fund")
    } else {
        Invoke-Npm @("install", "--no-audit", "--no-fund")
    }
    Invoke-Npm @("run", "build")
    $build = "passed"
} catch {
    $result = "failed"
    $err = "$_"
}

$report = [ordered]@{
    profile                 = $Profile
    fixture                 = $Fixture
    skill_name              = $SkillName
    verification_profile    = $Profile
    result                  = $result
    checks                  = @{ build = $build; docs = $doc }
    skill_promote_eligible  = ($result -eq "passed")
    error                   = $err
    recorded                = $false
    at                      = [DateTime]::UtcNow.ToString("o")
}

if ($Record) {
    if ([string]::IsNullOrWhiteSpace($OriginNodeID)) {
        throw "Verify-SkillLab -Record needs -OriginNodeID (the candidate skill node)"
    }
    $store = Join-Path $RepoRoot "godbrain_core\memory_store\memory-store.exe"
    if (-not (Test-Path -LiteralPath $store)) {
        throw "Verify-SkillLab: missing $store"
    }
    $payload = @{
        command               = "record_skill_run"
        skill_name            = $SkillName
        origin_node_id        = $OriginNodeID
        fixture_id            = $Fixture
        verification_profile  = $Profile
        result                = $result
        checks                = @{ build = $build; docs = $doc }
        reasoning             = $Reasoning
    } | ConvertTo-Json -Compress
    $payload | & $store | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Verify-SkillLab: memory-store record_skill_run failed"
    }
    $report.recorded = $true
}

$reportPath = Join-Path $logDir "last-skill-lab.json"
$report | ConvertTo-Json | Set-Content -LiteralPath $reportPath -Encoding utf8
Write-Host ("Verify-SkillLab {0} fixture={1} result={2}" -f $Profile, $Fixture, $result)
if ($result -ne "passed") { exit 1 }
