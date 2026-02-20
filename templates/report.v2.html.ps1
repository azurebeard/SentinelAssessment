param(
  [Parameter(Mandatory=$true)]$Data,
  [Parameter(Mandatory=$true)][string]$Css
)

function E([string]$s){
  if ($null -eq $s) { return "" }
  return ($s -replace "&","&amp;" -replace "<","&lt;" -replace ">","&gt;" -replace '"',"&quot;" -replace "'","&#39;")
}

$ws = $Data.meta.workspace
$ing = $Data.ingestion

# Ingestion bars
$bars = ""
if ($ing.status -ne "OK") {
  $bars = "<div class='warn'><strong>Not assessed:</strong> $(E $ing.error)</div>"
} elseif (-not $ing.top -or $ing.top.Count -eq 0) {
  $bars = "<div class='card'><p><em>No ingestion rows returned.</em></p></div>"
} else {
  $max = [Math]::Max(1, ($ing.top | Measure-Object -Property totalGb -Maximum).Maximum)
  foreach ($r in $ing.top) {
    $pct = [Math]::Round(($r.totalGb / $max) * 100, 0)
    $bars += @"
<div class="barRow">
  <div class="barLabel">$(E $r.dataType)</div>
  <div class="barTrack"><div class="barFill" style="width:${pct}%"></div></div>
  <div class="barValue">$(E ($r.totalGb.ToString("0.00"))) GB</div>
</div>
"@
  }
}

@"
<!doctype html>
<html lang="en-GB">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>Microsoft Sentinel Rapid Assessment</title>
<style>
$Css
</style>
</head>
<body>
<h1>Microsoft Sentinel Rapid Assessment</h1>
<p class="muted">
  Generated (UTC): $(E $Data.meta.runGeneratedUtc) • Workspace: <code>$(E $ws.workspaceName)</code> • RG: <code>$(E $ws.resourceGroup)</code>
</p>

<h2>Log ingestion profile (Top DataType by GB)</h2>
<div class="card">
$bars
</div>

<h2>Capabilities and limits</h2>
<div class="card">
  <pre><code>$(E (($Data.meta.capabilities | ConvertTo-Json -Depth 10)))</code></pre>
</div>

</body>
</html>
"@
