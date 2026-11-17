# lib/ai.ps1 -- OpenAI 兼容调用（DeepSeek / OpenAI / 任何 /chat/completions 端点）
# 配置位置：config.ai = { provider, base_url, model, api_key, temperature, max_batch }

function Get-AiConfig($cfg) {
  $ai = $null
  if ($cfg -and $cfg.ai) { $ai = $cfg.ai }
  if (-not $ai) { return $null }
  $key = [string]$ai.api_key
  if (-not $key) {
    # 允许从环境变量取，避免把 key 写进 config.json
    $envName = [string]$ai.api_key_env
    if ($envName) { $key = [string](Get-Item ("env:" + $envName) -ErrorAction SilentlyContinue).Value }
  }
  if (-not $key) { return $null }
  return [pscustomobject]@{
    provider = [string]$ai.provider
    base_url = if ($ai.base_url) { [string]$ai.base_url } else { "https://api.deepseek.com" }
    model    = if ($ai.model) { [string]$ai.model } else { "deepseek-chat" }
    api_key  = $key
    batch    = if ($ai.max_batch) { [int]$ai.max_batch } else { 10 }
    timeout  = if ($ai.timeout_sec) { [int]$ai.timeout_sec } else { 90 }
    prompts  = $ai.prompts
  }
}

function Test-AiReady($cfg) {
  $a = Get-AiConfig $cfg
  if (-not $a) { return $false }
  return $true
}

function Invoke-AiChat($aiCfg, [string]$system, [string]$user, [switch]$JsonMode) {
  $url = ($aiCfg.base_url.TrimEnd("/")) + "/chat/completions"
  $body = @{
    model    = $aiCfg.model
    messages = @(
      @{ role = "system"; content = $system },
      @{ role = "user";   content = $user }
    )
    temperature = 0.1
    stream      = $false
  }
  if ($JsonMode) { $body["response_format"] = @{ type = "json_object" } }
  $json = $body | ConvertTo-Json -Depth 8 -Compress
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  $headers = @{ "Authorization" = ("Bearer " + $aiCfg.api_key) }
  $lastErr = ""
  for ($try = 1; $try -le 3; $try++) {
    try {
      # 关键：PS 5.1 的 Invoke-RestMethod 不按 charset 解码，中文会变 mojibake -> 自己取字节按 UTF-8 解
      $resp = Invoke-WebRequest -Uri $url -Method Post -Body $bytes -ContentType "application/json; charset=utf-8" -Headers $headers -TimeoutSec $aiCfg.timeout -UseBasicParsing
      $rawBytes = $resp.RawContentStream.ToArray()
      $rawText = [System.Text.Encoding]::UTF8.GetString($rawBytes)
      $r = $rawText | ConvertFrom-Json
      $txt = [string]$r.choices[0].message.content
      $usage = $r.usage
      return [pscustomobject]@{ ok = $true; text = $txt; usage = $usage }
    } catch {
      $lastErr = $_.Exception.Message
      if ($lastErr -match "401|403") { break }
      Start-Sleep -Seconds (2 * $try)
    }
  }
  return [pscustomobject]@{ ok = $false; text = ""; error = $lastErr }
}
