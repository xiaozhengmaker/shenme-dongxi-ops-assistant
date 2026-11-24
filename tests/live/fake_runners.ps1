function New-FakeRunners {
  $map = @{}
  $map["Telegram"] = { param($p,$d) @{ result="complete"; items=@(@{key="tg-1";name="A";dispatched=$true;outcome="joined"},@{key="tg-2";name="B";dispatched=$true;outcome="existing"}) } }.GetNewClosure()
  $map["Steam"] = { param($p,$d) @{ result="complete"; items=@(@{key="st-1";name="C";dispatched=$true;outcome="joined"}) } }.GetNewClosure()
  $map["Facebook"] = { param($p,$d) @{ result="complete"; items=@() } }.GetNewClosure()
  $map["Reddit"] = { param($p,$d) @{ result="complete"; items=@() } }.GetNewClosure()
  $map["WhatsApp"] = { param($p,$d) @{ result="complete"; items=@() } }.GetNewClosure()
  return $map
}