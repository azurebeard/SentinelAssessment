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
    return @($obj.PSObject.Properties)
  }

  function Join-PathSafe([string]$a, [string]$b) {
    if ([string]::IsNullOrWhiteSpace($a)) { return $b }
    return (Join-Path $a $b)
  }

  # -----------------------------
  # Validate OutDir + load normalised.json
  # -----------------------------
  if (-not (Test-Path $OutDir)) { throw "OutDir not found: $OutDir" }

  $normPath = Join-Path $OutDir "normalised.json"
  if (-not (Test-Path $normPath)) { $normPath = Join-Path $OutDir "normalized.json" }
  if (-not (Test-Path $normPath)) { throw "normalised.json missing in $OutDir. Run Normalise." }

  $norm = Load-JsonFile $normPath
  if (-not $norm) { throw "Failed to parse: $normPath" }

  $meta = $norm.meta
  $ws   = $meta.workspace
  $caps = $meta.capabilities

  # -----------------------------
  # Ensure styles.css is beside report (portable)
  # -----------------------------
  if ($TemplatesDir) {
    $cssSrc = Join-Path $TemplatesDir "styles.css"
    $cssDst = Join-Path $OutDir "styles.css"
    if (Test-Path $cssSrc) {
      Copy-Item $cssSrc $cssDst -Force
    } else {
      Write-Warning "styles.css not found in TemplatesDir: $TemplatesDir"
    }
  }

  # -----------------------------
  # Derivations for KPI tiles
  # -----------------------------
  $ingTop = SafeArray $norm.ingestion.top
  $ingMaxGb = 0.0
  $ingTotalGbTop = 0.0
  foreach ($r in $ingTop) {
    $gb = 0.0
    if (HasProp $r "totalGb" -and ($r.totalGb -ne $null)) { $gb = [double]$r.totalGb }
    $ingTotalGbTop += $gb
    if ($gb -gt $ingMaxGb) { $ingMaxGb = $gb }
  }
  if ($ingMaxGb -le 0) { $ingMaxGb = 1.0 }

  # KQL pack counts
  $kqlPacks = $norm.kqlPacks
  $packProps = Get-Props $kqlPacks

  $kqlTotal = 0; $kqlOk = 0; $kqlSkipped = 0; $kqlErr = 0
  foreach ($p in $packProps) {
    $pack = $p.Value
    $queries = SafeArray $(if (HasProp $pack "queries") { $pack.queries } else { @() })
    $kqlTotal   += (SafeCount $queries)
    $kqlOk      += (SafeCount ($queries | Where-Object { $_.status -eq "OK" }))
    $kqlSkipped += (SafeCount ($queries | Where-Object { $_.status -eq "Skipped" }))
    $kqlErr     += (SafeCount ($queries | Where-Object { $_.status -eq "Error" }))
  }

  # Capabilities score-ish
  $capOk = 0; $capTotal = 0
  $capChecks = @(
    $caps.kql.canQueryUsage,
    $caps.kql.canQuerySentinelHealth,
    $caps.kql.canQuerySentinelAudit,
    $caps.arm.canListAlertRules,
    $caps.arm.canListConnectors,
    $caps.arm.canListAutomationRules,
    $caps.arm.canListWorkbooks,
    $caps.assets.canListLogicApps
  )
  foreach ($c in $capChecks) { $capTotal++; if ($c) { $capOk++ } }

  # -----------------------------
  # Start HTML
  # -----------------------------
  $html = ""
  $html += "<!doctype html><html lang='en-GB'><head>"
  $html += "<meta charset='utf-8'/>"
  $html += "<meta name='viewport' content='width=device-width, initial-scale=1'/>"
  $html += "<title>Microsoft Sentinel Assessment Report</title>"
  $html += "<link rel='stylesheet' href='styles.css'/>"
  $html += "</head><body><div class='container'>"

  # HERO
  $html += "<div class='hero'>"
  $html += "<div class='heroTop'>"
  $html += "<div>"
  $html += "<h1>Microsoft Sentinel Assessment Report</h1>"
  $html += "<div class='subtitle'>Generated (UTC): " + (HtmlEncode (Format-Nullable $meta.runGeneratedUtc)) + "</div>"
  $html += "</div>"
  $html += "<div class='pills'>"
  $html += "<span class='pill'>Workspace: <b>" + (HtmlEncode (Format-Nullable $ws.workspaceName)) + "</b></span>"
  $html += "<span class='pill'>RG: <b>" + (HtmlEncode (Format-Nullable $ws.resourceGroup)) + "</b></span>"
  $html += "<span class='pill'>Region: <b>" + (HtmlEncode (Format-Nullable $ws.location)) + "</b></span>"
  $html += "<span class='pill'>Retention: <b>" + (HtmlEncode (Format-Nullable $ws.retentionInDays)) + "d</b></span>"
  $html += "</div>"
  $html += "</div>"

  $html += "<div class='nav'>"
  $html += "<a href='#workspace'>Workspace</a>"
  $html += "<a href='#capabilities'>Capabilities</a>"
  $html += "<a href='#ingestion'>Ingestion</a>"
  $html += "<a href='#kql'>KQL</a>"
  $html += "<a href='#governance'>CAF/NIS2</a>"
  $html += "<a href='#evidence'>Evidence</a>"
  $html += "</div>"

  # KPI tiles
  $html += "<div class='kpiGrid'>"
  $html += "<div class='kpi'><div class='kpiLabel'>Capabilities available</div><div class='kpiValue'>" + (HtmlEncode "$capOk/$capTotal") + "</div><div class='kpiHint'>Least-privilege evidence coverage</div></div>"
  $html += "<div class='kpi'><div class='kpiLabel'>KQL checks</div><div class='kpiValue'>" + (HtmlEncode ([string]$kqlTotal)) + "</div><div class='kpiHint'>" + (BadgeHtml "OK") + " " + (HtmlEncode ([string]$kqlOk)) + " &nbsp; " + (BadgeHtml "Skipped") + " " + (HtmlEncode ([string]$kqlSkipped)) + " &nbsp; " + (BadgeHtml "Error") + " " + (HtmlEncode ([string]$kqlErr)) + "</div></div>"
  $html += "<div class='kpi'><div class='kpiLabel'>Top ingestion total</div><div class='kpiValue'>" + (HtmlEncode ([string]([math]::Round($ingTotalGbTop,2)))) + " GB</div><div class='kpiHint'>Sum of displayed top data types</div></div>"
  $html += "<div class='kpi'><div class='kpiLabel'>Retention</div><div class='kpiValue'>" + (HtmlEncode (Format-Nullable $ws.retentionInDays)) + " days</div><div class='kpiHint'>Check aligns to detection needs</div></div>"
  $html += "</div>"

  $html += "</div>" # hero

  # -----------------------------
  # Workspace
  # -----------------------------
  $html += "<h2 id='workspace'>Workspace</h2>"
  $html += "<div class='card'>"
  $html += "<table><tbody>"
  $html += "<tr><th>Workspace</th><td>" + (HtmlEncode (Format-Nullable $ws.workspaceName)) + "</td></tr>"
  $html += "<tr><th>Resource Group</th><td>" + (HtmlEncode (Format-Nullable $ws.resourceGroup)) + "</td></tr>"
  $html += "<tr><th>Location</th><td>" + (HtmlEncode (Format-Nullable $ws.location)) + "</td></tr>"
  $html += "<tr><th>Retention (days)</th><td>" + (HtmlEncode (Format-Nullable $ws.retentionInDays)) + "</td></tr>"
  $html += "<tr><th>SKU</th><td>" + (HtmlEncode (Format-Nullable $ws.sku)) + "</td></tr>"
  $html += "</tbody></table>"
  $html += "</div>"

  # -----------------------------
  # Capabilities
  # -----------------------------
  $html += "<h2 id='capabilities'>Capabilities (Least Privilege)</h2>"
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

  # -----------------------------
  # Ingestion
  # -----------------------------
  $html += "<h2 id='ingestion'>Log Ingestion (Top Data Types)</h2>"

  if ((SafeCount $ingTop) -gt 0) {
    $html += "<div class='card'>"
    foreach ($r in $ingTop) {
      $dt = if (HasProp $r "dataType") { [string]$r.dataType } else { "Unknown" }
      $gb = if (HasProp $r "totalGb" -and ($r.totalGb -ne $null)) { [double]$r.totalGb } else { 0.0 }
      $pct = [math]::Round(($gb / $ingMaxGb) * 100, 0)

      $html += "<div class='barRow'>"
      $html += "<div class='barLabel'>" + (HtmlEncode $dt) + "</div>"
      $html += "<div class='barTrack'><div class='barFill' style='width:" + $pct + "%'></div></div>"
      $html += "<div class='barValue'>" + (HtmlEncode ([string]([math]::Round($gb,2)))) + " GB</div>"
      $html += "</div>"
    }
    $html += "<div class='muted'>Relative bars scaled to the largest value in this list.</div>"
    $html += "</div>"
  } else {
    $html += "<div class='warnBox'>No ingestion summary available in normalised.json.</div>"
  }

  # -----------------------------
  # KQL Packs (Option B)
  # -----------------------------
  $html += "<h2 id='kql'>KQL Assessment</h2>"

  if ((SafeCount $packProps) -gt 0) {

    # Executive summary table
    $html += "<div class='card'>"
    $html += "<table><thead><tr><th>Pack</th><th>Status</th><th>Queries</th><th>OK</th><th>Skipped</th><th>Error</th></tr></thead><tbody>"

    foreach ($p in $packProps) {
      $packId = $p.Name
      $pack   = $p.Value
      $queries = SafeArray $(if (HasProp $pack "queries") { $pack.queries } else { @() })

      $ok  = SafeCount ($queries | Where-Object { $_.status -eq "OK" })
      $sk  = SafeCount ($queries | Where-Object { $_.status -eq "Skipped" })
      $er  = SafeCount ($queries | Where-Object { $_.status -eq "Error" })
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

    # Drilldown per pack (collapsible)
    foreach ($p in $packProps) {
      $packId = $p.Name
      $pack   = $p.Value
      $packStatus = if (HasProp $pack "status") { [string]$pack.status } else { "Unknown" }
      $queries = SafeArray $(if (HasProp $pack "queries") { $pack.queries } else { @() })
      $tot = SafeCount $queries

      $html += "<details open>"
      $html += "<summary>Pack: " + (HtmlEncode $packId) + " " + (BadgeHtml $packStatus) + "<span class='summaryRight'>Queries: " + (HtmlEncode ([string]$tot)) + "</span></summary>"

      # Coverage table
      $html += "<div class='card soft'>"
      $html += "<table><thead><tr><th>Query</th><th>Status</th><th>Reason / Notes</th></tr></thead><tbody>"

      foreach ($q in $queries) {
        $qTitle  = if (HasProp $q "title")  { [string]$q.title }  else { "Untitled" }
        $qStatus = if (HasProp $q "status") { [string]$q.status } else { "Unknown" }
        $reason  = if (HasProp $q "error" -and $q.error) { [string]$q.error } else { "" }

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
        $html += "<div><b>" + (HtmlEncode $qTitle) + "</b> " + (BadgeHtml "OK") + "</div>"

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

      $html += "</details>"
    }

  } else {
    $html += "<div class='warnBox'>No KQL pack results were included in normalised.json.</div>"
  }

  # -----------------------------
  # CAF / NIS2 mapping (lightweight)
  # -----------------------------
  $html += "<h2 id='governance'>CAF / NIS2 Mapping (Summary)</h2>"
  $html += "<div class='card'>"
  $html += "<div class='muted'>Governance-friendly translation of technical observations. Not a compliance determination.</div>"
  $html += "<ul>"

  if ($caps.kql.canQueryUsage) {
    $html += "<li><b>Monitoring & visibility:</b> Ingestion summarisation available to evidence telemetry completeness and oversight.</li>"
  } else {
    $html += "<li><b>Monitoring & visibility:</b> Limited ability to query ingestion reduces assurance over telemetry completeness.</li>"
  }

  if ($caps.arm.canListAlertRules) {
    $html += "<li><b>Detect:</b> Analytics rules inventory accessible for coverage and tuning review against threat model.</li>"
  } else {
    $html += "<li><b>Detect:</b> Analytics rules inventory not accessible under current permissions (evidence gap).</li>"
  }

  if ($caps.arm.canListAutomationRules -or $caps.assets.canListLogicApps) {
    $html += "<li><b>Respond:</b> Automation/playbook evidence available for response readiness and repeatability.</li>"
  } else {
    $html += "<li><b>Respond:</b> Automation/playbook evidence not available under current permissions.</li>"
  }

  $html += "</ul>"
  $html += "</div>"

  # -----------------------------
  # Evidence footer
  # -----------------------------
  $html += "<h2 id='evidence'>Evidence</h2>"
  $html += "<div class='card'>Run output directory: <code>" + (HtmlEncode $OutDir) + "</code></div>"
  $html += "<div class='footer'>SentinelAssessment report generated from cached evidence (normalised.json + raw outputs).</div>"

  $html += "</div></body></html>"

  # Write report
  $outPath = Join-Path $OutDir $ReportFileName
  Set-Content -Path $outPath -Value $html -Encoding UTF8

  Write-Host ("[INFO] Report written: {0}" -f $outPath) -ForegroundColor Cyan
  return $outPath
}
