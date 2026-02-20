<#
.SYNOPSIS
  Sentinel Rapid Assessment v2 (modular) - Orchestrator

.DESCRIPTION
  Runs collection and/or rendering steps with caching to avoid repeated long runs.
  Designed for Azure Cloud Shell PowerShell.

.EXAMPLE
  ./sentinel-assess-v2.ps1 -SubscriptionId "<sub>" -ResourceGroupName "<rg>" -WorkspaceName "<ws>"

.EXAMPLE
  # Collect once, render many times
  ./sentinel-assess-v2.ps1 -SubscriptionId "<sub>" -ResourceGroupName "<rg>" -WorkspaceName "<ws>" -Steps Collect
  ./sentinel-assess-v2.ps1 -SubscriptionId "<sub>" -ResourceGroupName "<rg>" -WorkspaceName "<ws>" -Steps Render -RunId "<existing>"
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$SubscriptionId,
  [Parameter(Mandatory=$true)][string]$ResourceGroupName,
  [Parameter(Mandatory=$true)][string]$WorkspaceName,

  [ValidateSet("Collect","Render","All")]
  [string]$Steps = "All",

  [string]$RunId,

  [ValidateRange(1,365)][int]$DaysIngestionLookback = 30,
  [ValidateRange(1,365)][int]$DaysHealthLookback = 30,

  [string]$OutputRoot = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- API versions (pinned) ---
$script:ApiVersionSecurityInsights = "2025-09-01"
$script:ApiVersionWorkbooks        = "2023-06-01"

function Write-Info($msg){ Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Warn($msg){ Write-Host "[WARN] $msg" -ForegroundColor Yellow }

function Ensure-Folder([string]$Path){
  if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path | Out-Null }
}

function Save-Json($obj, [string]$path){
  $obj | ConvertTo-Json -Depth 60 | Out-File -FilePath $path -Encoding utf8
}

function Load-Json([string]$path){
  if (-not (Test-Path $path)) { return $null }
  Get-Content -Path $path -Raw | ConvertFrom-Json
}

function HtmlEncode([string]$s){
  if ($null -eq $s) { return "" }
  return ($s -replace "&","&amp;" -replace "<","&lt;" -replace ">","&gt;" -replace '"',"&quot;" -replace "'","&#39;")
}

function Invoke-ArmGet {
  param([Parameter(Mandatory=$true)][string]$Uri)
  try {
    $resp = Invoke-AzRestMethod -Method GET -Uri $Uri
    if ($resp.StatusCode -lt 200 -or $resp.StatusCode -ge 300) {
      return @{ Success=$false; Error="ARM GET failed ($($resp.StatusCode)): $($resp.Content)"; Json=$null }
    }
    return @{ Success=$true; Error=$null; Json=($resp.Content | ConvertFrom-Json) }
  } catch {
    return @{ Success=$false; Error=$_.Exception.Message; Json=$null }
  }
}

function Try-RunLaQuery {
  param(
    [Parameter(Mandatory=$true)][Guid]$WorkspaceCustomerId,
    [Parameter(Mandatory=$true)][string]$Query,
    [Parameter(Mandatory=$true)][string]$Timespan
  )
  try {
    $res = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceCustomerId -Query $Query -Timespan $Timespan
    return @{ Success=$true; Error=$null; Results=$res.Results }
  } catch {
    return @{ Success=$false; Error=$_.Exception.Message; Results=$null }
  }
}

function Get-MitreTacticsBaseline {
  @(
    "Reconnaissance","Resource Development","Initial Access","Execution","Persistence",
    "Privilege Escalation","Defense Evasion","Credential Access","Discovery","Lateral Movement",
    "Collection","Command and Control","Exfiltration","Impact"
  )
}

# --- Run folder ---
if (-not $RunId) { $RunId = (Get-Date -Format "yyyyMMdd-HHmmss") }
$runDir = Join-Path $OutputRoot ("out/{0}" -f $RunId)
Ensure-Folder $runDir

Write-Info "RunId: $RunId"
Write-Info "OutDir: $runDir"
Write-Info "Steps: $Steps"

# --- Load module scripts (must exist in same folder) ---
$collectScript = Join-Path $PSScriptRoot "sentinel-assess-v2.collect.ps1"
$renderScript  = Join-Path $PSScriptRoot "sentinel-assess-v2.render.ps1"

if ($Steps -eq "Collect" -or $Steps -eq "All") {
  if (-not (Test-Path $collectScript)) { throw "Missing $collectScript" }
  . $collectScript `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -WorkspaceName $WorkspaceName `
    -RunDir $runDir `
    -DaysIngestionLookback $DaysIngestionLookback `
    -DaysHealthLookback $DaysHealthLookback `
    -ApiVersionSecurityInsights $script:ApiVersionSecurityInsights `
    -ApiVersionWorkbooks $script:ApiVersionWorkbooks
}

if ($Steps -eq "Render" -or $Steps -eq "All") {
  if (-not (Test-Path $renderScript)) { throw "Missing $renderScript" }
  . $renderScript -RunDir $runDir
}

Write-Info "Done. Output folder: $runDir"
