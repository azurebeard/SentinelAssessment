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
