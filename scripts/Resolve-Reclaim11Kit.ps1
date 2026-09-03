# Sets $RepoRoot and $Reclaim11Root from a GodBrain checkout or a standalone kit zip.
# Kit zip has catalog.json at the root. Repo has Start-GodBrain.ps1 and godbrain_core\reclaim11.

function Get-Reclaim11KitLayout {
    param([string]$Start = "")
    if ([string]::IsNullOrWhiteSpace($Start)) {
        if ($PSScriptRoot) { $Start = $PSScriptRoot }
        elseif ($MyInvocation.MyCommand.Path) { $Start = Split-Path -Parent $MyInvocation.MyCommand.Path }
    }
    if ([string]::IsNullOrWhiteSpace($Start)) {
        throw "Get-Reclaim11KitLayout: no start path"
    }
    $d = [IO.Path]::GetFullPath($Start)
    for ($i = 0; $i -lt 6; $i++) {
        $gb = Join-Path $d "Start-GodBrain.ps1"
        $kitInRepo = Join-Path $d "godbrain_core\reclaim11\catalog.json"
        if ((Test-Path -LiteralPath $gb) -and (Test-Path -LiteralPath $kitInRepo)) {
            return [pscustomobject]@{
                RepoRoot = $d
                Kit      = (Join-Path $d "godbrain_core\reclaim11")
            }
        }
        $cat = Join-Path $d "catalog.json"
        if (Test-Path -LiteralPath $cat) {
            return [pscustomobject]@{
                RepoRoot = $d
                Kit      = $d
            }
        }
        $parent = Split-Path $d
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $d) { break }
        $d = $parent
    }
    throw "Get-Reclaim11KitLayout: catalog.json not found from $Start"
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = $PSScriptRoot
}
$script:Reclaim11Layout = Get-Reclaim11KitLayout -Start $RepoRoot
$RepoRoot = $script:Reclaim11Layout.RepoRoot
$Reclaim11Root = $script:Reclaim11Layout.Kit

function Get-Reclaim11IsoStub {
    param(
        [string]$Preferred = "C:\Reclaim11\reclaim11-stub.exe"
    )
    if (Test-Path -LiteralPath $Preferred) {
        $fs = [IO.File]::OpenRead($Preferred)
        try {
            $b = New-Object byte[] 2
            $n = $fs.Read($b, 0, 2)
            if ($n -eq 2 -and $b[0] -eq 0x4D -and $b[1] -eq 0x5A) { return $Preferred }
        } finally { $fs.Close() }
        throw "Get-Reclaim11IsoStub: $Preferred exists but is not MZ (refusing a renamed .cmd)"
    }
    $src = Join-Path $Reclaim11Root "winpe\stub.c"
    if (-not (Test-Path -LiteralPath $src)) {
        throw "Get-Reclaim11IsoStub: missing $src and $Preferred. Build the WinPE ISO first."
    }
    $outDir = Split-Path -Parent $Preferred
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Path $outDir | Out-Null
    }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path -LiteralPath $vswhere)) {
        throw "Get-Reclaim11IsoStub: missing $Preferred and vswhere. Build the WinPE ISO first, or install VS C++ tools."
    }
    $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    $vcvars = Join-Path $vsPath "VC\Auxiliary\Build\vcvars64.bat"
    $cmd = "cl /nologo /O2 /GS- /c `"$src`" /Fo`"$outDir\stub.obj`" && link /nologo /OUT:`"$Preferred`" /ENTRY:mainCRTStartup /SUBSYSTEM:WINDOWS /NODEFAULTLIB kernel32.lib `"$outDir\stub.obj`""
    cmd.exe /c "call `"$vcvars`" >nul && $cmd"
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $Preferred)) {
        throw "Get-Reclaim11IsoStub: stub compile failed. Build the WinPE ISO first, or install VS C++ tools."
    }
    $Preferred
}
