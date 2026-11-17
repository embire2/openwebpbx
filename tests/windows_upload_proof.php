<?php
/** Platform-independent verification of the actual IIS handoff proof policy. */
require dirname(__DIR__).'/resources/classes/pbx_upload_gate.php';
$method=new ReflectionMethod(pbx_upload_gate::class,'verifyWindowsProof');
$key=str_repeat('a',64);$now=1794940000;$checks=0;
$server=['HTTP_X_OPENWEB_ADMISSION_URI'=>'/api/v2/instance/backups/import','CONTENT_LENGTH'=>'4096'];
$sign=static function(array $input,int $issued)use($key):array{$input['HTTP_X_OPENWEB_ADMISSION']=$issued.'.'.hash_hmac('sha256',$issued."\n".$input['HTTP_X_OPENWEB_ADMISSION_URI']."\n".$input['CONTENT_LENGTH'],$key);return $input;};
$verify=static function(array $input,bool $expected,string $label)use($method,$key,$now,&$checks):void{if($method->invoke(null,$input,$key,$now)!==$expected)throw new RuntimeException($label);$checks++;};
$good=$sign($server,$now);$verify($good,true,'Current exact proof');
$verify($sign($server,$now-61),false,'Expired proof');$verify($sign($server,$now+61),false,'Future proof');
$verify($good+['REQUEST_URI'=>'/api/v2/upload.php?route=/instance/backups/import'],true,'CGI rewrite keeps authenticated original route');
foreach(['HTTP_X_OPENWEB_ADMISSION_URI'=>'/api/v2/tenants/01234567-0123-0123-0123-012345678901/backups/import','CONTENT_LENGTH'=>'8192','HTTP_X_OPENWEB_ADMISSION'=>str_repeat('x',64)]as$name=>$value){$changed=$good;$changed[$name]=$value;$verify($changed,false,'Changed '.$name);}
foreach(['/api/v2/index.php?route=/instance/backups/import','/api/v2/instance/backups/import?x=1','/%61pp/pbx_protection/upload.php','/api/v2/instance/backups/import%00',"/api/v2/instance/backups/import\n",'/app/pbx_protection/upload.php?tenant=%30']as$uri){$changed=$server;$changed['HTTP_X_OPENWEB_ADMISSION_URI']=$uri;$verify($sign($changed,$now),false,'Noncanonical route');}
foreach(['/app/pbx_protection/upload.php','/app/pbx_protection/upload.php?tenant=','/app/pbx_protection/upload.php?tenant=01234567-0123-0123-0123-012345678901','/api/v2/tenants/01234567-0123-0123-0123-012345678901/backups/import']as$uri){$changed=$server;$changed['HTTP_X_OPENWEB_ADMISSION_URI']=$uri;$verify($sign($changed,$now),true,'Exact supported stream route');}
$verify([],false,'No module proof');$verify($server,false,'No signature');
echo "PASS $checks actual Windows upload proof controls; no request body or database read.\n";
