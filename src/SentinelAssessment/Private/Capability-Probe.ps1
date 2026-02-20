function Capability-Probe {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][Guid]$WorkspaceCustomerId,
    [Parameter(Mandatory=$true)][string]$WorkspaceResourceId,
    [Parameter(Mandatory=$true)][string]$SubscriptionId,
    [Parameter(Mandatory=$true)][string]$ResourceGroupName
  )

  $caps = [ordered]@{
    kql = [ordered]@{ canQueryUsage=$false; canQuerySentinelHealth=$false; canQuerySentinelAudit=$false }
    arm = [ordered]@{ canListAlertRules=$false; canListConnectors=$false; canListAutomationRules=$false; canListWorkbooks=$false }
    assets = [ordered]@{ canListLogicApps=$false }
    notes = @()
  }

  # KQL probes (cheap)
  $u = Try-RunLaQuery -WorkspaceCustomerId $WorkspaceCustomerId -Query "Usage | take 1" -Timespan "P7D"
  $caps.kql.canQueryUsage = [bool]$u.Success

  $h = Try-RunLaQuery -WorkspaceCustomerId $WorkspaceCustomerId -Query "SentinelHealth | take 1" -Timespan "P30D"
  $caps.kql.canQuerySentinelHealth = [bool]$h.Success

  $a = Try-RunLaQuery -WorkspaceCustomerId $WorkspaceCustomerId -Query "SentinelAudit | take 1" -Timespan "P30D"
  $caps.kql.canQuerySentinelAudit = [bool]$a.Success

  # ARM probes (safe GET lists)
  $siBase = "https://management.azure.com$WorkspaceResourceId/providers/Microsoft.SecurityInsights"
  $v = "2025-09-01"
  $r1 = Invoke-ArmGet -Uri "$siBase/alertRules?api-version=$v"
  $caps.arm.canListAlertRules = [bool]$r1.Success

  $r2 = Invoke-ArmGet -Uri "$siBase/dataConnectors?api-version=$v"
  $caps.arm.canListConnectors = [bool]$r2.Success

  $r3 = Invoke-ArmGet -Uri "$siBase/automationRules?api-version=$v"
  $caps.arm.canListAutomationRules = [bool]$r3.Success

  $wb = Invoke-ArmGet -Uri "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/workbooks?api-version=2023-06-01"
  $caps.arm.canListWorkbooks = [bool]$wb.Success

  # Assets probe
  try {
    $null = Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType "Microsoft.Logic/workflows" -ErrorAction Stop
    $caps.assets.canListLogicApps = $true
  } catch {
    $caps.assets.canListLogicApps = $false
  }

  return $caps
}
