<?php
// SPDX-License-Identifier: AGPL-3.0-or-later
/** Bounded, authenticated, read-only local native API client. */
final class windows_public_listener_esl {
    private $socket;private float $deadline;
    public function __construct(string $host,int $port,string $password){
        if(!in_array($host,['127.0.0.1','::1'],true)||$port<1||$port>65535||$password===''||strlen($password)>256||preg_match('/[\r\n\x00]/',$password))throw new RuntimeException('A protected loopback event socket is required.');
        $this->deadline=microtime(true)+15;
        $this->socket=stream_socket_client('tcp://'.($host==='::1'?'[::1]':$host).':'.$port,$errno,$message,2,STREAM_CLIENT_CONNECT);
        if(!$this->socket)throw new RuntimeException('The local native event socket is unavailable.');stream_set_timeout($this->socket,2);
        $hello=$this->frame();if(($hello['content-type']??'')!=='auth/request')throw new RuntimeException('The native event socket did not request authentication.');
        $this->send('auth '.$password);$reply=$this->frame();if(($reply['content-type']??'')!=='command/reply'||($reply['reply-text']??'')!=='+OK accepted')throw new RuntimeException('The native event socket refused authentication.');
    }
    private function send(string $command): void {$bytes=$command."\n\n";while($bytes!==''){if(microtime(true)>$this->deadline)throw new RuntimeException('The native inventory timed out.');$n=fwrite($this->socket,$bytes);if(!$n)throw new RuntimeException('The native event socket write failed.');$bytes=substr($bytes,$n);}}
    private function frame(): array {
        $headers=[];$size=0;
        while(true){if(microtime(true)>$this->deadline)throw new RuntimeException('The native inventory timed out.');$line=fgets($this->socket,8193);if($line===false||($size+=strlen($line))>8192||!str_ends_with($line,"\n"))throw new RuntimeException('The native response headers are invalid.');$line=rtrim($line,"\r\n");if($line==='')break;if(!preg_match('/^([A-Za-z-]+):[\t ]*(.*)$/D',$line,$m)||isset($headers[strtolower($m[1])]))throw new RuntimeException('The native response header is ambiguous.');$headers[strtolower($m[1])]=$m[2];}
        $length=$headers['content-length']??'0';if(!preg_match('/^(0|[1-9][0-9]{0,6})$/D',$length)||(int)$length>262144)throw new RuntimeException('The native response exceeded its bound.');$body='';while(strlen($body)<(int)$length){if(microtime(true)>$this->deadline)throw new RuntimeException('The native inventory timed out.');$part=fread($this->socket,min(8192,(int)$length-strlen($body)));if($part===false||$part==='')throw new RuntimeException('The native response was truncated.');$body.=$part;}$headers['body']=$body;return $headers;
    }
    public function api(string $command): string {$this->send('api '.$command);$response=$this->frame();if(($response['content-type']??'')!=='api/response')throw new RuntimeException('The native API response is invalid.');return $response['body'];}
    public function __destruct(){if(is_resource($this->socket))fclose($this->socket);}
}
