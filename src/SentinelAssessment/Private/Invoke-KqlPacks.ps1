function Invoke-KqlPacks {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][Guid]$WorkspaceCustomerId,
    [Parameter(Mandatory=$true)][string]$RepoRoot,
    [Parameter(Mandatory=$true)][string]$OutDir,

    [string[]]$IncludePacks,
    [string[]]$ExcludePacks,
    [switch]$DefaultsOnly,
    [switch]$ProbeTables,
    [int]$ProbeDays = 1
  )

  $packsRoot = Join-Path $RepoRoot "kql/packs"
  if (-not (Test-Path $packsRoot)) {
    Write-Host "[INFO] No KQL packs folder found at $packsRoot" -ForegroundColor Yellow
    return
  }

  $manifestFiles = Get-ChildItem -Path $packsRoot -Recurse -Filter manifest.json -File
  foreach ($mf in $manifestFiles) {
    $packPath = $mf.Directory.FullName
    $manifest = Get-Content $mf.FullName -Raw | ConvertFrom-Json
    $packId = [string]$manifest.packId

    if ($IncludePacks -and ($IncludePacks -notcontains $packId)) { continue }
    if ($ExcludePacks -and ($ExcludePacks -contains $packId)) { continue }
    if ($DefaultsOnly -and (-not [bool]$manifest.default)) { continue }

    Invoke-KqlPack `
      -WorkspaceCustomerId $WorkspaceCustomerId `
      -PackPath $packPath `
      -OutDir $OutDir `
      -ProbeTables:$ProbeTables `
      -ProbeDays $ProbeDays
  }
}
