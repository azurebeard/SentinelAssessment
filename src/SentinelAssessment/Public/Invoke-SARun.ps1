function Invoke-SARun {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$SubscriptionId,
    [Parameter(Mandatory=$true)][string]$ResourceGroupName,
    [Parameter(Mandatory=$true)][string]$WorkspaceName,
    [Parameter(Mandatory=$true)][string]$OutDir,
    [Parameter(Mandatory=$true)][string]$TemplatesDir,

    [ValidateSet("All","Collect","Normalise","Render")]
    [string]$Steps = "All",

    [int]$DaysIngestionLookback = 30,
    [int]$DaysHealthLookback = 30
  )

  if ($Steps -in @("All","Collect")) {
    Invoke-SACollect -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -OutDir $OutDir -DaysIngestionLookback $DaysIngestionLookback -DaysHealthLookback $DaysHealthLookback
  }

  if ($Steps -in @("All","Normalise")) {
    Invoke-SANormalise -OutDir $OutDir
  }

  if ($Steps -in @("All","Render")) {
    Invoke-SARender -OutDir $OutDir -TemplatesDir $TemplatesDir
  }
}
