function Invoke-SARender {

  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$OutDir,
    [string]$ReportFileName = "SentinelAssessment.report.html",
    [int]$MaxSampleRows = 12
  )

  Set-StrictMode -Version Latest
  $ErrorActionPreference = "Stop"

  # -----------------------------
  # Helpers
  # -----------------------------
  function SafeArray($x) {
    if ($null -eq $x) { return @() }
    return @($x)
  }

  function SafeCount($x) {
    if ($null -eq $x) { return 0 }
    return @($x).Count
  }

  function HtmlEncode([string]$s) {
    if ($null -eq $s) { return "" }
    return [System.Web.HttpUtility]::HtmlEncode($s)
  }

  function BadgeHtml([string]$status) {
    switch ($status) {
      "OK"      { return "<span class='badge ok'>OK</span>" }
      "Skipped" { return "<span class='badge warn'>Skipped</span>" }
      "Error"   { return "<span class='badge err'>Error</span>" }
      default   { return "<span class='badge neutral'>" + (HtmlEncode $status) + "</span>" }
    }
  }

  function Load-JsonFile([string]$path) {
    if (-not (Test-Path $path)) { return $null }
    return (Get-Content $path -Raw | ConvertFrom-Json)
  }

  # -----------------------------
  # Locate normalised file
  # -----------------------------
  $normPath = Join-Path $OutDir "normalised.json"
  if (-not (Test-Path $normPath)) {
    $normPath = Join-Path $OutDir "normalized.json"
  }
  if (-not (Test-Path $normPath)) {
    throw "normalised.json missing. Run Normalise."
  }

  $norm = Load-JsonFile $normPath
  if (-not $norm) { throw "Failed to parse normalised.json" }

  $meta = $norm.meta
  $ws   = $meta.workspace
  $caps = $meta.capabilities

  # -----------------------------
  # Begin HTML
  # -----------------------------
  $html = ""
  $html += "<!doctype html><html lang='en-GB'><head>"
  $html += "<meta charset='utf-8'/>"
  $html += "<meta name='viewport' content='width=device-width, initial-scale=1'/>"
  $html += "<title>Microsoft Sentinel Assessment Report</title>"
  $html += "<link rel='stylesheet' href='styles.css'/>"
  $html += "</head><body><div class='wrap'>"

  # Header
  $html += "<h1>Microsoft Sentinel Assessment Report</h1>"
  $html += "<div class='small'>Generated (UTC): " + (HtmlEncode $meta.runGeneratedUtc) + "</div>"

  # Workspace
  $html += "<h2>Workspace</h2>"
  $html += "<div class='grid'>"
  $html += "<div class='card'><h4>Workspace</h4>"
  $html += "<div><b>Name:</b> " + (HtmlEncode $ws.workspaceName) + "</div>"
  $html += "<div><b>Resource Group:</b> " + (HtmlEncode $ws.resourceGroup) + "</div>"
  $html += "<div><b>Location:</b> " + (HtmlEncode $ws.location) + "</div>"
  $html += "</div>"
  $html += "<div class='card'><h4>Retention & SKU</h4>"
  $html += "<div><b>Retention:</b> " + (HtmlEncode $ws.retentionInDays) + " days</div>"
  $html += "<div><b>SKU:</b> " + (HtmlEncode $ws.sku) + "</div>"
  $html += "</div>"
  $html += "</div>"

  # Capabilities
  $html += "<h2>Capabilities (Least Privilege)</h2>"
  $html += "<div class='grid'>"
  $html += "<div class='card'><h4>KQL</h4>"
  $html += "<div>Usage: " + (BadgeHtml ($(if($caps.kql.canQueryUsage){"OK"}else{"Error"}))) + "</div>"
  $html += "<div>SentinelHealth: " + (BadgeHtml ($(if($caps.kql.canQuerySentinelHealth){"OK"}else{"Error"}))) + "</div>"
  $html += "</div>"
  $html += "<div class='card'><h4>ARM</h4>"
  $html += "<div>Alert Rules: " + (BadgeHtml ($(if($caps.arm.canListAlertRules){"OK"}else{"Error"}))) + "</div>"
  $html += "<div>Connectors: " + (BadgeHtml ($(if($caps.arm.canListConnectors){"OK"}else{"Error"}))) + "</div>"
  $html += "<div>Automation Rules: " + (BadgeHtml ($(if($caps.arm.canListAutomationRules){"OK"}else{"Error"}))) + "</div>"
  $html += "</div>"
  $html += "</div>"

  # Ingestion Graph
  $html += "<h2>Log Ingestion (Top Data Types)</h2>"
  $ingTop = SafeArray $norm.ingestion.top

  if ((SafeCount $ingTop) -gt 0) {
    $max = ($ingTop | Measure-Object -Property totalGb -Maximum).Maximum
    if ($max -le 0) { $max = 1 }

    $html += "<div class='barwrap'>"
    foreach ($r in $ingTop) {
      $pct = [math]::Round(($r.totalGb / $max) * 100,0)
      $html += "<div class='barrow'>"
      $html += "<div>" + (HtmlEncode $r.dataType) + "</div>"
      $html += "<div class='bar'><span style='width:$pct%'></span></div>"
      $html += "<div class='small'>" + (HtmlEncode $r.totalGb) + " GB</div>"
      $html += "</div>"
    }
    $html += "</div>"
  }
  else {
    $html += "<p class='small'>No ingestion data available.</p>"
  }

  # -----------------------------
  # KQL Executive Summary + Drilldown
  # -----------------------------
  $html += "<h2>KQL Assessment</h2>"

  if ($norm.kqlPacks -and $norm.kqlPacks.PSObject.Properties.Count -gt 0) {

    $html += "<div class='grid'>"

    foreach ($prop in $norm.kqlPacks.PSObject.Properties) {
      $pack = $prop.Value
      $queries = SafeArray $pack.queries

      $ok  = (SafeArray ($queries | Where-Object {$_.status -eq "OK"})).Count
      $sk  = (SafeArray ($queries | Where-Object {$_.status -eq "Skipped"})).Count
      $er  = (SafeArray ($queries | Where-Object {$_.status -eq "Error"})).Count

      $html += "<div class='card'>"
      $html += "<h4>Pack: " + (HtmlEncode $prop.Name) + "</h4>"
      $html += "<div>Status: " + (BadgeHtml $pack.status) + "</div>"
      $html += "<div class='small'>OK: $ok | Skipped: $sk | Error: $er</div>"
      $html += "</div>"
    }

    $html += "</div>"

    $html += "<h3>Drilldown</h3>"

    foreach ($prop in $norm.kqlPacks.PSObject.Properties) {
      $pack = $prop.Value
      $queries = SafeArray $pack.queries

      $html += "<details>"
      $html += "<summary>Pack: " + (HtmlEncode $prop.Name) + "</summary>"

      $html += "<table><thead><tr><th>Query</th><th>Status</th><th>Reason</th></tr></thead><tbody>"
      foreach ($q in $queries) {
        $reason = if ($q.error) { $q.error } else { "" }
        $html += "<tr>"
        $html += "<td>" + (HtmlEncode $q.title) + "</td>"
        $html += "<td>" + (BadgeHtml $q.status) + "</td>"
        $html += "<td>" + (HtmlEncode $reason) + "</td>"
        $html += "</tr>"
      }
      $html += "</tbody></table>"

      foreach ($q in $queries) {
        $html += "<details>"
        $html += "<summary>" + (HtmlEncode $q.title) + "</summary>"

        if ($q.summary -and $q.summary.top) {
          $html += "<table><thead><tr><th>Item</th><th>Value</th></tr></thead><tbody>"
          foreach ($r in (SafeArray $q.summary.top)) {
            $html += "<tr><td>" + (HtmlEncode $r.dataType) + "</td><td>" + (HtmlEncode $r.totalGb) + "</td></tr>"
          }
          $html += "</tbody></table>"
        }
        elseif ($q.summary -and $q.summary.sample) {
          $sample = @($q.summary.sample | Select-Object -First $MaxSampleRows)
          $html += "<pre>" + (HtmlEncode ($sample | ConvertTo-Json -Depth 6)) + "</pre>"
        }

        $html += "</details>"
      }

      $html += "</details>"
    }

  }
  else {
    $html += "<p class='small'>No KQL packs present in normalised.json.</p>"
  }

  # Governance Mapping
  $html += "<h2>CAF / NIS2 Summary</h2>"
  $html += "<div class='card'>"
  $html += "<ul>"
  $html += "<li><b>Monitoring:</b> Log ingestion visibility supports oversight of detection capability.</li>"
  $html += "<li><b>Detection:</b> Analytics rules inventory should be reviewed against threat model and MITRE ATT&CK coverage.</li>"
  $html += "<li><b>Response:</b> Automation rules and playbooks should align to incident response processes.</li>"
  $html += "</ul>"
  $html += "</div>"

  $html += "</div></body></html>"

  # Write file
  $outPath = Join-Path $OutDir $ReportFileName
  Set-Content -Path $outPath -Value $html -Encoding UTF8

  Write-Host "[INFO] Report written: $outPath" -ForegroundColor Cyan
  return $outPath
}
