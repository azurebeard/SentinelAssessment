<#
.SYNOPSIS
  Sentinel Rapid Assessment v2 - Collector (read-only)

.DESCRIPTION
  Collects and caches:
   - workspace.json
   - ingestion.json (Usage -> DataType)
   - core-health.json (SentinelHealth/SentinelAudit presence)
   - alertRules.raw.json
   - dataConnectors.raw.json
   - automationRules.raw.json
   - connectorHealth.query.json (SentinelHealth resource type: Data connector)
   - automationHealth.query.json (SentinelHealth resource type: Automation rule / Playbook)
   - playbooks.json (Logic Apps workflows in RG)
   - workbooks.raw.json (Microsoft.Insights/workbooks in RG)

  Designed for Azure Cloud Shell PowerShell.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$SubscriptionId,
  [Parameter(Mandatory=$true)][string]$ResourceGroupName,
  [Parameter(Mandatory=$true)][string]$WorkspaceName,
  [Parameter(Mandatory=$true)][string]$RunDir,

  [ValidateRange(1,365)][int]$DaysIngestionLookback,
  [ValidateRange(1,365)][int]$DaysHealthLookback,

  [Parameter(Mandatory=$true)][string]$ApiVersionSecurityInsights,
  [Parameter(Mandatory=$true)][string]$ApiVersionWorkbooks
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Helpers are defined in orchestrator and available in scope when dot-sourced:
# Write-Info, Write-Warn, Save-Json, Invoke-ArmGet, Try-RunLaQuery, Summarize, etc.
# We do not redefine them here to keep it small.

function Summarize-TablePresence($result){
  if (-not $result.Success) {
    return @{ Status="Not assessed"; Details=$result.Error; Events=$null; LastEvent=$null }
  }
  $row = $result.Results | Select-Object -First 1
  if ($null -eq $row -or ($row.PSObject.Properties.Name -notcontains "Events")) {
    return @{ Status="No data returned"; Details="Query succeeded but returned no rows. Table may be empty or not yet created."; Events=$null; LastEvent=$null }
  }
  return @{ Status="Data present"; Details=""; Events=[int]$row.Events; LastEvent=$row.LastEvent }
}

# -------------------------
# 0) Subscription + workspace resolve
# -------------------------
Write-Info "Selecting subscription $SubscriptionId"
Select-AzSubscription -SubscriptionId $SubscriptionId | Out-Null

Write-Info "Resolving workspace $WorkspaceName in RG $ResourceGroupName"
$ws = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName -ErrorAction Stop

$workspace = [pscustomobject]@{
  WorkspaceName = $WorkspaceName
  ResourceGroupName = $ResourceGroupName
  SubscriptionId = $SubscriptionId
  ResourceId = $ws.ResourceId
  CustomerId = $ws.CustomerId
  Location = $ws.Location
  RetentionInDays = $ws.RetentionInDays
  Sku = $ws.Sku
}

Save-Json $workspace (Join-Path $RunDir "workspace.json")

$workspaceCustomerId = [Guid]$workspace.CustomerId
$workspaceResourceId = $workspace.ResourceId
$siBase = "https://management.azure.com$workspaceResourceId/providers/Microsoft.SecurityInsights"

# -------------------------
# 1) Ingestion profile (Usage -> DataType)
# -------------------------
Write-Info "Collecting ingestion profile last $DaysIngestionLookback days"
$tsIngest = ("P{0}D" -f $DaysIngestionLookback)
$ingQuery = @"
Usage
| where TimeGenerated > ago(${DaysIngestionLookback}d)
| summarize TotalMB = sum(Quantity) by DataType
| sort by TotalMB desc
| take 12
"@

$ing = Try-RunLaQuery -WorkspaceCustomerId $workspaceCustomerId -Query $ingQuery -Timespan $tsIngest
$ingOut = [pscustomobject]@{
  Success = $ing.Success
  Error   = $ing.Error
  IngestionDays = $DaysIngestionLookback
  Rows    = @()
}

if ($ing.Success -and $ing.Results) {
  $ingOut.Rows = $ing.Results | ForEach-Object {
    [pscustomobject]@{
      DataType = $_.DataType
      TotalGB  = [Math]::Round(([double]$_.TotalMB / 1024.0), 2)
    }
  }
}
Save-Json $ingOut (Join-Path $RunDir "ingestion.json")

# -------------------------
# 2) Baseline tables presence: SentinelHealth + SentinelAudit
# -------------------------
Write-Info "Collecting SentinelHealth/SentinelAudit presence last $DaysHealthLookback days"
$tsHealth = ("P{0}D" -f $DaysHealthLookback)

$healthQuery = @"
SentinelHealth
| where TimeGenerated > ago(${DaysHealthLookback}d)
| summarize Events=count(), LastEvent=max(TimeGenerated)
"@
$auditQuery = @"
SentinelAudit
| where TimeGenerated > ago(${DaysHealthLookback}d)
| summarize Events=count(), LastEvent=max(TimeGenerated)
"@

$health = Try-RunLaQuery -WorkspaceCustomerId $workspaceCustomerId -Query $healthQuery -Timespan $tsHealth
$audit  = Try-RunLaQuery -WorkspaceCustomerId $workspaceCustomerId -Query $auditQuery  -Timespan $tsHealth

$coreHealth = [pscustomobject]@{
  HealthDays = $DaysHealthLookback
  SentinelHealth = (Summarize-TablePresence $health)
  SentinelAudit  = (Summarize-TablePresence $audit)
}
Save-Json $coreHealth (Join-Path $RunDir "core-health.json")

# -------------------------
# 3) Sentinel control-plane inventories
# -------------------------
Write-Info "Collecting analytics rules (alertRules)"
$alertRulesUri = "$siBase/alertRules?api-version=$ApiVersionSecurityInsights"
$alertRulesResp = Invoke-ArmGet -Uri $alertRulesUri
Save-Json $alertRulesResp (Join-Path $RunDir "alertRules.raw.json")

Write-Info "Collecting data connectors (dataConnectors)"
$dataConnectorsUri = "$siBase/dataConnectors?api-version=$ApiVersionSecurityInsights"
$dataConnectorsResp = Invoke-ArmGet -Uri $dataConnectorsUri
Save-Json $dataConnectorsResp (Join-Path $RunDir "dataConnectors.raw.json")

Write-Info "Collecting automation rules (automationRules)"
$automationRulesUri = "$siBase/automationRules?api-version=$ApiVersionSecurityInsights"
$automationRulesResp = Invoke-ArmGet -Uri $automationRulesUri
Save-Json $automationRulesResp (Join-Path $RunDir "automationRules.raw.json")

# -------------------------
# 4) Connector-specific health (SentinelHealth)
# -------------------------
Write-Info "Collecting connector health (SentinelHealth) last $DaysHealthLookback days"
$connectorHealthQuery = @"
SentinelHealth
| where TimeGenerated > ago(${DaysHealthLookback}d)
| where SentinelResourceType == "Data connector"
| summarize arg_max(TimeGenerated, Status, Reason, Description, ExtendedProperties, SentinelResourceKind) by SentinelResourceName
| project SentinelResourceName, SentinelResourceKind, Status, Reason, TimeGenerated,
         DestinationTable=tostring(ExtendedProperties.DestinationTable),
         Description=tostring(Description)
| order by Status asc, TimeGenerated desc
"@
$connectorHealth = Try-RunLaQuery -WorkspaceCustomerId $workspaceCustomerId -Query $connectorHealthQuery -Timespan $tsHealth
Save-Json $connectorHealth (Join-Path $RunDir "connectorHealth.query.json")

# -------------------------
# 5) Automation + playbook health (SentinelHealth)
# -------------------------
Write-Info "Collecting automation/playbook health (SentinelHealth) last $DaysHealthLookback days"
$automationHealthQuery = @"
SentinelHealth
| where TimeGenerated > ago(${DaysHealthLookback}d)
| where SentinelResourceType in ("Automation rule","Playbook")
| summarize Failures=countif(Status == "Failure"),
            Partial=countif(Status == "Partial success"),
            Success=countif(Status == "Success"),
            LastEvent=max(TimeGenerated)
          by SentinelResourceType, SentinelResourceName
| order by Failures desc, Partial desc, LastEvent desc
"@
$automationHealth = Try-RunLaQuery -WorkspaceCustomerId $workspaceCustomerId -Query $automationHealthQuery -Timespan $tsHealth
Save-Json $automationHealth (Join-Path $RunDir "automationHealth.query.json")

# -------------------------
# 6) Playbooks inventory (Logic Apps workflows) in RG
# -------------------------
Write-Info "Collecting playbooks inventory (Logic Apps workflows) in RG"
$playbooksOut = @{
  Success = $true
  Error = $null
  Rows = @()
}

try {
  $logicApps = Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType "Microsoft.Logic/workflows" -ErrorAction Stop
  $playbooksOut.Rows = $logicApps | ForEach-Object {
    [pscustomobject]@{
      Name = $_.Name
      Id = $_.ResourceId
      Location = $_.Location
      Tags = if ($_.Tags) { ($_.Tags | ConvertTo-Json -Compress -Depth 6) } else { "" }
    }
  }
} catch {
  $playbooksOut.Success = $false
  $playbooksOut.Error = $_.Exception.Message
}

Save-Json $playbooksOut (Join-Path $RunDir "playbooks.json")

# -------------------------
# 7) Workbooks inventory (Microsoft.Insights/workbooks) in RG
# -------------------------
Write-Info "Collecting workbooks inventory (ARM) in RG"
$workbooksUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/workbooks?api-version=$ApiVersionWorkbooks"
$workbooksResp = Invoke-ArmGet -Uri $workbooksUri
Save-Json $workbooksResp (Join-Path $RunDir "workbooks.raw.json")

Write-Info "Collector completed. Cached JSON written to $RunDir"
