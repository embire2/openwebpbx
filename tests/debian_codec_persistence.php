<?php
/** Real PostgreSQL + native module XML generation; isolated schema and files only. */
if(PHP_SAPI!=='cli'){http_response_code(404);exit;}
require dirname(__DIR__).'/resources/require.php';
require dirname(__DIR__).'/packaging/debian/normalize-codec-modules.php';
$db=$database->db;$db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);
$schema='openweb_codec_test_'.bin2hex(random_bytes(6));
$root=sys_get_temp_dir().'/'.$schema;mkdir($root,0700);mkdir($root.'/autoload_configs',0700);mkdir($root.'/mod',0700);
$path=$root.'/autoload_configs/modules.conf.xml';$converter=$root.'/mod/mod_bcg729.so';
foreach(['mod_bcg729','mod_g729','mod_sofia'] as $name)file_put_contents($root.'/mod/'.$name.'.so','synthetic module marker');
$checks=0;
$check=function(bool $ok,string $message)use(&$checks){if(!$ok)throw new RuntimeException($message);$checks++;};
$q=function(string $sql,array $p=[])use($db){$s=$db->prepare($sql);$s->execute($p);return $s;};
$publicBefore=hash('sha256',json_encode($q('select * from public.v_modules order by module_uuid')->fetchAll(PDO::FETCH_ASSOC)));
$names=function()use($path){$doc=new DOMDocument();$doc->load($path);$x=new DOMXPath($doc);$out=[];foreach($x->query('/configuration/modules/load') as $n)$out[]=$n->getAttribute('module');sort($out);return $out;};
try{
 $db->exec('create schema '.$schema);$db->exec('set search_path to '.$schema.',public');
 $db->exec('create table v_modules (like public.v_modules including all)');
 foreach(['mod_g729','mod_bcg729','mod_sofia'] as $name)$q("insert into v_modules(module_uuid,module_name,module_label,module_category,module_order,module_enabled,module_default_enabled,module_description) values(?,?,?,'Codecs',800,true,true,'Preserve module metadata')",[uuid(),$name,$name]);
 // Exercise the actual get_modules/synch/xml methods used by --defaults. Avoid
 // the constructor's live engine socket, and route only module SQL to the schema.
 $reflection=new ReflectionClass('modules');$module=$reflection->newInstanceWithoutConstructor();
 $moduleDb=new class($db){
  public function __construct(private PDO $db){}
  public function select($sql,$parameters=null,$return='all'){
   if(!preg_match('/^select \* from v_modules\s/i',$sql)||$return!=='all')throw new RuntimeException('Unexpected native module query.');
   $s=$this->db->prepare($sql);$s->execute($parameters??[]);return $s->fetchAll(PDO::FETCH_ASSOC);
  }
  public function save($data){throw new RuntimeException('Default synchronization must preserve existing module rows.');}
 };
 $moduleSettings=new class($root){public function __construct(private string $root){}public function get($category,$name){if($category==='switch'&&$name==='conf')return $this->root;throw new RuntimeException('Unexpected module setting.');}};
 $reflection->getProperty('database')->setValue($module,$moduleDb);$reflection->getProperty('settings')->setValue($module,$moduleSettings);$module->dir=$root.'/mod';
 $regenerate=function()use($module){$module->get_modules();$module->synch();$module->xml();};
 $xml='<configuration name="modules.conf"><modules><load module="mod_bcg729"/><load module="mod_sofia"/></modules></configuration>';
 file_put_contents($path,$xml);
 // Reproduce 1.0.5: XML is repaired already, then --defaults reconstructs it
 // from still-enabled database rows and resurrects the conflicting module.
 $check(!openweb_normalize_codec_modules($path,$converter),'An already repaired XML file changed.');
 $regenerate();$check($names()===['mod_bcg729','mod_g729','mod_sofia'],'The historical defaults-regeneration failure was not reproduced.');
 $before=$q("select * from v_modules where module_name<>'mod_g729' order by module_name")->fetchAll(PDO::FETCH_ASSOC);
 $passthrough=$q("select * from v_modules where module_name='mod_g729'")->fetch(PDO::FETCH_ASSOC);
 // Same ordered calls as candidate bootstrap: normalize XML, persist source.
 $check(openweb_normalize_codec_modules($path,$converter),'Active XML conflict was not normalized.');
 $check(openweb_normalize_codec_module_settings($db,$converter),'Enabled database conflict was not normalized.');
 $regenerate();$check($names()===['mod_bcg729','mod_sofia'],'Native defaults regeneration re-enabled passthrough after migration.');
 $after=$q("select * from v_modules where module_name='mod_g729'")->fetch(PDO::FETCH_ASSOC);$passthrough['module_enabled']=false;
 $check($after===$passthrough,'Migration changed more than the passthrough enabled flag.');
 $check($q("select * from v_modules where module_name<>'mod_g729' order by module_name")->fetchAll(PDO::FETCH_ASSOC)===$before,'Converter or unrelated module settings changed.');
 $check(!openweb_normalize_codec_modules($path,$converter)&&!openweb_normalize_codec_module_settings($db,$converter),'Repeated bootstrap was not idempotent.');
 $regenerate();$regenerate();$check($names()===['mod_bcg729','mod_sofia'],'Repeated defaults generation restored the conflict.');
 // Exact deployed failure: XML already fixed, but both database rows enabled.
 $db->exec("update v_modules set module_enabled=true where module_name='mod_g729'");
 $check(!openweb_normalize_codec_modules($path,$converter)&&openweb_normalize_codec_module_settings($db,$converter),'Already repaired XML bypassed database normalization.');
 $regenerate();$check($names()===['mod_bcg729','mod_sofia'],'Already repaired XML lost its fix on regeneration.');
 $db->exec("update v_modules set module_enabled=(module_name<>'mod_bcg729')");
 $check(!openweb_normalize_codec_module_settings($db,$converter),'A disabled converter disabled passthrough.');
 $regenerate();$check($names()===['mod_g729','mod_sofia'],'Passthrough-only installation lost its codec.');
 $db->exec("update v_modules set module_enabled=true");unlink($converter);
 $check(!openweb_normalize_codec_module_settings($db,$converter),'An absent converter binary disabled passthrough.');
 $regenerate();$check(in_array('mod_g729',$names(),true),'Missing-converter installation lost passthrough.');
 $publicAfter=hash('sha256',json_encode($q('select * from public.v_modules order by module_uuid')->fetchAll(PDO::FETCH_ASSOC)));
 $check(hash_equals($publicBefore,$publicAfter),'Installed module settings changed during an isolated test.');
 echo 'PASS: '.$checks." PostgreSQL codec persistence and actual defaults/XML regeneration checks\n";
}finally{
 if($db->inTransaction())$db->rollBack();$db->exec('set search_path to public');$db->exec('drop schema if exists '.$schema.' cascade');
 $it=new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root,FilesystemIterator::SKIP_DOTS),RecursiveIteratorIterator::CHILD_FIRST);
 foreach($it as $file)$file->isDir()?rmdir($file->getPathname()):unlink($file->getPathname());rmdir($root);
}
