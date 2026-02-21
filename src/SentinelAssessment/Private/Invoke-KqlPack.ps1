function Invoke-KqlPack {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][Guid]$WorkspaceCustomerId,
    [Parameter(Mandatory=$true)][string]$PackPath,     # folder containing manifest.json + .kql files
    [Parameter(Mandatory=$true)][string]$OutDir,
    [int]$LookbackDaysOverride,
    [switch]$ProbeTables,                              # if set, will probe available tables once
    [int]$ProbeDays = 1,
    [int]$MaxQueries = 999
  )

  Set-StrictMode -Version Latest
  $ErrorActionPreference = "Stop"

  function Write-Info($m){ Write-Host "[INFO] $m" -ForegroundColor Cyan }

  # ---- local helpers ----
  function Safe-Array($x) {
  if ($null -eq $x) { return @() }
  return @($x)
  }

  function Safe-Count($x) {
  return (Safe-Array $x).Count
  }
  
  function Get-AvailableTablesLocal {
    param([Guid]$WorkspaceCustomerId, [int]$Days)

    $q = @"
search *
| where TimeGenerated > ago(${Days}d)
| summarize by `$table
| take 5000
"@

    $res = Try-RunLaQuery -WorkspaceCustomerId $WorkspaceCustomerId -Query $q -Days $Days
    if (-not $res.Success) {
      return @{ Success=$false; Error=$res.Error; Tables=@() }
    }

    $tables = @()
    foreach ($row in (As-Array $res.Results)) {
      if ($row.PSObject.Properties.Name -contains '$table') { $tables += [string]$row.'$table' }
      elseif ($row.PSObject.Properties.Name -contains 'table') { $tables += [string]$row.table }
    }

    @{ Success=$true; Error=$null; Tables=($tables | Where-Object { $_ } | Sort-Object -Unique) }
  }

  function Missing-Tables {
    param([string[]]$Deps, [string[]]$Available)
    $missing = @()
    foreach ($d in (Safe-Array $Deps)) {
      if ($Available -and ($Available -notcontains $d)) { $missing += $d }
    }
    $missing
  }

  # ---- manifest + output dirs ----
  $manifestPath = Join-Path $PackPath "manifest.json"
  if (-not (Test-Path $manifestPath)) { throw "Missing manifest.json at $manifestPath" }

  $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
  $packId = [string]$manifest.packId
  $packTitle = [string]$manifest.title

  $packOutDir = Join-Path $OutDir ("raw.kqlpack.{0}" -f $packId)
  New-Item -ItemType Directory -Path $packOutDir -Force | Out-Null

  Write-Info "KQL Pack: $packId ($packTitle)"

  # ---- optional table probe ----
  $tablesProbe = $null
  $availableTables = @()

  if ($ProbeTables) {
    Write-Info "Probing available tables (last $ProbeDays day(s))..."
    $tablesProbe = Get-AvailableTablesLocal -WorkspaceCustomerId $WorkspaceCustomerId -Days $ProbeDays
    Save-Json $tablesProbe (Join-Path $packOutDir "_tablesProbe.json")

    if ($tablesProbe.Success) {
      $availableTables = Safe-Array $tablesProbe.Tables
      Write-Info ("Tables found: {0}" -f (Safe-Count $availableTables))
    } else {
      Write-Info ("Table probe failed: {0}" -f $tablesProbe.Error)
    }
  }

  # ---- execute queries ----
  $resultsIndex = @()
  $ran = 0

  foreach ($q in (Safe-Array $manifest.queries)) {
    if ($ran -ge $MaxQueries) { break }

    $qid = [string]$q.id
    $kqlFile = Join-Path $PackPath ([string]$q.kqlFile)
    $days = if ($LookbackDaysOverride) { $LookbackDaysOverride } else { [int]$q.lookbackDaysDefault }
    $deps = Safe-Array $q.tableDependencies

    if (-not (Test-Path $kqlFile)) {
      $out = [ordered]@{
        packId  = $packId
        id      = $qid
        title   = [string]$q.title
        purpose = [string]$q.purpose
        days    = $days
        success = $false
        skipped = $true
        error   = "Missing KQL file: $($q.kqlFile)"
        rows    = @()
        collectedUtc = (Get-Date).ToUniversalTime().ToString("o")
      }
      $outFile = Join-Path $packOutDir ("{0}.json" -f $qid)
      Save-Json $out $outFile

      $resultsIndex += [ordered]@{ id=$qid; title=[string]$q.title; status="Skipped"; reason=$out.error; file=("raw.kqlpack.{0}/{1}.json" -f $packId, $qid) }
      continue
    }

    # If we probed tables and dependencies exist, skip cleanly when missing
    if ($ProbeTables -and $tablesProbe -and $tablesProbe.Success -and (Safe-Count $deps) -gt 0) {
      $missing = Missing-Tables -Deps $deps -Available $availableTables
      if (Safe-Count $missing -gt 0) {
        $out = [ordered]@{
          packId  = $packId
          id      = $qid
          title   = [string]$q.title
          purpose = [string]$q.purpose
          days    = $days
          success = $false
          skipped = $true
          error   = ("Missing tables: " + ($missing -join ", "))
          rows    = @()
          collectedUtc = (Get-Date).ToUniversalTime().ToString("o")
        }
        $outFile = Join-Path $packOutDir ("{0}.json" -f $qid)
        Save-Json $out $outFile

        $resultsIndex += [ordered]@{ id=$qid; title=[string]$q.title; status="Skipped"; reason=$out.error; file=("raw.kqlpack.{0}/{1}.json" -f $packId, $qid) }
        continue
      }
    }

    $kql = Get-Content $kqlFile -Raw
    $res = Try-RunLaQuery -WorkspaceCustomerId $WorkspaceCustomerId -Query $kql -Days $days

    $out = [ordered]@{
      packId  = $packId
      packTitle = $packTitle
      id      = $qid
      title   = [string]$q.title
      purpose = [string]$q.purpose
      days    = $days
      tableDependencies = $deps
      success = $res.Success
      skipped = $false
      error   = $res.Error
      rows    = As-Array $res.Results
      collectedUtc = (Get-Date).ToUniversalTime().ToString("o")
    }

    $outFile = Join-Path $packOutDir ("{0}.json" -f $qid)
    Save-Json $out $outFile

    $resultsIndex += [ordered]@{
      id=$qid
      title=[string]$q.title
      status=($(if($res.Success){"OK"}else{"Error"}))
      reason=$res.Error
      file=("raw.kqlpack.{0}/{1}.json" -f $packId, $qid)
    }

    $ran++
  }

  Save-Json $resultsIndex (Join-Path $packOutDir "_index.json")
}
