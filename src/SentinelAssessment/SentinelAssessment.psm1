$public  = Join-Path $PSScriptRoot 'Public'
$private = Join-Path $PSScriptRoot 'Private'

Get-ChildItem -Path $private -Filter *.ps1 -File | ForEach-Object { . $_.FullName }
Get-ChildItem -Path $public  -Filter *.ps1 -File | ForEach-Object { . $_.FullName }
