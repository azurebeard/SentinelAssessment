function Load-Json([string]$path){
  if (-not (Test-Path $path)) { return $null }
  Get-Content -Path $path -Raw | ConvertFrom-Json
}
