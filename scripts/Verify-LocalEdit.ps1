# Bounded post-/edit checks. Not a skill gym. Apply-only cannot promote.
# Keep profile names in sync with local_edit.cpp check_profile_for.
#
#   .\scripts\Verify-LocalEdit.ps1 -RepoRoot . -Path scripts\Show-SystemFlex.ps1
#   .\scripts\Verify-LocalEdit.ps1 -SelfTest

[CmdletBinding()]
param(
    [string]$RepoRoot = "",
    [string[]]$Path = @(),
    [string]$PathList = "",
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
if ($PSScriptRoot -and -not $RepoRoot) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    throw "Verify-LocalEdit: RepoRoot is empty"
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)

function Split-EditPathList([string]$List) {
    if ([string]::IsNullOrWhiteSpace($List)) { return @() }
    return @($List -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-EditCheckProfile([string]$Rel) {
    $n = $Rel.Replace('/', '\').ToLowerInvariant().TrimStart('\')
    if ($n -eq 'godbrain_core\frontend\galaxy.html') { return 'galaxy-html-static-v1' }
    if ($n.StartsWith('godbrain_core\memory_store\') -and $n.EndsWith('.go')) {
        return 'memory-store-go-v1'
    }
    if ($n -eq 'godbrain_core\cpp_tools\librarian.cpp') { return 'librarian-self-test-v1' }
    if ($n.StartsWith('godbrain_core\cpp_kernel\') -and
        ($n.EndsWith('.cpp') -or $n.EndsWith('.h'))) {
        return 'kernel-file-v1'
    }
    if ($n.EndsWith('.ps1')) { return 'powershell-parse-v1' }
    return 'local-edit-apply-v1'
}

function Test-RepoRel([string]$Rel) {
    if ([string]::IsNullOrWhiteSpace($Rel)) { throw "empty path" }
    if ($Rel.Contains('..') -or $Rel.Contains(':')) { throw "path not allowlisted: $Rel" }
    $full = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $Rel))
    $root = $RepoRoot.TrimEnd('\') + '\'
    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -and
        $full -ne $RepoRoot) {
        throw "path escaped repo: $Rel"
    }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "missing $Rel"
    }
    return $full
}

function Test-PowerShellParse([string]$Full) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Full, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        throw ("parse failed: " + $errors[0].ToString())
    }
}

function Test-KernelFile([string]$Full) {
    $bytes = [System.IO.File]::ReadAllBytes($Full)
    if ($bytes.Length -lt 1) { throw "empty kernel file" }
    if ($bytes -contains 0) { throw "NUL byte in kernel file" }
}

function Test-GalaxyHtml([string]$Full) {
    $text = [System.IO.File]::ReadAllText($Full)
    if ($text.Length -lt 200) { throw "galaxy.html too short" }
    if ($text -notmatch '(?i)<html') { throw "galaxy.html missing html" }
    if ($text -notmatch '(?i)godbrain') { throw "galaxy.html missing GodBrain" }
    if ($text -notmatch '(?i)3d-graph') { throw "galaxy.html missing graph root" }
    if ($text -notmatch 'id\s*=\s*(["''])host-card\1') { throw "galaxy.html missing host card" }
    if ($text -notmatch 'CS2:\s*idle') { throw "galaxy.html missing CS2 idle glance" }
    if ($text -notmatch 'Heal:\s*none') { throw "galaxy.html missing Heal glance" }
    if ($text -notmatch 'Inbox:\s*none') { throw "galaxy.html missing Inbox glance" }
    if ($text -notmatch 'GPU:\s*none') { throw "galaxy.html missing GPU glance" }
    if ($text -notmatch 'Judge:\s*none') { throw "galaxy.html missing Judge glance" }
}

function Test-MemoryStoreGo {
    $mod = Join-Path $RepoRoot "godbrain_core\memory_store"
    if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
        throw "go is not on PATH"
    }
    Push-Location $mod
    try {
        & go test -count=1 -short -timeout 45s ./...
        if ($LASTEXITCODE -ne 0) { throw "go test failed: $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
}

function Test-LibrarianSelfTest {
    $exe = Join-Path $RepoRoot "godbrain_core\cpp_tools\librarian.exe"
    if (-not (Test-Path -LiteralPath $exe)) { throw "missing librarian.exe" }
    & $exe --self-test
    if ($LASTEXITCODE -ne 0) { throw "librarian --self-test failed: $LASTEXITCODE" }
}

function Invoke-EditChecks([string[]]$Rels) {
    $profiles = New-Object System.Collections.Generic.List[string]
    foreach ($rel in $Rels) {
        $full = Test-RepoRel $rel
        $profile = Get-EditCheckProfile $rel
        if (-not $profiles.Contains($profile)) { $profiles.Add($profile) }
        switch ($profile) {
            'powershell-parse-v1' { Test-PowerShellParse $full }
            'kernel-file-v1' { Test-KernelFile $full }
            'galaxy-html-static-v1' { Test-GalaxyHtml $full }
            'memory-store-go-v1' { }
            'librarian-self-test-v1' { }
            'local-edit-apply-v1' { }
            default { throw "unknown profile $profile" }
        }
    }
    if ($profiles -contains 'memory-store-go-v1') { Test-MemoryStoreGo }
    if ($profiles -contains 'librarian-self-test-v1') { Test-LibrarianSelfTest }
    $joined = [string]::Join('+', $profiles)
    return @{ ok = $true; profile = $joined; detail = 'check passed' }
}

if ($SelfTest) {
    if ((Get-EditCheckProfile 'scripts\Show-SystemFlex.ps1') -ne 'powershell-parse-v1') {
        throw "classify ps1"
    }
    if ((Get-EditCheckProfile 'godbrain_core\cpp_kernel\main.cpp') -ne 'kernel-file-v1') {
        throw "classify kernel"
    }
    if ((Get-EditCheckProfile 'godbrain_core\memory_store\store.go') -ne 'memory-store-go-v1') {
        throw "classify go"
    }
    if ((Get-EditCheckProfile 'godbrain_core\frontend\galaxy.html') -ne 'galaxy-html-static-v1') {
        throw "classify galaxy"
    }
    if ((Get-EditCheckProfile 'godbrain_core\cpp_tools\librarian.cpp') -ne 'librarian-self-test-v1') {
        throw "classify librarian"
    }
    if ((Get-EditCheckProfile 'docs\architecture\current.md') -ne 'local-edit-apply-v1') {
        throw "classify md"
    }
    $tmp = Join-Path $env:TEMP ("gb-edit-" + [guid]::NewGuid().ToString("n") + ".ps1")
    Set-Content -LiteralPath $tmp -Value 'Write-Output 1' -Encoding UTF8
    try { Test-PowerShellParse $tmp } finally { Remove-Item -LiteralPath $tmp -Force }
    $bad = Join-Path $env:TEMP ("gb-edit-bad-" + [guid]::NewGuid().ToString("n") + ".ps1")
    Set-Content -LiteralPath $bad -Value 'function (' -Encoding UTF8
    $threw = $false
    try { Test-PowerShellParse $bad } catch { $threw = $true }
    Remove-Item -LiteralPath $bad -Force
    if (-not $threw) { throw "broken ps1 must fail parse" }
    Test-GalaxyHtml (Join-Path $RepoRoot "godbrain_core\frontend\galaxy.html")
    $alt = "id = 'host-card'`nCS2:idle`nHeal: none`nInbox:none"
    if ($alt -notmatch 'id\s*=\s*(["''])host-card\1') { throw "host-card single quote" }
    if ($alt -notmatch 'CS2:\s*idle') { throw "cs2 whitespace" }
    if ($alt -notmatch 'Heal:\s*none') { throw "heal whitespace" }
    if ($alt -notmatch 'Inbox:\s*none') { throw "inbox whitespace" }
    $alt += "`nGPU:none`nJudge:none"
    if ($alt -notmatch 'GPU:\s*none') { throw "gpu whitespace" }
    if ($alt -notmatch 'Judge:\s*none') { throw "judge whitespace" }
    $listed = Invoke-EditChecks @('README.md','AGENTS.md')
    if ($listed.profile -ne 'local-edit-apply-v1') { throw "pathlist classify" }
    $split = Split-EditPathList ' README.md ; AGENTS.md ; '
    if ($split.Count -ne 2 -or $split[0] -ne 'README.md' -or $split[1] -ne 'AGENTS.md') {
        throw "pathlist split"
    }
    $hostExe = (Get-Process -Id $PID).Path
    $child = & $hostExe -NoProfile -File $PSCommandPath -RepoRoot $RepoRoot -PathList 'README.md;AGENTS.md'
    if ($LASTEXITCODE -ne 0) { throw "pathlist child failed: $child" }
    $childObj = $child | Select-Object -Last 1 | ConvertFrom-Json
    if (-not $childObj.ok) { throw "pathlist child not ok" }
    Write-Output '{"ok":true,"profile":"self-test","detail":"self-test ok"}'
    exit 0
}

$rels = @()
$rels += Split-EditPathList $PathList
if ($Path) { $rels += @($Path) }
if ($rels.Count -lt 1) {
    throw "Verify-LocalEdit: pass -Path or -PathList"
}
try {
    $result = Invoke-EditChecks $rels
    $payload = @{
        ok      = [bool]$result.ok
        profile = [string]$result.profile
        detail  = [string]$result.detail
    } | ConvertTo-Json -Compress
    Write-Output $payload
    exit 0
} catch {
    $err = $_.Exception.Message
    if ([string]::IsNullOrWhiteSpace($err)) { $err = "$_" }
    $payload = @{
        ok      = $false
        profile = 'local-edit-apply-v1'
        detail  = $err
    } | ConvertTo-Json -Compress
    Write-Output $payload
    exit 1
}
