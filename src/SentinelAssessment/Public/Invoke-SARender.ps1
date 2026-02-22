function Invoke-SARender {

  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$OutDir,
    [Parameter(Mandatory=$false)][string]$TemplatesDir,
    [string]$ReportFileName = "SentinelAssessment.html",
    [int]$MaxSampleRows = 12
  )

  Set-StrictMode -Version Latest
  $ErrorActionPreference = "Stop"

  # -----------------------------
  # Helpers
  # -----------------------------
  function SafeArray {
    param([object]$InputObject)
      if ($null -eq $InputObject) { return @() }
    return @($InputObject)
  }

  function SafeCount {
    param([object]$InputObject)
      if ($null -eq $InputObject) { return 0 }
    return (@($InputObject)).Length
  }

  function HasProp($obj, [string]$name) {
    return ($null -ne $obj) -and ($obj.PSObject.Properties.Name -contains $name)
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

  function Format-Nullable([object]$v) {
    if ($null -eq $v) { return "—" }
    $s = [string]$v
    if ([string]::IsNullOrWhiteSpace($s)) { return "—" }
    return $s
  }

  function Get-Props($obj) {
    if ($null -eq $obj) { return @() }
    # PSObject.Properties is a collection, wrap it anyway for safety
    return @($obj.PSObject.Properties)
  }

  # -----------------------------
  # Validate OutDir + load normalised.json
  # -----------------------------
  if (-not (Test-Path $OutDir)) { throw "OutDir not found: $OutDir" }

  $normPath = Join-Path $OutDir "normalised.json"
  if (-not (Test-Path $normPath)) {
    $normPath = Join-Path $OutDir "normalized.json"
  }
  if (-not (Test-Path $normPath)) {
    throw "normalised.json missing in $OutDir. Run Normalise."
  }

  $norm = Load-JsonFile $normPath
  if (-not $norm) { throw "Failed to parse: $normPath" }

  # -----------------------------
  # Ensure styles.css is beside report (portable)
  # -----------------------------
  if ($TemplatesDir) {
    $cssSrc = Join-Path $TemplatesDir "styles.css"
    $cssDst = Join-Path $OutDir "styles.css"
    if (Test-Path $cssSrc) {
      Copy-Item $cssSrc $cssDst -Force
    }
    else {
      Write-Warning "styles.css not found in TemplatesDir: $TemplatesDir"
    }
  }

  $meta = $norm.meta
  $ws   = $meta.workspace
  $caps = $meta.capabilities

  # -----------------------------
  # Start HTML
  # -----------------------------
  $html = ""
  $html += "<!doctype html><html lang='en-GB'><head>"
  $html += "<meta charset='utf-8'/>"
  $html += "<meta name='viewport' content='width=device-width, initial-scale=1'/>"
  $html += "<title>Microsoft Sentinel Assessment Report</title>"
  $html += "<link rel='stylesheet' href='styles.css'/>"
  $html += "</head><body>"

  $html += "<h1>Microsoft Sentinel Assessment Report</h1>"
  $html += "<div class='muted'>Generated (UTC): " + (HtmlEncode (Format-Nullable $meta.runGeneratedUtc)) + "</div>"

  # Workspace
  $html += "<h2>Workspace</h2>"
  $html += "<div class='card'>"
  $html += "<table><tbody>"
  $html += "<tr><th>Workspace</th><td>" + (HtmlEncode (Format-Nullable $ws.workspaceName)) + "</td></tr>"
  $html += "<tr><th>Resource Group</th><td>" + (HtmlEncode (Format-Nullable $ws.resourceGroup)) + "</td></tr>"
  $html += "<tr><th>Location</th><td>" + (HtmlEncode (Format-Nullable $ws.location)) + "</td></tr>"
  $html += "<tr><th>Retention (days)</th><td>" + (HtmlEncode (Format-Nullable $ws.retentionInDays)) + "</td></tr>"
  $html += "<tr><th>SKU</th><td>" + (HtmlEncode (Format-Nullable $ws.sku)) + "</td></tr>"
  $html += "</tbody></table>"
  $html += "</div>"

  # Capabilities
  $html += "<h2>Capabilities (Least Privilege)</h2>"
  $html += "<div class='card'>"
  $html += "<table><thead><tr><th>Area</th><th>Capability</th><th>Status</th></tr></thead><tbody>"

  $html += "<tr><td>KQL</td><td>Query Usage</td><td>" + (BadgeHtml ($(if($caps.kql.canQueryUsage){"OK"}else{"Error"}))) + "</td></tr>"
  $html += "<tr><td>KQL</td><td>Query SentinelHealth</td><td>" + (BadgeHtml ($(if($caps.kql.canQuerySentinelHealth){"OK"}else{"Error"}))) + "</td></tr>"
  $html += "<tr><td>KQL</td><td>Query SentinelAudit</td><td>" + (BadgeHtml ($(if($caps.kql.canQuerySentinelAudit){"OK"}else{"Error"}))) + "</td></tr>"

  $html += "<tr><td>ARM</td><td>List Analytics Rules</td><td>" + (BadgeHtml ($(if($caps.arm.canListAlertRules){"OK"}else{"Error"}))) + "</td></tr>"
  $html += "<tr><td>ARM</td><td>List Data Connectors</td><td>" + (BadgeHtml ($(if($caps.arm.canListConnectors){"OK"}else{"Error"}))) + "</td></tr>"
  $html += "<tr><td>ARM</td><td>List Automation Rules</td><td>" + (BadgeHtml ($(if($caps.arm.canListAutomationRules){"OK"}else{"Error"}))) + "</td></tr>"
  $html += "<tr><td>ARM</td><td>List Workbooks</td><td>" + (BadgeHtml ($(if($caps.arm.canListWorkbooks){"OK"}else{"Error"}))) + "</td></tr>"

  $html += "<tr><td>Assets</td><td>List Logic Apps (Playbooks)</td><td>" + (BadgeHtml ($(if($caps.assets.canListLogicApps){"OK"}else{"Error"}))) + "</td></tr>"

  $html += "</tbody></table>"
  $html += "</div>"

  # Ingestion bar chart
  $html += "<h2>Log Ingestion (Top Data Types)</h2>"
  $ingTop = SafeArray $norm.ingestion.top
  if ((SafeCount $ingTop) -gt 0) {
    $maxGb = 0.0
    foreach ($r in $ingTop) {
      $gb = 0.0
      if (HasProp $r "totalGb" -and ($r.totalGb -ne $null)) { $gb = [double]$r.totalGb }
      if ($gb -gt $maxGb) { $maxGb = $gb }
    }
    if ($maxGb -le 0) { $maxGb = 1.0 }

    $html += "<div class='card'>"
    foreach ($r in $ingTop) {
      $dt = if (HasProp $r "dataType") { [string]$r.dataType } else { "Unknown" }
      $gb = if (HasProp $r "totalGb" -and ($r.totalGb -ne $null)) { [double]$r.totalGb } else { 0.0 }
      $pct = [math]::Round(($gb / $maxGb) * 100, 0)

      $html += "<div class='barRow'>"
      $html += "<div class='barLabel'>" + (HtmlEncode $dt) + "</div>"
      $html += "<div class='barTrack'><div class='barFill' style='width:" + $pct + "%'></div></div>"
      $html += "<div class='barValue'>" + (HtmlEncode ([string]$gb)) + " GB</div>"
      $html += "</div>"
    }
    $html += "<div class='muted'>Relative bars scaled to the largest value in this list.</div>"
    $html += "</div>"
  }
  else {
    $html += "<div class='warn'>No ingestion summary available in normalised.json.</div>"
  }

  # -----------------------------
  # KQL Packs (Option B)
  # -----------------------------
  $html += "<h2>KQL Assessment</h2>"
  $kqlPacks = $norm.kqlPacks
  $packProps = Get-Props $kqlPacks

  if ((SafeCount $packProps) -gt 0) {

    # Executive summary table
    $html += "<div class='card'>"
    $html += "<table><thead><tr><th>Pack</th><th>Status</th><th>Queries</th><th>OK</th><th>Skipped</th><th>Error</th></tr></thead><tbody>"

    foreach ($p in $packProps) {
      $packId = $p.Name
      $pack   = $p.Value
      $queries = SafeArray $(if (HasProp $pack "queries") { $pack.queries } else { @() })

      $ok  = SafeCount (SafeArray ($queries | Where-Object { $_.status -eq "OK" }))
      $sk  = SafeCount (SafeArray ($queries | Where-Object { $_.status -eq "Skipped" }))
      $er  = SafeCount (SafeArray ($queries | Where-Object { $_.status -eq "Error" }))
      $tot = SafeCount $queries

      $packStatus = if (HasProp $pack "status") { [string]$pack.status } else { "Unknown" }

      $html += "<tr>"
      $html += "<td>" + (HtmlEncode $packId) + "</td>"
      $html += "<td>" + (BadgeHtml $packStatus) + "</td>"
      $html += "<td>" + (HtmlEncode ([string]$tot)) + "</td>"
      $html += "<td>" + (HtmlEncode ([string]$ok)) + "</td>"
      $html += "<td>" + (HtmlEncode ([string]$sk)) + "</td>"
      $html += "<td>" + (HtmlEncode ([string]$er)) + "</td>"
      $html += "</tr>"
    }

    $html += "</tbody></table>"
    $html += "</div>"

    # Drilldown per pack
    foreach ($p in $packProps) {
      $packId = $p.Name
      $pack   = $p.Value
      $packStatus = if (HasProp $pack "status") { [string]$pack.status } else { "Unknown" }
      $queries = SafeArray $(if (HasProp $pack "queries") { $pack.queries } else { @() })

      $html += "<h3>Pack: " + (HtmlEncode $packId) + " " + (BadgeHtml $packStatus) + "</h3>"

      $html += "<div class='card'>"
      $html += "<table><thead><tr><th>Query</th><th>Status</th><th>Reason / Notes</th></tr></thead><tbody>"

      foreach ($q in $queries) {
        $qTitle = if (HasProp $q "title") { [string]$q.title } else { "Untitled" }
        $qStatus = if (HasProp $q "status") { [string]$q.status } else { "Unknown" }
        $reason = if (HasProp $q "error" -and $q.error) { [string]$q.error } else { "" }

        $html += "<tr>"
        $html += "<td>" + (HtmlEncode $qTitle) + "</td>"
        $html += "<td>" + (BadgeHtml $qStatus) + "</td>"
        $html += "<td>" + (HtmlEncode $reason) + "</td>"
        $html += "</tr>"
      }

      $html += "</tbody></table>"
      $html += "</div>"

      # Evidence blocks for OK queries
      foreach ($q in ($queries | Where-Object { $_.status -eq "OK" })) {
        $qTitle = if (HasProp $q "title") { [string]$q.title } else { "Untitled" }

        $html += "<div class='card'>"
        $html += "<b>" + (HtmlEncode $qTitle) + "</b> " + (BadgeHtml "OK")

        if (HasProp $q "summary" -and $q.summary) {
          if (HasProp $q.summary "top" -and $q.summary.top) {
            $top = SafeArray $q.summary.top
            $html += "<table><thead><tr><th>Item</th><th>Value</th></tr></thead><tbody>"
            foreach ($r in $top) {
              if (HasProp $r "dataType" -and HasProp $r "totalGb") {
                $html += "<tr><td>" + (HtmlEncode ([string]$r.dataType)) + "</td><td>" + (HtmlEncode ([string]$r.totalGb)) + "</td></tr>"
              } else {
                $html += "<tr><td colspan='2'><code>" + (HtmlEncode ($r | ConvertTo-Json -Depth 6)) + "</code></td></tr>"
              }
            }
            $html += "</tbody></table>"
          }
          elseif (HasProp $q.summary "sample" -and $q.summary.sample) {
            $sample = @($q.summary.sample | Select-Object -First $MaxSampleRows)
            $html += "<pre>" + (HtmlEncode ($sample | ConvertTo-Json -Depth 8)) + "</pre>"
          }
          else {
            $html += "<div class='muted'>No summarised rows available for this query.</div>"
          }
        }
        else {
          $html += "<div class='muted'>No summary present for this query.</div>"
        }

        if (HasProp $q "evidence" -and $q.evidence -and HasProp $q.evidence "rawFile" -and $q.evidence.rawFile) {
          $html += "<div class='muted'>Evidence file: <code>" + (HtmlEncode ([string]$q.evidence.rawFile)) + "</code></div>"
        }

        $html += "</div>"
      }
    }

  }
  else {
    $html += "<div class='warn'>No KQL pack results were included in normalised.json.</div>"
  }

  # -----------------------------
  # CAF / NIS2 mapping (lightweight)
  # -----------------------------
  $html += "<h2>CAF / NIS2 Mapping (Summary)</h2>"
  $html += "<div class='card'>"
  $html += "<div class='muted'>Governance-friendly translation of technical observations. Not a compliance determination.</div>"
  $html += "<ul>"

  if ($caps.kql.canQueryUsage) {
    $html += "<li><b>Monitoring & visibility:</b> Ingestion summarisation available (supports CAF monitoring expectations and NIS2 oversight).</li>"
  } else {
    $html += "<li><b>Monitoring & visibility:</b> Limited ability to query ingestion (reduces assurance over telemetry completeness).</li>"
  }

  if ($caps.arm.canListAlertRules) {
    $html += "<li><b>Detect:</b> Analytics rules inventory accessible for coverage and tuning review (align to threat model / MITRE).</li>"
  } else {
    $html += "<li><b>Detect:</b> Analytics rules inventory not accessible under current permissions (gap in assurance evidence).</li>"
  }

  if ($caps.arm.canListAutomationRules -or $caps.assets.canListLogicApps) {
    $html += "<li><b>Respond:</b> Automation/playbook inventory can be evidenced for response readiness and repeatability.</li>"
  } else {
    $html += "<li><b>Respond:</b> Automation/playbook evidence not available under current permissions.</li>"
  }

  $html += "</ul>"
  $html += "</div>"

  # Footer
  $html += "<h2>Evidence Location</h2>"
  $html += "<div class='card'>Run output directory: <code>" + (HtmlEncode $OutDir) + "</code></div>"

  $html += "</body></html>"

  # Write report
  $outPath = Join-Path $OutDir $ReportFileName
  Set-Content -Path $outPath -Value $html -Encoding UTF8

  Write-Host ("[INFO] Report written: {0}" -f $outPath) -ForegroundColor Cyan
  return $outPath
}
