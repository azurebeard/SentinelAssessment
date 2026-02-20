function Save-Json($obj, [string]$path){
  $obj | ConvertTo-Json -Depth 60 | Out-File -FilePath $path -Encoding utf8
}
