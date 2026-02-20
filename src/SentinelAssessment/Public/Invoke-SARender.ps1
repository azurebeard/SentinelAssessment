function Invoke-SARender {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$OutDir,
    [Parameter(Mandatory=$true)][string]$TemplatesDir
  )

  $norm = Load-Json (Join-Path $OutDir "normalised.json")
  if (-not $norm) { throw "normalised.json missing. Run Normalise." }

  $template = Join-Path $TemplatesDir "report.v2.html.ps1"
  if (-not (Test-Path $template)) { throw "Template missing: $template" }

  $css = Get-Content (Join-Path $TemplatesDir "styles.css") -Raw

  # Template returns an HTML string
  $html = & $template -Data $norm -Css $css

  $out = Join-Path $OutDir "Sentinel-Assessment-v2.html"
  $html | Out-File -FilePath $out -Encoding utf8
}
