function Invoke-KqlPack {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][Guid]$WorkspaceCustomerId,
    [Parameter(Mandatory=$true)][string]$PackPath,
    [Parameter(Mandatory=$true)][string]$OutDir,
    [int]$LookbackDaysOverride,
    [switch]$ProbeTables,
    [int]$ProbeDays = 1,
    [int]$MaxQueries = 999
  )

  Set-StrictMode -Version Latest
  $ErrorActionPreference = "Stop"

  function Write-Info($m){ Write-Host "[INFO] $m" -ForegroundColor Cyan }

  function Safe-Array($x) { if ($null -eq $x) { @() } else { @($x) } }
  function Safe-Count($x) { (Safe-Array $x).Count }

  function Get-AvailableTablesLocal {
    param([Guid]$WorkspaceCustomerId, [int]$Days)

    # NOTE: escape `$table` for PowerShell, so KQL receives literal $table
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
    foreach ($row in (Safe-Array $res.Results)) {
      if ($row.PSObject.Properties.Name -contains '$table') { $tables += [string]$row.'$table' }
      elseif ($row.PSObject.Properties.Name -contains 'table') { $tables += [string]$row.table }
    }

    @{ Success=$true; Error=$null; Tables=($tables | Where-Object { $_ } | Sort-Object -Unique) }
  }

  function Missing-Tables {
    param([object]$Deps, [object]$Available)

    $depsArr = Safe-Array $Deps
    $availArr = Safe-Array $Available

    $missing = @()
    foreach ($d in $depsArr) {
      if ($null -eq $d) { continue }
      if ($availArr -notcontains [string]$d) { $missing += [string]$d }
    }
    $missing
  }

  # ---- manifest ----
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
      Save-Json $out (Join-Path $packOutDir ("{0}.json" -f $qid))

      $resultsIndex += [ordered]@{ id=$qid; title=[string]$q.title; status="Skipped"; reason=$out.error; file=("raw.kqlpack.{0}/{1}.json" -f $packId, $qid) }
      continue
    }

    if ($ProbeTables -and $tablesProbe -and $tablesProbe.Success -and (Safe-Count $deps) -gt 0) {
      $missing = Safe-Array (Missing-Tables -Deps $deps -Available $availableTables)
      if ((Safe-Count $missing) -gt 0) {
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
        Save-Json $out (Join-Path $packOutDir ("{0}.json" -f $qid))

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
      rows    = Safe-Array $res.Results
      collectedUtc = (Get-Date).ToUniversalTime().ToString("o")
    }

    Save-Json $out (Join-Path $packOutDir ("{0}.json" -f $qid))

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
