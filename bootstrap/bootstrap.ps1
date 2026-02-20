[CmdletBinding()]
param(
  [ValidateSet("Release","Branch")]
  [string]$Mode = "Release",

  [string]$Org = "azurebeard",
  [string]$Repo = "SentinelAssessment",
  [string]$Branch = "main",

  # If Mode=Release and Version not specified -> latest
  [string]$Version = "latest",

  # Run parameters
  [Parameter(Mandatory=$false)][string]$SubscriptionId,
  [Parameter(Mandatory=$false)][string]$ResourceGroupName,
  [Parameter(Mandatory=$false)][string]$WorkspaceName,

  [ValidateSet("All","Collect","Normalize","Render")]
  [string]$Steps = "All",

  [int]$DaysIngestionLookback = 30,
  [int]$DaysHealthLookback = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info($m){ Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Write-Warn($m){ Write-Host "[WARN] $m" -ForegroundColor Yellow }

$WorkDir = Join-Path $HOME "sentinel-assessment"
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
Set-Location $WorkDir

Write-Info "WorkDir: $WorkDir"
Write-Info "Mode: $Mode"

function Download-File([string]$Url, [string]$OutFile){
  Write-Info "Downloading: $Url"
  if (Get-Command curl -ErrorAction SilentlyContinue) {
    curl -fsSL $Url -o $OutFile
  } else {
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
  }
  if (-not (Test-Path $OutFile)) { throw "Download failed: $Url" }
}

function Expand-Zip([string]$Zip, [string]$Dest){
  if (Test-Path $Dest) { Remove-Item $Dest -Recurse -Force }
  New-Item -ItemType Directory -Path $Dest -Force | Out-Null
  Expand-Archive -Path $Zip -DestinationPath $Dest -Force
}

$BundleDir = Join-Path $WorkDir "bundle"

if ($Mode -eq "Branch") {
  # Pull a prebuilt bundle file from the branch (you’ll commit one), OR download module+templates raw.
  # Easiest: commit a branch bundle at /packaging/SentinelAssessment.bundle.zip
  $BundleZip = Join-Path $WorkDir "SentinelAssessment.bundle.zip"
  $bundleUrl = "https://raw.githubusercontent.com/$Org/$Repo/$Branch/packaging/SentinelAssessment.bundle.zip"
  Download-File $bundleUrl $BundleZip
  Expand-Zip $BundleZip $BundleDir
}
else {
  # Release mode: fetch latest (or specific tag) release asset.
  # NOTE: We avoid complex GitHub API parsing here by letting you keep a stable "latest bundle" URL.
  # Best practice: attach SentinelAssessment.bundle.zip to every GitHub Release.
  # For latest, you can use the GitHub "latest download" endpoint.
  $BundleZip = Join-Path $WorkDir "SentinelAssessment.bundle.zip"
  if ($Version -eq "latest") {
    $bundleUrl = "https://github.com/$Org/$Repo/releases/latest/download/SentinelAssessment.bundle.zip"
  } else {
    $bundleUrl = "https://github.com/$Org/$Repo/releases/download/$Version/SentinelAssessment.bundle.zip"
  }
  Download-File $bundleUrl $BundleZip
  Expand-Zip $BundleZip $BundleDir
}

# Bundle contains:
#  - src/SentinelAssessment module folder
#  - templates
#  - run.ps1 (small runner wrapper)
$Runner = Join-Path $BundleDir "run.ps1"
if (-not (Test-Path $Runner)) { throw "Bundle missing run.ps1 at $Runner" }

# If user didn’t pass runtime params, prompt minimally (Cloud Shell friendly)
if (-not $SubscriptionId)    { $SubscriptionId    = Read-Host "SubscriptionId" }
if (-not $ResourceGroupName) { $ResourceGroupName = Read-Host "ResourceGroupName" }
if (-not $WorkspaceName)     { $WorkspaceName     = Read-Host "WorkspaceName" }

Write-Info "Launching runner..."
& $Runner `
  -SubscriptionId $SubscriptionId `
  -ResourceGroupName $ResourceGroupName `
  -WorkspaceName $WorkspaceName `
  -Steps $Steps `
  -DaysIngestionLookback $DaysIngestionLookback `
  -DaysHealthLookback $DaysHealthLookback `
  -WorkDir $WorkDir `
  -BundleDir $BundleDir
