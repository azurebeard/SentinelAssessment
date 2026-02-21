function Invoke-KqlPack {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][Guid]$WorkspaceCustomerId,
    [Parameter(Mandatory=$true)][string]$PackPath,     # folder containing manifest.json + .kql files
    [Parameter(Mandatory=$true)][string]$OutDir,
    [int]$LookbackDaysOverride
  )

  $manifestPath = Join-Path $PackPath "manifest.json"
  if (-not (Test-Path $manifestPath)) { throw "Missing manifest.json at $manifestPath" }

  $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
  $packId = $manifest.packId
  $packOutDir = Join-Path $OutDir ("raw.kqlpack.{0}" -f $packId)
  New-Item -ItemType Directory -Path $packOutDir -Force | Out-Null

  $resultsIndex = @()

  foreach ($q in $manifest.queries) {
    $qid = [string]$q.id
    $kqlFile = Join-Path $PackPath $q.kqlFile
    $days = if ($LookbackDaysOverride) { $LookbackDaysOverride } else { [int]$q.lookbackDaysDefault }

    $kql = Get-Content $kqlFile -Raw
    # Optional token replacement if you want it later:
    # $kql = $kql -replace '\{\{LOOKBACK_DAYS\}\}', $days

    $res = Try-RunLaQuery -WorkspaceCustomerId $WorkspaceCustomerId -Query $kql -Days $days

    $out = [ordered]@{
      packId  = $packId
      id      = $qid
      title   = $q.title
      purpose = $q.purpose
      days    = $days
      success = $res.Success
      error   = $res.Error
      rows    = As-Array $res.Results
      collectedUtc = (Get-Date).ToUniversalTime().ToString("o")
    }

    $outFile = Join-Path $packOutDir ("{0}.json" -f $qid)
    Save-Json $out $outFile

    $resultsIndex += [ordered]@{
      id=$qid; title=$q.title; success=$res.Success; error=$res.Error; file=("raw.kqlpack.{0}/{1}.json" -f $packId, $qid)
    }
  }

  Save-Json $resultsIndex (Join-Path $packOutDir "_index.json")
}
