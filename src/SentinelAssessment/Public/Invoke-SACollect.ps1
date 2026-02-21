function Invoke-SACollect {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$SubscriptionId,
    [Parameter(Mandatory=$true)][string]$ResourceGroupName,
    [Parameter(Mandatory=$true)][string]$WorkspaceName,
    [Parameter(Mandatory=$true)][string]$OutDir,
    [int]$DaysIngestionLookback = 30,
    [int]$DaysHealthLookback = 30
  )

  New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

  Select-AzSubscription -SubscriptionId $SubscriptionId | Out-Null

  $ws = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName -ErrorAction Stop

  $workspace = [pscustomobject]@{
    subscriptionId = $SubscriptionId
    resourceGroup  = $ResourceGroupName
    workspaceName  = $WorkspaceName
    resourceId     = $ws.ResourceId
    customerId     = $ws.CustomerId
    location       = $ws.Location
    retentionInDays= $ws.RetentionInDays
    sku            = $ws.Sku
    collectedUtc   = (Get-Date).ToUniversalTime().ToString("o")
  }
  Save-Json $workspace (Join-Path $OutDir "raw.workspace.json")

  $caps = Capability-Probe -WorkspaceCustomerId ([Guid]$ws.CustomerId) -WorkspaceResourceId $ws.ResourceId -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName
  Save-Json $caps (Join-Path $OutDir "raw.capabilities.json")

  # --- Move your existing raw collectors here ---
  # KQL: Usage, SentinelHealth, SentinelAudit
  # ARM: alertRules, dataConnectors, automationRules
  # Assets: Logic Apps workflows, Workbooks
  # Save everything as raw.*.json

  # Example: ingestion
  $q = @"
Usage
| where TimeGenerated > ago(${DaysIngestionLookback}d)
| summarize TotalMB=sum(Quantity) by DataType
| sort by TotalMB desc
| take 12
"@
  $ing = Try-RunLaQuery -WorkspaceCustomerId ([Guid]$ws.CustomerId) -Query $q -Days $DaysIngestionLookback
  Save-Json $ing (Join-Path $OutDir "raw.ingestion.query.json")

  # NOTE: keep going with your existing raw calls...
}

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)  # .../src/SentinelAssessment
$kqlCorePack = Join-Path $repoRoot "../../kql/packs/core"
$kqlCorePack = (Resolve-Path $kqlCorePack).Path

Invoke-KqlPack -WorkspaceCustomerId ([Guid]$ws.CustomerId) -PackPath $kqlCorePack -OutDir $OutDir
