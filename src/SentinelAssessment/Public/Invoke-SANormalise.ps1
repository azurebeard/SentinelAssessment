function Invoke-SANormalise {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$OutDir
  )

  $rawWs   = Load-Json (Join-Path $OutDir "raw.workspace.json")
  $rawCaps = Load-Json (Join-Path $OutDir "raw.capabilities.json")

  $norm = [ordered]@{
    meta = [ordered]@{
      runGeneratedUtc = (Get-Date).ToUniversalTime().ToString("o")
      workspace = $rawWs
      capabilities = $rawCaps
      tool = @{ name="SentinelAssessment"; schemaVersion="1.0" }
    }
    ingestion = @{ lookbackDays = $null; top = @(); status="NotAssessed"; error=$null }
    connectors = @{ inventory=@(); health=@(); status="NotAssessed"; error=$null }
    detections = @{ rules=@(); counts=@{}; mitre=@{ tactics=@(); techniques=@() }; status="NotAssessed"; error=$null }
    automation = @{ rules=@(); playbooks=@(); health=@(); status="NotAssessed"; error=$null }
    workbooks  = @{ inventory=@(); status="NotAssessed"; error=$null }
    errors     = @()
  }

  # Normalize ingestion query -> always array
  $rawIng = Load-Json (Join-Path $OutDir "raw.ingestion.query.json")
  if ($rawIng -and $rawIng.Success) {
    $norm.ingestion.status = "OK"
    $norm.ingestion.lookbackDays = $rawWs ? $null : $null # optional
    $rows = As-Array $rawIng.Results
    $norm.ingestion.top = @(
      foreach ($r in $rows) {
        [ordered]@{
          dataType = $r.DataType
          totalGb  = [math]::Round(([double]$r.TotalMB / 1024.0), 2)
        }
      }
    )
  } else {
    $norm.ingestion.status = "NotAssessed"
    $norm.ingestion.error  = $rawIng.Error
  }

  # TODO: normalize the rest (connectors, rules, automation, workbooks, playbooks, health)
  # Key principle: every collection becomes { status, error, rows[] }, and rows is ALWAYS an array.

  Save-Json $norm (Join-Path $OutDir "normalised.json")
}
