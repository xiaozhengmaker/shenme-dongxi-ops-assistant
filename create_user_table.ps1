param([switch]$DryRun)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib\feishu.ps1")
$cfg = Get-Content (Join-Path $PSScriptRoot "config.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$tok = Get-FsToken
$hdr = @{ Authorization = "Bearer $tok"; "Content-Type" = "application/json; charset=utf-8" }
$app = $cfg.feishu.base_app_token

$fields = @(
  @{ field_name = "平台";     type = 3; property = @{ options = @(@{name="Telegram"},@{name="Facebook"}) } },
  @{ field_name = "群ID";     type = 1 },
  @{ field_name = "群名";     type = 1 },
  @{ field_name = "用户ID";   type = 1 },
  @{ field_name = "用户名";   type = 1 },
  @{ field_name = "昵称";     type = 1 },
  @{ field_name = "语言";     type = 1 },
  @{ field_name = "角色";     type = 3; property = @{ options = @(@{name="管理员"},@{name="普通成员"}) } },
  @{ field_name = "最近活跃"; type = 5; property = @{ date_formatter = "yyyy/MM/dd" } },
  @{ field_name = "采集日";   type = 5; property = @{ date_formatter = "yyyy/MM/dd" } },
  @{ field_name = "来源";     type = 3; property = @{ options = @(@{name="成员页"},@{name="互动者"},@{name="种子"}) } },
  @{ field_name = "状态";     type = 3; property = @{ options = @(@{name="有效"},@{name="疑似失效"}) } }
)
$body = @{ table = @{ name = "用户样本"; default_view_name = "全部样本"; fields = $fields } } | ConvertTo-Json -Depth 12
if ($DryRun) { $body; return }
$r = Invoke-RestMethod -Uri "https://open.feishu.cn/open-apis/bitable/v1/apps/$app/tables" -Method Post -Headers $hdr -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 30
if ($r.code -ne 0) { "ERR code=$($r.code) msg=$($r.msg)"; return }
"table_id=" + $r.data.table_id
"name=" + $r.data.name