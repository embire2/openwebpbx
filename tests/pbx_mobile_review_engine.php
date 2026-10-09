<?php
/** Native event-socket reply shapes; no database, phone, or network connection. */
if(PHP_SAPI!=='cli'){http_response_code(404);exit;}
class event_socket {
    public static mixed $reply;
    public static array $calls=[];
    public static function api($command){self::$calls[]=['api',$command];return self::$reply;}
    public static function async($command){self::$calls[]=['async',$command];return self::$reply;}
}
require dirname(__DIR__).'/resources/classes/pbx_mobile.php';
class review_engine_fixture extends pbx_mobile {
    public function __construct(){}
    public function send(bool $background):string{return $this->reviewEngine('fixture',$background);}
}
$phone=new review_engine_fixture;$count=0;
set_error_handler(static function($severity,$message){throw new RuntimeException($message);});
foreach([
    [true,['Content-Type'=>'command/reply','Reply-Text'=>'+OK Job-UUID: 11111111-1111-4111-8111-111111111111','Job-UUID'=>'11111111-1111-4111-8111-111111111111'],'+OK Job-UUID: 11111111-1111-4111-8111-111111111111'],
    [true,['Content-Type'=>'command/reply','Reply-Text'=>'-ERR denied'],'-ERR denied'],
    [true,['Content-Type'=>'command/reply'],''],
    [true,false,''],
    [true,'+OK accepted','+OK accepted'],
    [false,'{"row_count":0}','{"row_count":0}'],
    [false,false,''],
] as [$background,$reply,$expected]){
    event_socket::$reply=$reply;
    if($phone->send($background)!==$expected||end(event_socket::$calls)!==[$background?'async':'api','fixture'])throw new RuntimeException('Unexpected engine reply normalization.');
    $count++;
}
restore_error_handler();
echo 'PASS: '.$count." native review engine reply checks\n";
