@{
  RootModule        = 'SentinelAssessment.psm1'
  ModuleVersion     = '0.1.0'
  GUID              = 'f3d3c5c7-1b9a-4c88-9a1e-7b5c1b2c9d0a'
  Author            = 'azurebeard'
  CompanyName       = 'azurebeard'
  PowerShellVersion = '7.0'
  FunctionsToExport = @(
    'Invoke-SACollect',
    'Invoke-SANormalise',
    'Invoke-SARender',
    'Invoke-SARun'
  )
}
