<?php
/** Bundled public-domain music, installed locally and served by the native stream. */
class pbx_music {
    public const STREAM='openweb';
    public static function file(): string {return pbx_paths::storage().'/openweb-music/16000/lofi-beat-loop-schmoop.wav';}
    /** Change only the stock native default; leave all custom choices and other XML bytes intact. */
    public static function nativeDefault(string $vars,string $conf): bool {
        if(PHP_SAPI!=='cli')throw new RuntimeException('Instance installation is required.');
        if($conf===''||is_link($vars)||!pbx_paths::contains($conf,$vars)||!is_file($vars)||filesize($vars)>1048576)throw new RuntimeException('The installed native variable file is unavailable.');
        $xml=file_get_contents($vars);
        if(preg_match('/<!\s*(?:DOCTYPE|ENTITY)/i',$xml))throw new RuntimeException('The native variable file is unsafe.');
        $document=new DOMDocument();$previous=libxml_use_internal_errors(true);
        try{
            if(!$document->loadXML($xml,LIBXML_NONET)){
                // save_var_xml() writes native preprocessor fragments, without
                // an enclosing document. Validate that exact shape in memory;
                // never serialize or persist this temporary wrapper.
                libxml_clear_errors();
                if(!$document->loadXML('<openweb_music_fragment>'.$xml.'</openweb_music_fragment>',LIBXML_NONET))throw new RuntimeException('The native variable file is invalid.');
                $elements=0;
                foreach($document->documentElement->childNodes as $node){
                    if($node->nodeType===XML_COMMENT_NODE)continue;
                    if($node->nodeType===XML_TEXT_NODE&&trim($node->textContent)==='')continue;
                    if($node->nodeType!==XML_ELEMENT_NODE||$node->nodeName!=='X-PRE-PROCESS'||$node->hasChildNodes())throw new RuntimeException('The native variable file is invalid.');
                    $elements++;
                }
                if($elements===0)throw new RuntimeException('The native variable file is invalid.');
            }
        }
        finally{libxml_clear_errors();libxml_use_internal_errors($previous);}
        $xpath=new DOMXPath($document);$stock=$xpath->query('//X-PRE-PROCESS[@cmd="set" and @data="hold_music=local_stream://default"]');
        if($stock->length>1)throw new RuntimeException('The stock music default is ambiguous.');
        if($stock->length===0)return false;
        $next=preg_replace('/(\bdata\s*=\s*[\x22\x27])hold_music=local_stream:\/\/default([\x22\x27])/','$1hold_music=local_stream://openweb$2',$xml,-1,$count);
        if($count!==1)throw new RuntimeException('The stock music default could not be updated.');
        $temporary=$vars.'.music-'.bin2hex(random_bytes(8));
        try{
            $f=fopen($temporary,'x');if(!$f)throw new RuntimeException('The native music default could not be saved.');
            try{if(fwrite($f,$next)!==strlen($next)||!fflush($f)||(function_exists('fsync')&&!fsync($f)))throw new RuntimeException('The native music default could not be saved.');}
            finally{fclose($f);}
            if(!rename($temporary,$vars))throw new RuntimeException('The native music default could not be published.');
        }finally{if(is_file($temporary))unlink($temporary);}
        return true;
    }
    private static function prepared(string $bundle,string $sourceHash): array {
        $root=realpath($bundle);$manifest=$bundle.'/bundle-manifest.json';
        if($root===false||!is_dir($root)||is_link($bundle)||is_link($manifest)||!is_file($manifest)||filesize($manifest)>65536)throw new RuntimeException('Prepared hold music is unavailable.');
        $data=json_decode(file_get_contents($manifest),true,32,JSON_THROW_ON_ERROR);
        if(($data['schema']??null)!==1||!is_string($data['source_sha256']??null)||!hash_equals($sourceHash,$data['source_sha256']))throw new RuntimeException('Prepared hold music source failed verification.');
        $files=[];
        foreach([8000,16000,32000,48000] as $rate){
            $entry=$data['rates'][(string)$rate]??[];$name=$rate.'/lofi-beat-loop-schmoop.wav';$path=$root.'/'.$name;
            if(($entry['path']??null)!==$name||!is_file($path)||is_link($path)||!pbx_paths::contains($root,$path)||filesize($path)!==($entry['bytes']??null)||!is_string($entry['sha256']??null)||!hash_equals($entry['sha256'],hash_file('sha256',$path)))throw new RuntimeException('Prepared hold music failed verification.');
            $files[$rate]=$path;
        }
        return $files;
    }
    public static function install(?PDO $db=null,?string $preparedBundle=null): void {
        if(PHP_SAPI!=='cli')throw new RuntimeException('Instance installation is required.');
        $db??=database::new()->db;$source=PROJECT_ROOT.'/resources/music-on-hold/lofi-beat-loop-schmoop.wav';
        $manifest=json_decode(file_get_contents(PROJECT_ROOT.'/resources/music-on-hold/manifest.json'),true,32,JSON_THROW_ON_ERROR);
        if(!hash_equals($manifest['files']['lofi-beat-loop-schmoop.wav']['sha256']??'',hash_file('sha256',$source)))throw new RuntimeException('Bundled music failed verification.');
        // Windows packages carry these exact rates so installation needs no
        // shell, converter PATH lookup or additional binary dependency.
        $prepared=$preparedBundle===null?null:self::prepared($preparedBundle,hash_file('sha256',$source));
        if(PHP_OS_FAMILY==='Windows'&&$prepared===null)throw new RuntimeException('Use the complete Windows release music bundle.');
        $root=pbx_paths::storage().'/openweb-music';
        foreach([8000,16000,32000,48000] as $rate){
            $dir=$root.'/'.$rate;if(!is_dir($dir)&&!mkdir($dir,0755,true))throw new RuntimeException('Hold music directory is unavailable.');
            $file=$dir.'/lofi-beat-loop-schmoop.wav';$temporary=$dir.'/track-'.bin2hex(random_bytes(8)).'.wav';
            if($prepared!==null||$rate===16000){if(!copy($prepared[$rate]??$source,$temporary))throw new RuntimeException('Hold music could not be installed.');}
            else{
                $process=proc_open(['sox',$source,'-r',(string)$rate,$temporary,'rate','-v',(string)$rate],[0=>['file',PHP_OS_FAMILY==='Windows'?'NUL':'/dev/null','r'],1=>['pipe','w'],2=>['pipe','w']],$pipes);
                if(!is_resource($process))throw new RuntimeException('Install the sox audio converter.');
                stream_get_contents($pipes[1]);stream_get_contents($pipes[2]);fclose($pipes[1]);fclose($pipes[2]);if(proc_close($process)!==0){@unlink($temporary);throw new RuntimeException('Hold music conversion failed.');}
            }
            chmod($temporary,0644);if(!rename($temporary,$file))throw new RuntimeException('Hold music could not be installed.');
            $q=$db->prepare("select music_on_hold_uuid from v_music_on_hold where domain_uuid is null and music_on_hold_name=? and music_on_hold_rate=?");$q->execute([self::STREAM,$rate]);$id=$q->fetchColumn();
            if($id){$q=$db->prepare('update v_music_on_hold set music_on_hold_path=?,music_on_hold_shuffle=false where music_on_hold_uuid=?');$q->execute([$dir,$id]);}
            else{$q=$db->prepare('insert into v_music_on_hold(music_on_hold_uuid,music_on_hold_name,music_on_hold_path,music_on_hold_rate,music_on_hold_shuffle,music_on_hold_channels,music_on_hold_interval,music_on_hold_timer_name) values(?,?,?,?,false,1,20,?)');$q->execute([uuid(),self::STREAM,$dir,$rate,'soft']);}
        }
        foreach(['README.md','manifest.json'] as $name){copy(PROJECT_ROOT.'/resources/music-on-hold/'.$name,$root.'/'.$name);chmod($root.'/'.$name,0644);}
        // Replace only the stock instance default; preserve explicit operator/custom choices.
        $q=$db->prepare("update v_vars set var_value='local_stream://openweb' where var_name='hold_music' and var_value='local_stream://default'");$q->execute();
        $cache=new cache;$cache->delete('configuration:local_stream.conf');$cache->delete(gethostname().':configuration:local_stream.conf');
    }
}
