[CmdletBinding()]
param(
  [string]$OutFile = "packaging/SentinelAssessment.bundle.zip"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..") | Select-Object -ExpandProperty Path
$bundle = Join-Path $env:TEMP ("SentinelAssessment.bundle-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

New-Item -ItemType Directory -Path $bundle -Force | Out-Null

Copy-Item -Recurse -Force (Join-Path $root "src")       (Join-Path $bundle "src")
Copy-Item -Recurse -Force (Join-Path $root "templates") (Join-Path $bundle "templates")

# runner
Copy-Item -Force (Join-Path $root "packaging/run.ps1") (Join-Path $bundle "run.ps1")

if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
Compress-Archive -Path (Join-Path $bundle "*") -DestinationPath (Join-Path $root $OutFile) -Force

Write-Host "Built bundle: $OutFile"
