<?php
/** Actual native-variable producer and music fragment compatibility; private files only. */
if(PHP_SAPI!=='cli')exit(2);
$root=dirname(__DIR__);require $root.'/resources/classes/pbx_paths.php';require $root.'/resources/classes/pbx_music.php';
set_error_handler(static function(int $level,string $message,string $file,int $line): never {throw new ErrorException($message,0,$level,$file,$line);});
$base=sys_get_temp_dir().'/openweb-native-music-'.bin2hex(random_bytes(8));mkdir($base,0700);$conf=$base.'/conf';mkdir($conf,0700);$vars=$conf.'/vars.xml';$checks=0;
$check=static function(bool $value,string $name)use(&$checks): void {if(!$value)throw new RuntimeException($name);$checks++;};
try{
    // Extract only the actual producer function; resources/switch.php normally
    // bootstraps a live application at file scope, which this test never does.
    $source=file_get_contents($root.'/resources/switch.php');$needle='function save_var_xml() {';
    $start=strpos($source,$needle);$end=strpos($source,"\n}\n",$start);
    $check(substr_count($source,$needle)===1&&$start!==false&&$end!==false,'Actual variable producer is unique');
    eval(substr($source,$start,$end+2-$start));
    $settings=new class($conf){public function __construct(public string $path){}public function get(...$args): string{return $this->path;}};$config=$settings;$domain_uuid=null;
    $database=new class {public function select($sql,$parameters,$mode): array {return [
        ['var_category'=>'Music on Hold','var_command'=>'set','var_name'=>'hold_music','var_value'=>'local_stream://default'],
        ['var_category'=>'Defaults','var_command'=>'set','var_name'=>'fixture_keep','var_value'=>'keep-exactly']];}};
    save_var_xml();$fragment=file_get_contents($vars);
    $document=new DOMDocument();$previous=libxml_use_internal_errors(true);
    try{$whole=$document->loadXML($fragment,LIBXML_NONET);$errors=libxml_get_errors();}
    finally{libxml_clear_errors();libxml_use_internal_errors($previous);}
    $check(!$whole&&count($errors)>0&&$errors[0]->code===5,'Actual producer demonstrates old single-document refusal');
    $check(substr_count($fragment,'<X-PRE-PROCESS')===2&&!str_contains($fragment,'<include>'),'Actual producer writes a native fragment');
    $check(pbx_music::nativeDefault($vars,$conf),'Actual producer fragment installs stock native music');
    $expected=str_replace('hold_music=local_stream://default','hold_music=local_stream://openweb',$fragment);
    $check(file_get_contents($vars)===$expected,'Generated fragment bytes preserved except exact stock value');
    $check(!str_contains($expected,'openweb_music_fragment'),'Synthetic validation wrapper is never persisted');
    $check(!pbx_music::nativeDefault($vars,$conf)&&file_get_contents($vars)===$expected,'Repeat preserves native fragment exactly');
    $custom=str_replace('hold_music=local_stream://default','hold_music=local_stream://operator-choice',$fragment);file_put_contents($vars,$custom);
    $check(!pbx_music::nativeDefault($vars,$conf)&&file_get_contents($vars)===$custom,'Custom native fragment remains byte-identical');
    $wholeXml="<?xml version=\"1.0\"?>\n<include>\n".$fragment."</include>\n";file_put_contents($vars,$wholeXml);
    $check(pbx_music::nativeDefault($vars,$conf)&&file_get_contents($vars)===str_replace('hold_music=local_stream://default','hold_music=local_stream://openweb',$wholeXml),'Existing whole-document path remains exact');
    $singleQuotes="<!-- keep -->\n<X-PRE-PROCESS cmd='set' data='hold_music=local_stream://default'/>\n<X-PRE-PROCESS cmd='set' data='fixture_keep=exact'/>\n";file_put_contents($vars,$singleQuotes);
    $check(pbx_music::nativeDefault($vars,$conf)&&file_get_contents($vars)===str_replace('hold_music=local_stream://default','hold_music=local_stream://openweb',$singleQuotes),'Single-quoted fragment replacement preserves bytes');
    $reject=static function(string $xml,string $name)use($vars,$conf,$check): void {
        file_put_contents($vars,$xml);$before=hash_file('sha256',$vars);$refused=false;
        try{pbx_music::nativeDefault($vars,$conf);}catch(RuntimeException){$refused=true;}
        $check($refused,$name.' refused');$check(hash_file('sha256',$vars)===$before,$name.' leaves original bytes intact');
        $check(glob($vars.'.music-*')===[],$name.' leaves no temporary publication file');
    };
    $reject($fragment."<unexpected/>\n",'Other top-level fragment element');
    $reject($fragment."not-native-whitespace\n",'Top-level nonwhitespace');
    $reject("<?fixture keep-private?>\n".$fragment,'Fragment processing instruction');
    $reject("<?xml version=\"1.0\"?>\n".$fragment,'Multiple roots with document declaration');
    $reject("<!DOCTYPE root SYSTEM \"https://example.invalid/private\">\n".$fragment,'External DTD');
    $reject("<!DOCTYPE root [<!ENTITY fixture \"private\">]>\n".$fragment,'Entity declaration');
    $reject($fragment."<X-PRE-PROCESS cmd=\"set\" data=\"hold_music=local_stream://default\"/>\n",'Ambiguous duplicate stock target');
    $reject($fragment."<!-- data=\"hold_music=local_stream://default\" -->\n",'Ambiguous textual replacement');
    $reject($fragment."<X-PRE-PROCESS><unexpected/></X-PRE-PROCESS>\n",'Nested fragment instruction');
    $reject($fragment."<!-- invalid--comment -->\n",'Malformed comment');
    $reject($fragment."<X-PRE-PROCESS\n",'Malformed fragment');
    $reject(str_repeat(' ',1048577),'Oversized native file');
    $outside=$base.'/outside.xml';file_put_contents($outside,$fragment);$refused=false;
    try{pbx_music::nativeDefault($outside,$conf);}catch(RuntimeException){$refused=true;}
    $check($refused&&file_get_contents($outside)===$fragment,'Outside configuration root refused without mutation');
    if(PHP_OS_FAMILY!=='Windows'){
        $link=$conf.'/linked.xml';symlink($outside,$link);$refused=false;
        try{pbx_music::nativeDefault($link,$conf);}catch(RuntimeException){$refused=true;}
        $check($refused&&file_get_contents($outside)===$fragment,'Linked native file refused');unlink($link);
    }
    echo 'PASS '.$checks." actual-producer/native-music fragment, exact-byte/custom/bounds/DTD/entity/path controls; no PBX/database accessed\n";
}finally{
    $files=new RecursiveIteratorIterator(new RecursiveDirectoryIterator($base,FilesystemIterator::SKIP_DOTS),RecursiveIteratorIterator::CHILD_FIRST);
    foreach($files as $file){if($file->isDir()&&!$file->isLink())rmdir($file->getPathname());else unlink($file->getPathname());}rmdir($base);restore_error_handler();
}
