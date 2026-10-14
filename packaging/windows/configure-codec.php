<?php
/** Select the locally built audio converter; private installation CLI only. */
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
set_exception_handler(static function (Throwable $error): void { fwrite(STDERR,"The Windows audio codec configuration did not complete.\n"); exit(1); });
$web=$argv[1]??'';
require $web.'/resources/require.php';
if(PHP_OS_FAMILY!=='Windows')throw new RuntimeException('This helper is for the Windows call engine.');
$engine=dirname((string)config::load()->get('switch.conf.dir'));
$state=(getenv('ProgramData')?:'C:/ProgramData').'/OpenWebPBX/local-codec.json';
$proof=json_decode(file_get_contents($state),true,512,JSON_THROW_ON_ERROR);
if(($proof['schema']??0)!==1||($proof['callbacks']??'')!=='passed'||($proof['data_imports_and_heap_ownership']??'')!=='passed')throw new RuntimeException('Build and verify the local audio codec first.');
foreach(['mod/mod_bcg729.dll','libbcg729.dll'] as $name){
 if(!is_file($engine.'/'.$name)||!hash_equals((string)($proof['files'][$name]??''),hash_file('sha256',$engine.'/'.$name)))throw new RuntimeException('The installed audio codec changed.');
}
$db=$database->db;$db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);
$db->beginTransaction();
try{
 $db->exec("update v_modules set module_enabled=false where module_name='mod_g729'");
 $statement=$db->prepare("update v_modules set module_enabled=true where module_name='mod_bcg729'");$statement->execute();
 if(!$statement->rowCount()){
  $statement=$db->prepare("insert into v_modules(module_uuid,module_name,module_enabled,module_category,module_description) values(?,'mod_bcg729',true,'Codecs','OpenWeb PBX local audio converter')");$statement->execute([uuid()]);
 }
 $db->commit();
}catch(Throwable $error){$db->rollBack();throw $error;}
$path=(string)config::load()->get('switch.conf.dir').'/autoload_configs/modules.conf.xml';
$text=file_get_contents($path);
if(strlen($text)>1048576||preg_match('/<!\s*(?:DOCTYPE|ENTITY)/i',$text))throw new RuntimeException('The module configuration needs review.');
$document=new DOMDocument();$document->preserveWhiteSpace=true;
if(!$document->loadXML($text,LIBXML_NONET))throw new RuntimeException('The module configuration is malformed.');
$xpath=new DOMXPath($document);
foreach(iterator_to_array($xpath->query('/configuration/modules/load[@module="mod_g729"]')) as $node)$node->parentNode->replaceChild($document->createComment(' OpenWeb PBX local audio converter selected. '),$node);
if(!$xpath->query('/configuration/modules/load[@module="mod_bcg729"]')->length){$load=$document->createElement('load');$load->setAttribute('module','mod_bcg729');$xpath->query('/configuration/modules')->item(0)->appendChild($load);}
if($document->save($path)===false)throw new RuntimeException('The module configuration could not be saved.');
settings::clear_cache();(new cache())->delete('configuration:modules.conf');
echo "The local audio converter is enabled.\n";
