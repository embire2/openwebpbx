<?php
/** Bundled public-domain music, installed locally and served by the native stream. */
class pbx_music {
    public const STREAM='openweb';
    public static function file(): string {return pbx_paths::storage().'/openweb-music/16000/lofi-beat-loop-schmoop.wav';}
    public static function install(?PDO $db=null): void {
        if(PHP_SAPI!=='cli')throw new RuntimeException('Instance installation is required.');
        $db??=database::new()->db;$source=PROJECT_ROOT.'/resources/music-on-hold/lofi-beat-loop-schmoop.wav';
        $manifest=json_decode(file_get_contents(PROJECT_ROOT.'/resources/music-on-hold/manifest.json'),true,32,JSON_THROW_ON_ERROR);
        if(!hash_equals($manifest['files']['lofi-beat-loop-schmoop.wav']['sha256']??'',hash_file('sha256',$source)))throw new RuntimeException('Bundled music failed verification.');
        $root=pbx_paths::storage().'/openweb-music';
        foreach([8000,16000,32000,48000] as $rate){
            $dir=$root.'/'.$rate;if(!is_dir($dir)&&!mkdir($dir,0755,true))throw new RuntimeException('Hold music directory is unavailable.');
            $file=$dir.'/lofi-beat-loop-schmoop.wav';$temporary=$dir.'/track-'.bin2hex(random_bytes(8)).'.wav';
            if($rate===16000){if(!copy($source,$temporary))throw new RuntimeException('Hold music could not be installed.');}
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
