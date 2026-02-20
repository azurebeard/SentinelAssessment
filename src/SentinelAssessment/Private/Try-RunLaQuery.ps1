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
