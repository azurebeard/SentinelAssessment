<#
.SYNOPSIS
  Sentinel Rapid Assessment v2 - Renderer (offline)

.DESCRIPTION
  Reads cached JSON files from a RunDir and renders a single HTML report.
  Does NOT call Azure or run KQL.

.PARAMETER RunDir
  The output directory created by the collector, e.g. ./out/20260204-213500
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$RunDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Helpers come from orchestrator scope when dot-sourced. If you run this directly,
# it still works by re-defining tiny helpers here.
function Load-Json([string]$path){
  if (-not (Test-Path $path)) { return $null }
  Get-Content -Path $path -Raw | ConvertFrom-Json
}
function HtmlEncode([string]$s){
  if ($null -eq $s) { return "" }
  return ($s -replace "&","&amp;" -replace "<","&lt;" -replace ">","&gt;" -replace '"',"&quot;" -replace "'","&#39;")
}
function Get-MitreTacticsBaseline {
  @(
    "Reconnaissance","Resource Development","Initial Access","Execution","Persistence",
    "Privilege Escalation","Defense Evasion","Credential Access","Discovery","Lateral Movement",
    "Collection","Command and Control","Exfiltration","Impact"
  )
}

$workspace   = Load-Json (Join-Path $RunDir "workspace.json")
$ingestion   = Load-Json (Join-Path $RunDir "ingestion.json")
$coreHealth  = Load-Json (Join-Path $RunDir "core-health.json")

$alertRulesResp      = Load-Json (Join-Path $RunDir "alertRules.raw.json")
$dataConnectorsResp  = Load-Json (Join-Path $RunDir "dataConnectors.raw.json")
$automationRulesResp = Load-Json (Join-Path $RunDir "automationRules.raw.json")

$connectorHealthQ  = Load-Json (Join-Path $RunDir "connectorHealth.query.json")
$automationHealthQ = Load-Json (Join-Path $RunDir "automationHealth.query.json")

$playbooks    = Load-Json (Join-Path $RunDir "playbooks.json")
$workbooksResp= Load-Json (Join-Path $RunDir "workbooks.raw.json")

if (-not $workspace) { throw "Missing workspace.json in $RunDir. Run Collect step first." }

# -------------------------
# Derive analytics rule metrics
# -------------------------
$rulesError = $null
$rules = @()
if ($alertRulesResp -and $alertRulesResp.Success -and $alertRulesResp.Json -and $alertRulesResp.Json.value) {
  $rules = $alertRulesResp.Json.value
} else {
  $rulesError = if ($alertRulesResp) { $alertRulesResp.Error } else { "alertRules.raw.json missing" }
}

$totalRules = $rules.Count
$enabledCount = 0
$disabledCount = 0
$kindCounts = @{}
$tacticCounts = @{}
$techniqueCounts = @{}

foreach ($r in $rules) {
  $kind = $r.kind
  if (-not $kindCounts.ContainsKey($kind)) { $kindCounts[$kind] = 0 }
  $kindCounts[$kind]++

  $props = $r.properties
  if ($props -and ($props.PSObject.Properties.Name -contains "enabled")) {
    if ([bool]$props.enabled) { $enabledCount++ } else { $disabledCount++ }
  }
  if ($props -and $props.tactics) {
    foreach ($t in $props.tactics) {
      if ([string]::IsNullOrWhiteSpace($t)) { continue }
      if (-not $tacticCounts.ContainsKey($t)) { $tacticCounts[$t] = 0 }
      $tacticCounts[$t]++
    }
  }
  if ($props -and $props.techniques) {
    foreach ($te in $props.techniques) {
      if ([string]::IsNullOrWhiteSpace($te)) { continue }
      if (-not $techniqueCounts.ContainsKey($te)) { $techniqueCounts[$te] = 0 }
      $techniqueCounts[$te]++
    }
  }
}

# -------------------------
# Connectors inventory metrics
# -------------------------
$connectorInvError = $null
$connectorInvCount = 0
if ($dataConnectorsResp -and $dataConnectorsResp.Success -and $dataConnectorsResp.Json -and $dataConnectorsResp.Json.value) {
  $connectorInvCount = $dataConnectorsResp.Json.value.Count
} else {
  $connectorInvError = if ($dataConnectorsResp) { $dataConnectorsResp.Error } else { "dataConnectors.raw.json missing" }
}

# -------------------------
# Automation rules + playbook references
# -------------------------
$autoRulesError = $null
$autoRules = @()
if ($automationRulesResp -and $automationRulesResp.Success -and $automationRulesResp.Json -and $automationRulesResp.Json.value) {
  $autoRules = $automationRulesResp.Json.value
} else {
  $autoRulesError = if ($automationRulesResp) { $automationRulesResp.Error } else { "automationRules.raw.json missing" }
}

$playbookRefs = New-Object System.Collections.Generic.HashSet[string]
foreach ($r in $autoRules) {
  $json = $r | ConvertTo-Json -Depth 40 -Compress
  $matches = [regex]::Matches($json, "(/subscriptions/[^""]+/resourceGroups/[^""]+/providers/Microsoft\.Logic/workflows/[^""]+)", "IgnoreCase")
  foreach ($m in $matches) { [void]$playbookRefs.Add($m.Groups[1].Value) }
}

# -------------------------
# Ingestion bars
# -------------------------
$ingBarsHtml = ""
$ingDays = if ($ingestion -and $ingestion.IngestionDays) { $ingestion.IngestionDays } else { "?" }

if (-not $ingestion -or -not $ingestion.Success) {
  $err = if ($ingestion) { $ingestion.Error } else { "ingestion.json missing" }
  $ingBarsHtml = "<div class='warn'><strong>Not assessed:</strong> $(HtmlEncode $err)</div>"
} elseif ($ingestion.Rows.Count -eq 0) {
  $ingBarsHtml = "<p><em>No ingestion rows returned for the selected period.</em></p>"
} else {
  $maxGB = [Math]::Max(1, ($ingestion.Rows | Measure-Object -Property TotalGB -Maximum).Maximum)
  foreach ($row in $ingestion.Rows) {
    $pct = [Math]::Round(($row.TotalGB / $maxGB) * 100, 0)
    $ingBarsHtml += @"
<div class="barRow">
  <div class="barLabel">$(HtmlEncode $row.DataType)</div>
  <div class="barTrack"><div class="barFill" style="width:${pct}%"></div></div>
  <div class="barValue">$(HtmlEncode ($row.TotalGB.ToString("0.00"))) GB</div>
</div>
"@
  }
}

# -------------------------
# MITRE coverage tables
# -------------------------
$baseline = Get-MitreTacticsBaseline
$coverageRows = foreach ($t in $baseline) {
  $count = 0
  if ($tacticCounts.ContainsKey($t)) { $count = [int]$tacticCounts[$t] }
  [pscustomobject]@{ Tactic=$t; RuleCount=$count }
}
$missingTactics = $coverageRows | Where-Object { $_.RuleCount -eq 0 } | Select-Object -ExpandProperty Tactic

$mitreGapsHtml = if ($rulesError) {
  "<div class='warn'><strong>Not assessed:</strong> $(HtmlEncode $rulesError)</div>"
} elseif ($missingTactics.Count -gt 0) {
  "<p><strong>Potential tactic gaps:</strong> $(HtmlEncode ($missingTactics -join ', '))</p>"
} else {
  "<p><strong>Potential tactic gaps:</strong> None identified from metadata baseline.</p>"
}

$mitreRows = if ($rulesError) { "" } else {
  ($coverageRows | Sort-Object RuleCount -Descending | ForEach-Object {
    "<tr><td>$(HtmlEncode $_.Tactic)</td><td style='text-align:right'>$(HtmlEncode $_.RuleCount)</td></tr>"
  }) -join "`n"
}

$topTechniques = $techniqueCounts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 12
$techTableHtml = if ($rulesError) {
  "<div class='warn'><strong>Not assessed:</strong> rules could not be listed.</div>"
} elseif (-not $topTechniques -or $topTechniques.Count -eq 0) {
  "<p><em>No techniques metadata found.</em></p>"
} else {
  $rows = ($topTechniques | ForEach-Object {
    "<tr><td>$(HtmlEncode $_.Key)</td><td style='text-align:right'>$(HtmlEncode $_.Value)</td></tr>"
  }) -join "`n"
  @"
<table>
  <tr><th>Technique</th><th style='text-align:right'>Rules (metadata)</th></tr>
  $rows
</table>
"@
}

# -------------------------
# Rule kind table
# -------------------------
$kindTableHtml = if ($rulesError) {
  "<div class='warn'><strong>Not assessed:</strong> $(HtmlEncode $rulesError)</div>"
} elseif ($kindCounts.Count -eq 0) {
  "<p><em>No rules returned.</em></p>"
} else {
  $rows = ($kindCounts.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
    "<tr><td>$(HtmlEncode $_.Key)</td><td style='text-align:right'>$(HtmlEncode $_.Value)</td></tr>"
  }) -join "`n"
  @"
<table>
  <tr><th>Rule kind</th><th style='text-align:right'>Count</th></tr>
  $rows
</table>
"@
}

# -------------------------
# Connector health (SentinelHealth)
# -------------------------
$connectorHealthHtml = "<h2>Data connector health (supported connectors only)</h2><p class='muted'>Sourced from <code>SentinelHealth</code>. Health events exist for selected connectors only.</p>"
if (-not $connectorHealthQ -or -not $connectorHealthQ.Success) {
  $err = if ($connectorHealthQ) { $connectorHealthQ.Error } else { "connectorHealth.query.json missing" }
  $connectorHealthHtml += "<div class='warn'><strong>Not assessed:</strong> $(HtmlEncode $err)</div>"
} elseif ($connectorHealthQ.Results.Count -eq 0) {
  $connectorHealthHtml += "<div class='card'><p>No connector health events returned for the selected period.</p></div>"
} else {
  $rows = ($connectorHealthQ.Results | Select-Object -First 25 | ForEach-Object {
    "<tr><td>$(HtmlEncode $_.SentinelResourceName)</td><td>$(HtmlEncode $_.SentinelResourceKind)</td><td>$(HtmlEncode $_.Status)</td><td>$(HtmlEncode $_.Reason)</td><td>$(HtmlEncode $_.TimeGenerated)</td></tr>"
  }) -join "`n"
  $connectorHealthHtml += @"
<div class='card'>
  <table>
    <tr><th>Connector</th><th>Kind</th><th>Status</th><th>Reason</th><th>Last event (UTC)</th></tr>
    $rows
  </table>
</div>
"@
}

# -------------------------
# Automation/playbook health
# -------------------------
$automationHtml = "<h2>Automation rules & playbooks</h2>"
if ($autoRulesError) {
  $automationHtml += "<div class='warn'><strong>Automation rules not assessed:</strong> $(HtmlEncode $autoRulesError)</div>"
} else {
  $automationHtml += "<div class='card'><p><strong>$($autoRules.Count)</strong> automation rule(s) found. <strong>$($playbookRefs.Count)</strong> distinct playbook references extracted (best-effort).</p></div>"
}

if (-not $automationHealthQ -or -not $automationHealthQ.Success) {
  $err = if ($automationHealthQ) { $automationHealthQ.Error } else { "automationHealth.query.json missing" }
  $automationHtml += "<div class='warn'><strong>Automation/playbook health not assessed:</strong> $(HtmlEncode $err)</div>"
} elseif ($automationHealthQ.Results.Count -eq 0) {
  $automationHtml += "<div class='card'><p>No automation/playbook health events returned for the selected period.</p></div>"
} else {
  $rows = ($automationHealthQ.Results | Select-Object -First 30 | ForEach-Object {
    "<tr><td>$(HtmlEncode $_.SentinelResourceType)</td><td>$(HtmlEncode $_.SentinelResourceName)</td><td style='text-align:right'>$(HtmlEncode $_.Failures)</td><td style='text-align:right'>$(HtmlEncode $_.'Partial')</td><td style='text-align:right'>$(HtmlEncode $_.Success)</td><td>$(HtmlEncode $_.LastEvent)</td></tr>"
  }) -join "`n"
  $automationHtml += @"
<div class='card'>
  <table>
    <tr><th>Type</th><th>Name</th><th style='text-align:right'>Failures</th><th style='text-align:right'>Partial</th><th style='text-align:right'>Success</th><th>Last event (UTC)</th></tr>
    $rows
  </table>
</div>
"@
}

# -------------------------
# Playbooks inventory
# -------------------------
$playbooksHtml = "<h2>Playbooks (Logic Apps workflows) inventory</h2>"
if (-not $playbooks -or -not $playbooks.Success) {
  $err = if ($playbooks) { $playbooks.Error } else { "playbooks.json missing" }
  $playbooksHtml += "<div class='warn'><strong>Not assessed:</strong> $(HtmlEncode $err)</div>"
} elseif ($playbooks.Rows.Count -eq 0) {
  $playbooksHtml += "<div class='card'><p>No Logic Apps workflows found in this RG.</p></div>"
} else {
  $rows = ($playbooks.Rows | Sort-Object Name | Select-Object -First 40 | ForEach-Object {
    $ref = if ($playbookRefs.Contains($_.Id)) { "Yes" } else { "No" }
    "<tr><td>$(HtmlEncode $_.Name)</td><td>$ref</td><td>$(HtmlEncode $_.Location)</td></tr>"
  }) -join "`n"
  $playbooksHtml += @"
<div class='card'>
  <p><strong>$($playbooks.Rows.Count)</strong> playbook(s) found. “Referenced” indicates automation linkage only.</p>
  <table>
    <tr><th>Playbook</th><th>Referenced by automation?</th><th>Location</th></tr>
    $rows
  </table>
</div>
"@
}

# -------------------------
# Workbooks inventory
# -------------------------
$workbooksHtml = "<h2>Workbooks inventory (RG resources)</h2><p class='muted'>Lists workbook resources in the resource group. Content Hub install state is not asserted under least privilege.</p>"
if (-not $workbooksResp -or -not $workbooksResp.Success) {
  $err = if ($workbooksResp) { $workbooksResp.Error } else { "workbooks.raw.json missing" }
  $workbooksHtml += "<div class='warn'><strong>Not assessed:</strong> $(HtmlEncode $err)</div>"
} elseif (-not $workbooksResp.Json -or -not $workbooksResp.Json.value -or $workbooksResp.Json.value.Count -eq 0) {
  $workbooksHtml += "<div class='card'><p>No workbooks found in this RG.</p></div>"
} else {
  $rows = ($workbooksResp.Json.value | Select-Object -First 40 | ForEach-Object {
    $dn = $_.properties.displayName
    $cat = $_.properties.category
    $looks = if (($dn -match "Sentinel") -or ($cat -match "sentinel")) { "Likely" } else { "Unknown" }
    "<tr><td>$(HtmlEncode $dn)</td><td>$(HtmlEncode $cat)</td><td>$looks</td><td>$(HtmlEncode $_.location)</td></tr>"
  }) -join "`n"
  $workbooksHtml += @"
<div class='card'>
  <p><strong>$($workbooksResp.Json.value.Count)</strong> workbook(s) found in RG.</p>
  <table>
    <tr><th>Display name</th><th>Category</th><th>Sentinel-related?</th><th>Location</th></tr>
    $rows
  </table>
</div>
"@
}

# -------------------------
# Governance translation
# -------------------------
$governanceHtml = @"
<h2>Governance translation (CAF / NIS2 / UK CSR themes)</h2>
<div class="card">
  <table>
    <tr><th>Technical signal</th><th>CAF framing</th><th>NIS2 theme</th><th>UK CSR theme</th></tr>
    <tr><td>Connector health failures / ingestion gaps</td><td>CAF C + CAF D</td><td>Monitoring, incident handling, continuity</td><td>Operational resilience evidence</td></tr>
    <tr><td>Analytics rule coverage + MITRE gaps</td><td>CAF C</td><td>Risk management measures, monitoring</td><td>Protective monitoring assurance</td></tr>
    <tr><td>Automation rules + playbook linkage + health</td><td>CAF D</td><td>Incident handling, continuity</td><td>Response readiness</td></tr>
    <tr><td>SentinelAudit/SentinelHealth presence</td><td>CAF A + CAF C</td><td>Accountability and logging</td><td>Assurance artefacts</td></tr>
  </table>
</div>
"@

# -------------------------
# KPIs
# -------------------------
$healthStatus = if ($coreHealth -and $coreHealth.SentinelHealth) { $coreHealth.SentinelHealth.Status } else { "Unknown" }
$auditStatus  = if ($coreHealth -and $coreHealth.SentinelAudit)  { $coreHealth.SentinelAudit.Status } else { "Unknown" }

$kpiHtml = @"
<div class="kpi">
  <div class="card"><div class="muted">Analytics rules</div><div class="big">$totalRules</div><div class="muted">Enabled(best-effort): $enabledCount • Disabled(best-effort): $disabledCount</div></div>
  <div class="card"><div class="muted">Data connectors (inventory)</div><div class="big">$connectorInvCount</div><div class="muted">Control-plane resources</div></div>
  <div class="card"><div class="muted">Automation rules</div><div class="big">$($autoRules.Count)</div><div class="muted">Playbook refs: $($playbookRefs.Count)</div></div>
  <div class="card"><div class="muted">SentinelHealth</div><div class="big">$(HtmlEncode $healthStatus)</div></div>
  <div class="card"><div class="muted">SentinelAudit</div><div class="big">$(HtmlEncode $auditStatus)</div></div>
  <div class="card"><div class="muted">Retention</div><div class="big">$($workspace.RetentionInDays) d</div><div class="muted">SKU: $(HtmlEncode $workspace.Sku)</div></div>
</div>
"@

# -------------------------
# Render HTML
# -------------------------
$reportTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
$outPath = Join-Path $RunDir "Sentinel-Assessment-v2.html"

$html = @"
<!doctype html>
<html lang="en-GB">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>Microsoft Sentinel Rapid Assessment (v2)</title>
<style>
  body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #111; line-height: 1.35; }
  h1 { margin: 0 0 6px 0; font-size: 22px; }
  h2 { margin-top: 22px; font-size: 18px; }
  .muted { color:#555; }
  .kpi { display:flex; gap:12px; flex-wrap:wrap; margin-top: 10px; }
  .card { border:1px solid #ddd; border-radius:10px; padding:12px 14px; background:#fff; }
  .big { font-size:20px; font-weight:600; margin-top: 2px; }
  .warn { border:1px solid #ffe1a6; background:#fff7e6; padding:10px; border-radius:10px; }
  table { border-collapse: collapse; width: 100%; margin-top: 8px;}
  th, td { border: 1px solid #e3e3e3; padding: 8px; vertical-align: top; }
  th { background: #f6f6f6; text-align: left; }
  .barRow { display:flex; align-items:center; gap:10px; margin: 6px 0; }
  .barLabel { width: 260px; font-size: 12px; overflow:hidden; text-overflow: ellipsis; white-space: nowrap; }
  .barTrack { flex: 1; background:#f0f0f0; border-radius: 8px; height: 12px; overflow:hidden; }
  .barFill { height: 12px; background:#444; }
  .barValue { width: 90px; text-align:right; font-variant-numeric: tabular-nums; font-size: 12px; }
  code { background:#f6f6f6; padding: 1px 4px; border-radius: 6px; }
</style>
</head>
<body>

<h1>Microsoft Sentinel Rapid Assessment (v2)</h1>
<p class="muted">Generated: $reportTime • Workspace: <code>$(HtmlEncode $workspace.WorkspaceName)</code> • RG: <code>$(HtmlEncode $workspace.ResourceGroupName)</code></p>

$kpiHtml

<h2>Executive summary (≤ 10 minutes)</h2>
<div class="card">
  <ul>
    <li><strong>Detection posture:</strong> $totalRules total analytics rules discovered; enabled/disabled counts are best-effort.</li>
    <li><strong>Ingestion profile:</strong> top data types shown for last <strong>$ingDays</strong> days.</li>
    <li><strong>Connector/automation health:</strong> shown where <code>SentinelHealth</code> data exists and is permitted.</li>
    <li><strong>Automation coverage:</strong> $($autoRules.Count) automation rule(s), $($playbookRefs.Count) playbook reference(s) extracted.</li>
  </ul>
</div>

<h2>Log ingestion profile (Top DataType by GB)</h2>
<p class="muted">Source: Log Analytics <code>Usage</code> table summarised by <code>DataType</code>.</p>
<div class="card">
$ingBarsHtml
</div>

<h2>Analytics rules inventory</h2>
<div class="card">
$kindTableHtml
</div>

<h2>MITRE ATT&CK summary (metadata-based)</h2>
<p class="muted">Gaps are prompts for validation against your threat model; not proof of weakness.</p>
<div class="card">
$mitreGapsHtml
<table>
  <tr><th>Tactic</th><th style='text-align:right'>Rules (metadata)</th></tr>
  $mitreRows
</table>
</div>

<h2>Top techniques (metadata frequency)</h2>
<div class="card">
$techTableHtml
</div>

$connectorHealthHtml
$automationHtml
$playbooksHtml
$workbooksHtml
$governanceHtml

<h2>Scope and limits</h2>
<div class="card">
  <ul>
    <li><strong>Connector health:</strong> uses <code>SentinelHealth</code>; health events exist for selected connectors only.</li>
    <li><strong>Workbooks:</strong> inventory shows workbook resources in this RG; Content Hub install state not asserted under least privilege.</li>
    <li><strong>Playbooks:</strong> inventory is Logic Apps workflows in this RG; referenced-by-automation is best-effort.</li>
    <li><strong>Enablement counts:</strong> enabled/disabled is best-effort; not all rule kinds expose <code>enabled</code> uniformly.</li>
  </ul>
</div>

</body>
</html>
"@

$html | Out-File -FilePath $outPath -Encoding utf8
Write-Host "[INFO] Rendered: $outPath" -ForegroundColor Cyan
