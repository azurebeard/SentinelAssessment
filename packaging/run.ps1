[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$SubscriptionId,
  [Parameter(Mandatory=$true)][string]$ResourceGroupName,
  [Parameter(Mandatory=$true)][string]$WorkspaceName,

  [ValidateSet("All","Collect","Normalise","Render")]
  [string]$Steps = "All",

  [int]$DaysIngestionLookback = 30,
  [int]$DaysHealthLookback = 30,

  [Parameter(Mandatory=$true)][string]$WorkDir,
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$OutDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info($m){ Write-Host "[INFO] $m" -ForegroundColor Cyan }

# Import module from repo
$modulePath = Join-Path $RepoRoot "src/SentinelAssessment/SentinelAssessment.psd1"
if (-not (Test-Path $modulePath)) { throw "Module not found: $modulePath" }

Import-Module $modulePath -Force

$templatesDir = Join-Path $RepoRoot "templates"
if (-not (Test-Path $templatesDir)) { throw "Templates dir not found: $templatesDir" }

Write-Info "Running pipeline..."
Invoke-SARun `
  -SubscriptionId $SubscriptionId `
  -ResourceGroupName $ResourceGroupName `
  -WorkspaceName $WorkspaceName `
  -Steps $Steps `
  -OutDir $OutDir `
  -TemplatesDir $templatesDir `
  -DaysIngestionLookback $DaysIngestionLookback `
  -DaysHealthLookback $DaysHealthLookback

# Zip output for download
$zip = Join-Path $WorkDir ("SentinelAssessment-{0}.zip" -f (Split-Path $OutDir -Leaf))
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path @($OutDir) -DestinationPath $zip -Force

Write-Info "ZIP created: $zip"
Write-Info "HTML: $(Join-Path $OutDir 'Sentinel-Assessment-v2.html')"
