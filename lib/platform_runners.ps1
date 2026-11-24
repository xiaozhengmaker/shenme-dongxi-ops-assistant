function New-PlatformRunners {
  param([string]$HubBase = "http://127.0.0.1:8787", [int]$JoinTimeoutSec = 900)
  $map = @{}
  foreach ($p in @("Facebook","Telegram","Reddit","WhatsApp","Steam")) {
    $plat = $p
    $map[$plat] = {
      param($platform, $DataDir)
      $body = @{ action = "start"; platforms = @($platform); source = "runner" } | ConvertTo-Json -Compress
      $r = Invoke-RestMethod -Uri "$HubBase/control" -Method Post -ContentType "application/json" -Body $body -TimeoutSec 20
      $deadline = (Get-Date).AddSeconds($JoinTimeoutSec)
      while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $s = Invoke-RestMethod -Uri "$HubBase/state" -TimeoutSec 10
        if (-not $s.running) { break }
      }
      $items = @()
      if ($s.ledger) { foreach ($k in $s.ledger.PSObject.Properties.Name) { $l = $s.ledger.$k; $items += @{ key = $k; name = [string]$l.name; dispatched = [bool]$l.dispatched; outcome = [string]$l.outcome } } }
      $res = "complete"
      if ($s.phase -eq "stalled") { $res = "no_candidates" }
      if (@($s.failed) -gt 0 -and @($s.joined) -eq 0) { $res = "platform_failure" }
      @{ result = $res; items = $items; shared = $false }
    }.GetNewClosure()
  }
  return $map
}