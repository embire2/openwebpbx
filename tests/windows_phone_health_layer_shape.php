<?php
// Actual readonly source summary only; no Windows, database, engine or native calls.
$source=file_get_contents(__DIR__.'/windows_phone_health_layers.php');
$start=strpos($source," \$shape=['valid'=>false");$end=strpos($source,'unset($tree,$data,$host,$m,$shape);',$start);
if($start===false||$end===false)throw new RuntimeException('Exact source summary unavailable.');
$block=substr($source,$start,$end-$start);$checks=0;
$profile=static fn(string $data,string $state='RUNNING',string $type='profile')=>'<profile><type>'.$type.'</type><data>'.htmlspecialchars($data,ENT_XML1).'</data><state>'.$state.'</state></profile>';
$cases=[
 ['<profiles>'.$profile('sip:mod_sofia@127.0.0.1:5060').$profile('sip:mod_sofia@127.0.0.1:5061;transport=tls').'</profiles>',true,2,0],
 ['<profiles>'.$profile('sip:mod_sofia@127.0.0.1:5060').$profile('sip:mod_sofia@10.1.2.3:5080').'</profiles>',false,2,0],
 ['<profiles>'.$profile('sip:mod_sofia@[::1]:5060').'</profiles>',true,1,0],
 ['<profiles>'.$profile('sip:mod_sofia@[fe80::1]:5080').'</profiles>',false,1,0],
 ['<profiles>'.$profile('sip:mod_sofia@127.0.0.1:5060;transport=ws').'</profiles>',false,0,0],
 ['<profiles>'.$profile('malformed').'</profiles>',false,1,1],
 ['<profiles>'.$profile('sip:mod_sofia@127.0.0.1:5060','DOWN').'</profiles>',false,0,0],
 ['<!DOCTYPE profiles><profiles/>',false,0,0],
];
foreach($cases as[$xml,$loopback,$running,$bad]){$out=[];eval($block);$r=$out['sofia_profile_summary'];if($r['loopback_only']!==$loopback||$r['running']!==$running||$r['unparseable']!==$bad)throw new RuntimeException('Closed source classification failed.');$checks++;$encoded=json_encode($r,JSON_THROW_ON_ERROR);if(str_contains($encoded,'mod_sofia')||str_contains($encoded,'127.0.0.1')||str_contains($encoded,'10.1.2.3')||str_contains($encoded,'fe80'))throw new RuntimeException('Raw profile data escaped.');$checks++;}
echo json_encode(['passed'=>true,'checks'=>$checks,'actual_source_summary'=>true,'no_native_or_DB_calls'=>true],JSON_THROW_ON_ERROR),PHP_EOL;
