<?php
/** Actual PHP failure producer only; fixture errors and paths never leave this check. */
if(PHP_SAPI!=='cli')exit(2);
$source=file_get_contents(__DIR__.'/windows_phone_catalogue_native.php');
if(preg_match_all('~function catalogue_fixture_failure\(Throwable \$error\):array\{.*?\n\}~s',$source,$matches)!==1)throw new RuntimeException('The actual closed failure producer is ambiguous.');
eval($matches[0][0]);
$checks=0;
foreach([new RuntimeException('PRIVATE-SENTINEL'),new JsonException('PRIVATE-SENTINEL'),new TypeError('PRIVATE-SENTINEL'),new Exception('PRIVATE-SENTINEL')]as$error){
    $value=catalogue_fixture_failure($error);$text=json_encode($value,JSON_THROW_ON_ERROR);
    if(array_keys($value)!==['schema','producer','state','source_basename','source_line','error_type']||$value['schema']!==1||$value['producer']!=='windows_phone_catalogue_native.php'||$value['state']!=='failed'||$value['source_basename']!=='external_component'||$value['source_line']<1||$value['source_line']>100000||str_contains($text,'PRIVATE-SENTINEL')||str_contains($text,__DIR__))throw new RuntimeException('The actual PHP diagnostic exposed nonclosed data.');
    $checks++;
    if($value['error_type']!==($error::class==='Exception'?'external_error':$error::class))throw new RuntimeException('The actual PHP diagnostic type differs.');
    $checks++;
}
// Both preparation and the main operation are inside the actual outer catch.
$tokens=token_get_all($source,TOKEN_PARSE);$tryAt=strpos($source,"try{\n\n\$configPath");
if($tryAt===false||$tryAt>strpos($source,'$config=json_decode')||!str_contains($source,'catalogue_fixture_failure($failure->getPrevious()??$failure)')||!str_contains($source,"'config'=>\$config['openssl_config']"))throw new RuntimeException('The fixture diagnostic preparation/config boundary changed.');
$checks++;
echo 'PASS '.$checks." actual PHP diagnostic producer/type/privacy/preparation controls; no Windows or production operation\n";
