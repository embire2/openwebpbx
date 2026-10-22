<?php
/** Bounded local ESL frames; no SIP/event/credential logging. */
final class pbx_windows_health_stream {
    private mixed $socket=null;private string $buffer='';private array $pending=[];
    public function close():void {if(is_resource($this->socket))fclose($this->socket);$this->socket=null;$this->buffer='';$this->pending=[];}
    public function __destruct(){$this->close();}
    public function connect(bool $subscribe=true):void {
        $this->close();$c=config::load();$host=$c->get('switch.event_socket.host',null)??$c->get('event_socket.ip_address',null)??'127.0.0.1';
        $port=(int)($c->get('switch.event_socket.port',null)??$c->get('event_socket.port',null)??8021);$password=$c->get('switch.event_socket.password',null)??$c->get('event_socket.password',null);
        if(!in_array($host,['127.0.0.1','::1','localhost'],true)||$port<1||$port>65535||!is_string($password)||$password===''||preg_match('/[\r\n\x00]/',$password))throw new RuntimeException('Private local event settings required.');
        $errno=0;$error='';$this->socket=@stream_socket_client('tcp://'.($host==='::1'?'[::1]':$host).':'.$port,$errno,$error,3);
        if(!is_resource($this->socket))throw new RuntimeException('The local event service is unavailable.');stream_set_blocking($this->socket,false);
        if(($this->readPacket(3)['Content-Type']??null)!=='auth/request')throw new RuntimeException('The local event service is unavailable.');
        $this->send('auth '.$password);if(($this->readPacket(3)['Reply-Text']??null)!=='+OK accepted')throw new RuntimeException('The local event service is unavailable.');
        if(!$subscribe)return;
        $this->send('event json CUSTOM');$this->reply();
        foreach(['sofia::register_failure','sofia::pre_register','event_guard:phone_health_unblock']as$event){$this->send('filter Event-Subclass '.$event);$this->reply();}
    }
    public static function api(string $command):string {
        if(!in_array($command,['show registrations as json','sofia xmlstatus'],true)&&!preg_match('/^sofia xmlstatus gateway [a-fA-F0-9-]{36}$/D',$command))throw new RuntimeException('An allowed phone health command is required.');
        $client=new self();try{$client->connect(false);$client->send('api '.$command);$r=$client->readPacket(4);if(($r['Content-Type']??null)!=='api/response')throw new RuntimeException('The local phone response is unavailable.');return $r['body'];}finally{$client->close();}
    }
    public static function recovery(string $block,string $recovery):bool {
        if(!is_uuid($block)||!is_uuid($recovery))return false;
        $client=new self();try{$client->connect(false);$client->send("sendevent CUSTOM\nEvent-Name: CUSTOM\nEvent-Subclass: event_guard:phone_health_unblock\nOpenWeb-Phone-Health-Block: ".$block."\nOpenWeb-Phone-Health-Recovery: ".$recovery);$r=$client->readPacket(3);return ($r['Content-Type']??null)==='command/reply'&&preg_match('/^\+OK(?:\s|$)/D',$r['Reply-Text']??'')===1;}finally{$client->close();}
    }
    private function reply():void {
        $deadline=microtime(true)+3;
        do{$r=$this->readPacket(max(.001,$deadline-microtime(true)));if(($r['Content-Type']??null)==='text/event-json'){if(count($this->pending)>=32)throw new RuntimeException('The local event subscription is busy.');$this->pending[]=$r;continue;}
            if(($r['Content-Type']??null)==='command/reply'&&str_starts_with($r['Reply-Text']??'','+OK'))return;break;
        }while(microtime(true)<$deadline);throw new RuntimeException('The local event subscription is unavailable.');
    }
    private function send(string $command):void {$raw=$command."\n\n";$deadline=microtime(true)+3;while($raw!==''){$n=fwrite($this->socket,$raw);if($n===false||microtime(true)>$deadline)throw new RuntimeException('The local event service is unavailable.');if($n===0){usleep(10000);continue;}$raw=substr($raw,$n);}}
    public function packet(float $wait=1):?array {
        if($this->pending)return array_shift($this->pending);return $this->readPacket($wait);
    }
    private function readPacket(float $wait=1):?array {
        $deadline=microtime(true)+$wait;
        do{
            $marker=strpos($this->buffer,"\n\n");$separator=2;$crlf=strpos($this->buffer,"\r\n\r\n");if($crlf!==false&&($marker===false||$crlf<$marker)){$marker=$crlf;$separator=4;}
            if($marker!==false){if($marker>16384)throw new RuntimeException('Local event header exceeded its bound.');$headers=[];foreach(preg_split('/\r?\n/',substr($this->buffer,0,$marker))as$line){if(!str_contains($line,':'))throw new RuntimeException('Invalid local event frame.');[$k,$v]=explode(':',$line,2);$k=trim($k);if(isset($headers[$k]))throw new RuntimeException('Invalid local event frame.');$headers[$k]=trim($v);}
                $size=$headers['Content-Length']??'0';if(!preg_match('/^[0-9]{1,7}$/D',$size)||(int)$size>4194304)throw new RuntimeException('Local event frame exceeded its bound.');$length=$marker+$separator+(int)$size;
                if(strlen($this->buffer)>=$length){$headers['body']=substr($this->buffer,$marker+$separator,(int)$size);$this->buffer=substr($this->buffer,$length);return $headers;}
            }elseif(strlen($this->buffer)>16384)throw new RuntimeException('Local event header exceeded its bound.');
            if(!is_resource($this->socket)||feof($this->socket))throw new RuntimeException('The local event service disconnected.');
            $read=[$this->socket];$write=[];$except=[];$remaining=$deadline-microtime(true);if($remaining<=0)return null;
            if(stream_select($read,$write,$except,0,(int)min(999999,$remaining*1000000))>0){$raw=fread($this->socket,65536);if($raw===false)throw new RuntimeException('The local event service disconnected.');$this->buffer.=$raw;if(strlen($this->buffer)>4210688)throw new RuntimeException('Local event buffer exceeded its bound.');}
        }while(microtime(true)<$deadline);return null;
    }
}
