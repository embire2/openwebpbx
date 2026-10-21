# Read the owned local IIS listener through normal CA/name-verified TLS.
# This performs no DNS lookup, proxy request or certificate-policy override.
function Get-OpenWebReadinessWait([Diagnostics.Stopwatch]$Timer){
 $remaining=10000-$Timer.ElapsedMilliseconds
 if($remaining -le 0){throw [TimeoutException]::new('The local web readiness deadline expired.')}
 return [int][Math]::Min(3000,$remaining)
}
function ConvertFrom-OpenWebChunkedBody([byte[]]$Body,[Diagnostics.Stopwatch]$Timer){
 $cursor=0;$chunks=0;$decoded=[IO.MemoryStream]::new()
 try{
  while($cursor -lt $Body.Length -and $chunks -lt 8192){
   $null=Get-OpenWebReadinessWait $Timer
   $chunks++;$start=$cursor
   while($cursor+1 -lt $Body.Length -and !($Body[$cursor] -eq 13 -and $Body[$cursor+1] -eq 10)){if($cursor-$start -gt 128){throw 'Invalid HTTP chunk header.'};$cursor++}
   if($cursor+1 -ge $Body.Length){throw 'Incomplete HTTP chunk header.'}
   $line=[Text.Encoding]::ASCII.GetString($Body,$start,$cursor-$start);$match=[regex]::Match($line,'^([A-Fa-f0-9]{1,8})(?:;[\x20-\x7e]{0,120})?$')
   if(!$match.Success){throw 'Invalid HTTP chunk size.'};$size=[Convert]::ToInt64($match.Groups[1].Value,16);$cursor+=2
   if($size -eq 0){
    if($Body.Length-$cursor -gt 16384){throw 'Oversized HTTP trailers.'}
    $trailers=[Text.Encoding]::ASCII.GetString($Body,$cursor,$Body.Length-$cursor)
    if($trailers -cnotmatch '^(?:[!#$%&''*+.^_`|~0-9A-Za-z-]+:[\x20-\x7e]*\r\n)*\r\n$'){throw 'Invalid HTTP trailers.'}
    return ,$decoded.ToArray()
   }
   if($size -gt 1MB -or $decoded.Length+$size -gt 1MB -or $cursor+$size+2 -gt $Body.Length){throw 'Oversized or incomplete HTTP chunk.'}
   $decoded.Write($Body,$cursor,[int]$size);$cursor+=[int]$size
   if($Body[$cursor] -ne 13 -or $Body[$cursor+1] -ne 10){throw 'Invalid HTTP chunk ending.'};$cursor+=2
  }
  throw 'Incomplete HTTP chunked body.'
 }finally{$decoded.Dispose()}
}
function Test-OpenWebTrustedLogin([string]$Hostname,[int]$Port){
 if($Hostname -cnotmatch '^[A-Za-z0-9.-]{1,253}$' -or $Port -lt 1 -or $Port -gt 65535){return $false}
 $timer=[Diagnostics.Stopwatch]::StartNew();$tcp=$null;$ssl=$null;$response=$null
 try{
  $tcp=[Net.Sockets.TcpClient]::new();$tcp.ReceiveTimeout=3000;$tcp.SendTimeout=3000
  if(!$tcp.ConnectAsync('127.0.0.1',$Port).Wait((Get-OpenWebReadinessWait $timer))){return $false}
  $ssl=[Net.Security.SslStream]::new($tcp.GetStream(),$false);$ssl.ReadTimeout=3000;$ssl.WriteTimeout=3000
  $authentication=$ssl.AuthenticateAsClientAsync($Hostname)
  if(!$authentication.Wait((Get-OpenWebReadinessWait $timer))){return $false};$null=$authentication.GetAwaiter().GetResult()
  if(!$ssl.IsAuthenticated -or !$ssl.IsEncrypted){return $false}
  $request=[Text.Encoding]::ASCII.GetBytes("GET /login.php HTTP/1.1`r`nHost: ${Hostname}:$Port`r`nAccept: text/html`r`nAccept-Encoding: identity`r`nConnection: close`r`n`r`n")
  $ssl.WriteTimeout=Get-OpenWebReadinessWait $timer;$ssl.Write($request,0,$request.Length);$ssl.Flush();$response=[IO.MemoryStream]::new();$buffer=New-Object byte[] 8192
  do{
   $ssl.ReadTimeout=Get-OpenWebReadinessWait $timer;$count=$ssl.Read($buffer,0,$buffer.Length)
   if($response.Length+$count -gt 1MB+65536){return $false};if($count){$response.Write($buffer,0,$count)}
  }while($count -gt 0)
  $wire=$response.ToArray();$headerEnd=-1
  for($i=0;$i+3 -lt $wire.Length -and $i -lt 65536;$i++){if($wire[$i] -eq 13 -and $wire[$i+1] -eq 10 -and $wire[$i+2] -eq 13 -and $wire[$i+3] -eq 10){$headerEnd=$i;break}}
  if($headerEnd -lt 1){return $false};$headers=[Text.Encoding]::ASCII.GetString($wire,0,$headerEnd)
  if($headers -cnotmatch '^HTTP/1\.[01] 200(?: |\r\n)' -or $headers -notmatch '(?im)^Content-Type:\s*text/html(?:\s*;|\s*$)'){return $false}
  if($headers -match '(?im)^Content-Encoding:' -and $headers -notmatch '(?im)^Content-Encoding:\s*identity\s*$'){return $false}
  $body=New-Object byte[] ($wire.Length-$headerEnd-4);[Buffer]::BlockCopy($wire,$headerEnd+4,$body,0,$body.Length)
  $transfer=@([regex]::Matches($headers,'(?im)^Transfer-Encoding:\s*([^\r\n]+)'))
  $length=@([regex]::Matches($headers,'(?im)^Content-Length:\s*([^\r\n]*)'))
  if($transfer.Count){if($transfer.Count -ne 1 -or $length.Count -or $transfer[0].Groups[1].Value.Trim() -ine 'chunked'){return $false};$body=ConvertFrom-OpenWebChunkedBody $body $timer}
  else{
   if($length.Count -gt 1 -or ($length.Count -eq 1 -and ($length[0].Groups[1].Value.Trim() -cnotmatch '^[0-9]{1,10}$' -or [long]$length[0].Groups[1].Value -ne $body.Length))){return $false}
  }
  if($body.Length -gt 1MB){return $false};$html=[Text.UTF8Encoding]::new($false,$true).GetString($body)
  $null=Get-OpenWebReadinessWait $timer
  return $html -match '<form\b' -and $html -match 'name=["'']username["'']' -and $html -match 'name=["'']password["'']'
 }catch{return $false}
 finally{if($tcp){$tcp.Dispose()};if($ssl){$ssl.Dispose()};if($response){$response.Dispose()};$timer.Stop()}
}
