function Invoke-SANormalize {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$OutDir,
    [int]$MaxRowsPerQuery = 25
  )

  Set-StrictMode -Version Latest
  $ErrorActionPreference = "Stop"

  # -------- helpers (local to normalization) --------
  function New-StatusBlock([string]$status, [string]$error = $null) {
    [ordered]@{ status = $status; error = $error }
  }

  function Normalize-QueryStatus($raw, $indexItem) {
    # Our raw payload format from Invoke-KqlCollectors:
    # { success: bool, skipped?: bool, error?: string, rows?: [] }
    if ($null -eq $raw) { return "Error" }
    if ($raw.PSObject.Properties.Name -contains "skipped" -and [bool]$raw.skipped) { return "Skipped" }
    if ($raw.PSObject.Properties.Name -contains "success" -and [bool]$raw.success) { return "OK" }

    # fallback to index status if present
    if ($indexItem -and $indexItem.PSObject.Properties.Name -contains "status" -and $indexItem.status) {
      return [string]$indexItem.status
    }
    return "Error"
  }

  function Get-QueryError($raw, $indexItem) {
    if ($raw -and $raw.PSObject.Properties.Name -contains "error" -and $raw.error) { return [string]$raw.error }
    if ($indexItem -and $indexItem.PSObject.Properties.Name -contains "reason" -and $indexItem.reason) { return [string]$indexItem.reason }
    return $null
  }

  function Take-Top($rows, [int]$n) {
    (As-Array $rows | Select-Object -First $n)
  }

  function Summarize-KqlQuery {
    param(
      [Parameter(Mandatory=$true)][string]$QueryId,
      [Parameter(Mandatory=$true)]$Raw,
      [int]$MaxRows = 25
    )

    $rows = As-Array $Raw.rows

    switch ($QueryId) {

      # ---- EXAMPLES: tailor these IDs to your manifests ----

      "ingestion_top_datatypes" {
        # Expected: DataType + TotalGB or TotalMB
        $top = @()
        foreach ($r in (Take-Top $rows 12)) {
          $gb =
            if ($r.PSObject.Properties.Name -contains "TotalGB") { [double]$r.TotalGB }
            elseif ($r.PSObject.Properties.Name -contains "TotalMB") { [math]::Round(([double]$r.TotalMB / 1024.0), 2) }
            elseif ($r.PSObject.Properties.Name -contains "totalGb") { [double]$r.totalGb }
            else { $null }

          $top += [ordered]@{
            dataType = [string]$r.DataType
            totalGb  = $gb
          }
        }
        return [ordered]@{ top = $top }
      }

      "sentinel_audit_ops" {
        # Expected: OperationName, Events, LastEvent
        $top = @()
        foreach ($r in (Take-Top $rows 25)) {
          $top += [ordered]@{
            operation = [string]$r.OperationName
            events    = if ($r.PSObject.Properties.Name -contains "Events") { [int]$r.Events } else { $null }
            lastEvent = if ($r.PSObject.Properties.Name -contains "LastEvent") { [string]$r.LastEvent } else { $null }
          }
        }
        return [ordered]@{ top = $top }
      }

      "incidents_summary" {
        # Often binned daily: TimeGenerated + counts
        # Keep a small sample for the renderer to chart/table.
        return [ordered]@{ sample = (Take-Top $rows $MaxRows) }
      }

      default {
        # Safe fallback: first N rows as evidence
        return [ordered]@{ sample = (Take-Top $rows $MaxRows) }
      }
    }
  }

  # -------- load raw inputs --------
  $rawWorkspacePath     = Join-Path $OutDir "raw.workspace.json"
  $rawCapabilitiesPath  = Join-Path $OutDir "raw.capabilities.json"
  $rawTablesProbePath   = Join-Path $OutDir "raw.tablesProbe.json"

  $rawWorkspace    = Load-Json $rawWorkspacePath
  $rawCapabilities = Load-Json $rawCapabilitiesPath
  $rawTablesProbe  = Load-Json $rawTablesProbePath

  # -------- create normalized base --------
  $norm = [ordered]@{
    meta = [ordered]@{
      runGeneratedUtc = (Get-Date).ToUniversalTime().ToString("o")
      tool = [ordered]@{
        name = "SentinelAssessment"
        schemaVersion = "1.0"
      }
      workspace = $rawWorkspace
      capabilities = $rawCapabilities
      tablesProbe = $rawTablesProbe
    }

    # Future sections you can fill progressively
    ingestion  = [ordered]@{ status = "NotAssessed"; error = $null; top = @() }
    detections = [ordered]@{ status = "NotAssessed"; error = $null }
    connectors = [ordered]@{ status = "NotAssessed"; error = $null }
    automation = [ordered]@{ status = "NotAssessed"; error = $null }
    workbooks  = [ordered]@{ status = "NotAssessed"; error = $null }

    # The new dynamic section:
    kqlPacks = [ordered]@{}

    errors = @()
  }

  # -------- OPTIONAL: keep your existing ingestion normalisation if you have raw.ingestion.query.json --------
  $rawIngPath = Join-Path $OutDir "raw.ingestion.query.json"
  $rawIng = Load-Json $rawIngPath
  if ($rawIng) {
    if ($rawIng.Success) {
      $norm.ingestion.status = "OK"
      $norm.ingestion.top = @(
        foreach ($r in (Take-Top (As-Array $rawIng.Results) 12)) {
          [ordered]@{
            dataType = [string]$r.DataType
            totalGb  = if ($r.PSObject.Properties.Name -contains "TotalGB") { [double]$r.TotalGB }
                       elseif ($r.PSObject.Properties.Name -contains "TotalMB") { [math]::Round(([double]$r.TotalMB / 1024.0), 2) }
                       else { $null }
          }
        }
      )
    } else {
      $norm.ingestion.status = "NotAssessed"
      $norm.ingestion.error  = [string]$rawIng.Error
    }
  }

  # -------- normalize dynamic KQL collectors into kqlPacks --------
  $kqlIndexPath = Join-Path $OutDir "raw.kql/_index.json"
  $kqlIndex = Load-Json $kqlIndexPath

  if (-not $kqlIndex) {
    # no dynamic KQL outputs found, keep empty
    $norm.kqlPacks = [ordered]@{}
  }
  else {
    $groups = (As-Array $kqlIndex) | Group-Object -Property packId

    foreach ($g in $groups) {
      $packId = [string]$g.Name
      $packStatus = "OK"
      $queries = @()

      foreach ($item in $g.Group) {
        $rawFileRel = [string]$item.file
        $rawFileAbs = Join-Path $OutDir $rawFileRel

        $raw = Load-Json $rawFileAbs
        $status = Normalize-QueryStatus -raw $raw -indexItem $item
        $err = Get-QueryError -raw $raw -indexItem $item

        if ($status -ne "OK" -and $packStatus -eq "OK") {
          $packStatus = $status
        }

        $q = [ordered]@{
          id     = [string]$item.id
          title  = [string]$item.title
          status = $status
          days   = if ($raw -and $raw.PSObject.Properties.Name -contains "days") { [int]$raw.days } else { $null }
          error  = $err
          summary = [ordered]@{}
          evidence = [ordered]@{
            rawFile = $rawFileRel
          }
        }

        if ($status -eq "OK" -and $raw) {
          $q.summary = Summarize-KqlQuery -QueryId $q.id -Raw $raw -MaxRows $MaxRowsPerQuery
        }

        $queries += $q
      }

      $norm.kqlPacks[$packId] = [ordered]@{
        packTitle = $packId
        status    = $packStatus
        queries   = $queries
      }
    }
  }

  Save-Json $norm (Join-Path $OutDir "normalized.json")
}
