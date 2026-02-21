function Invoke-SARender {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$OutDir,
    [Parameter(Mandatory=$true)][string]$TemplatesDir
  )

  $norm = Load-Json (Join-Path $OutDir "normalised.json")
  
  if (-not $norm) { throw "normalised.json missing. Run Normalise." }

  function HtmlEncode([string]$s) {
    if ($null -eq $s) { return "" }
      return [System.Web.HttpUtility]::HtmlEncode($s)
  }

  function SafeArray($x) {
    if ($null -eq $x) { return @() }
      return @($x)
  }

  function BadgeHtml([string]$status) {
    switch ($status) {
      "OK"      { return "<span class='badge ok'>OK</span>" }
      "Skipped" { return "<span class='badge warn'>Skipped</span>" }
      "Error"   { return "<span class='badge err'>Error</span>" }
      default   { return "<span class='badge neutral'>" + (HtmlEncode $status) + "</span>" }
    }
  }
  
  $template = Join-Path $TemplatesDir "report.v2.html.ps1"
  if (-not (Test-Path $template)) { throw "Template missing: $template" }

  $css = Get-Content (Join-Path $TemplatesDir "styles.css") -Raw

  # Template returns an HTML string
  $html = & $template -Data $norm -Css $css

  $out = Join-Path $OutDir "Sentinel-Assessment-v2.html"
  $html | Out-File -FilePath $out -Encoding utf8
}
