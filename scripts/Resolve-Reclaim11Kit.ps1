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
