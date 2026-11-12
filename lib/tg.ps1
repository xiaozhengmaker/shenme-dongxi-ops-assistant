# tg.ps1 -- Telegram Web 内部 API 客户端（通过 CDP 在页面上下文调用，不占前台）
# 依赖：调试端口 Chrome 已打开 https://web.telegram.org 且已登录

$script:CdpCall = "D:\DeepSeek\运营\cdp_call.ps1"
$script:TgMatch = "web.telegram"

function Invoke-TgJs {
  param([string]$Js)
  $expr = $Js
  $payload = @{}
  $payload.Add("expression", $expr)
  $payload.Add("awaitPromise", $true)
  $payload.Add("returnByValue", $true)
  $json = $payload | ConvertTo-Json -Depth 5
  $raw = & $script:CdpCall -Method "Runtime.evaluate" -ParamsJson $json -Match $script:TgMatch
  if (-not $raw) { throw "empty CDP response" }
  $obj = $raw | ConvertFrom-Json
  if ($obj.exceptionDetails) { throw ("JS error: " + ($obj.exceptionDetails.text)) }
  return $obj.result.value
}

function Get-TgSelfId {
  $js = "(async()=>{const am=rootScope.managers.apiManager;const r=await am.invokeApi('users.getFullUser',{id:{_: 'inputUserSelf'}});return String(r.users[0].id)})()"
  return Invoke-TgJs $js
}

function Search-Tg {
  param([string]$Query, [int]$Limit = 20)
  $q = $Query.Replace("'", "\'")
  $js = @"
(async()=>{const am=rootScope.managers.apiManager;
const r=await am.invokeApi('contacts.search',{q:'$q',limit:$Limit});
return JSON.stringify((r.chats||[]).map(c=>({id:String(c.id),title:c.title,u:c.username||'',n:c.participants_count||0,mg:!!c.megagroup,bc:!!c.broadcast})))})()
"@
  $val = Invoke-TgJs $js
  if (-not $val) { return @() }
  return $val | ConvertFrom-Json
}

function Join-Tg {
  param([string]$Username, [string]$ChatId, [string]$SelfId)
  if (-not $SelfId) { $SelfId = Get-TgSelfId }
  $u = $Username
  $cid = $ChatId
  $js = @"
(async()=>{const am=rootScope.managers.apiManager;
let chat=null;
try{
  if('$u'){const r=await am.invokeApi('contacts.resolveUsername',{username:'$u'});chat=(r.chats&&r.chats[0])||null;}
}catch(e){return 'resolve_err:'+String(e&&e.message||e);}
if(!chat && '$cid'){ chat={id:'$cid',_: 'chat'}; }
if(!chat) return 'not_found';
try{
  if(chat._==='channel'){
    const inp={_: 'inputChannel', channel_id: chat.id, access_hash: chat.access_hash};
    await am.invokeApi('channels.joinChannel',{channel:inp});
  }else{
    const inp={_: 'inputChat', chat_id: chat.id, access_hash: chat.access_hash};
    await am.invokeApi('messages.addChatUser',{chat_id:inp,user_id:'$SelfId',fwd_limit:0});
  }
  return 'joined';
}catch(e){
  const m=String(e&&e.message||e);
  if(m.indexOf('USER_ALREADY_PARTICIPANT')>=0) return 'already';
  if(m.indexOf('INVITE_REQUEST_SENT')>=0) return 'request_sent';
  if(m.indexOf('CHANNELS_TOO_MUCH')>=0) return 'too_many';
  if(m.indexOf('FLOOD_WAIT')>=0) return 'flood:'+m;
  return 'err:'+m;
}})()
"@
  return Invoke-TgJs $js
}
