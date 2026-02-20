[CmdletBinding()]
param(
  # Repo
  [string]$Org = "azurebeard",
  [string]$Repo = "SentinelAssessment",
  [string]$Branch = "main",

  # Run parameters
  [Parameter(Mandatory=$false)][string]$SubscriptionId,
  [Parameter(Mandatory=$false)][string]$ResourceGroupName,
  [Parameter(Mandatory=$false)][string]$WorkspaceName,

  [ValidateSet("All","Collect","Normalise","Render")]
  [string]$Steps = "All",

  [int]$DaysIngestionLookback = 30,
  [int]$DaysHealthLookback = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info($m){ Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Write-Warn($m){ Write-Host "[WARN] $m" -ForegroundColor Yellow }

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

# Persistent Cloud Shell home
$WorkDir = Join-Path $HOME "sentinel-assessment"
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
Set-Location $WorkDir

Write-Info "WorkDir: $WorkDir"
Write-Info "Repo: $Org/$Repo (branch: $Branch)"

# Download repo branch ZIP
$RepoZip = Join-Path $WorkDir "$Repo-$Branch.zip"
$ArchiveUrl = "https://github.com/$Org/$Repo/archive/refs/heads/$Branch.zip"
Download-File $ArchiveUrl $RepoZip

# Extract
$ExtractDir = Join-Path $WorkDir "repo"
Expand-Zip $RepoZip $ExtractDir

# GitHub ZIP root folder is typically Repo-Branch
$RepoRoot = Join-Path $ExtractDir "$Repo-$Branch"
if (-not (Test-Path $RepoRoot)) {
  # fallback: take first directory
  $RepoRoot = (Get-ChildItem -Path $ExtractDir -Directory | Select-Object -First 1).FullName
}
Write-Info "RepoRoot: $RepoRoot"

# Expect packaging/run.ps1 to exist in repo
$Runner = Join-Path $RepoRoot "packaging/run.ps1"
if (-not (Test-Path $Runner)) {
  throw "Runner not found: $Runner. Ensure packaging/run.ps1 exists in the repo."
}

# Prompt only if missing (Cloud Shell friendly)
if (-not $SubscriptionId)    { $SubscriptionId    = Read-Host "SubscriptionId" }
if (-not $ResourceGroupName) { $ResourceGroupName = Read-Host "ResourceGroupName" }
if (-not $WorkspaceName)     { $WorkspaceName     = Read-Host "WorkspaceName" }

# Prepare output dir for this run
$RunId  = (Get-Date -Format "yyyyMMdd-HHmmss")
$OutDir = Join-Path $WorkDir ("out/{0}" -f $RunId)
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

Write-Info "RunId: $RunId"
Write-Info "OutDir: $OutDir"
Write-Info "Steps: $Steps"

# Execute runner from extracted repo
& $Runner `
  -SubscriptionId $SubscriptionId `
  -ResourceGroupName $ResourceGroupName `
  -WorkspaceName $WorkspaceName `
  -Steps $Steps `
  -DaysIngestionLookback $DaysIngestionLookback `
  -DaysHealthLookback $DaysHealthLookback `
  -WorkDir $WorkDir `
  -RepoRoot $RepoRoot `
  -OutDir $OutDir

Write-Info "Done."
Write-Info "HTML: $(Join-Path $OutDir 'Sentinel-Assessment-v2.html')"
