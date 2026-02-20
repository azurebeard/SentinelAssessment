function Try-RunLaQuery {
  param(
    [Parameter(Mandatory=$true)][Guid]$WorkspaceCustomerId,
    [Parameter(Mandatory=$true)][string]$Query,
    [Parameter(Mandatory=$true)][int]$Days
  )

  try {
    $timeSpan = New-TimeSpan -Days $Days

    $res = Invoke-AzOperationalInsightsQuery `
      -WorkspaceId $WorkspaceCustomerId `
      -Query $Query `
      -Timespan $timeSpan

    return @{
      Success = $true
      Error   = $null
      Results = $res.Results
    }
  }
  catch {
    return @{
      Success = $false
      Error   = $_.Exception.Message
      Results = $null
    }
  }
}
