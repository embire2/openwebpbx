<?php
/** Keep an already-installed G.729 transcoder ahead of the passthrough module. */
function openweb_normalize_codec_modules(
    string $path='/etc/freeswitch/autoload_configs/modules.conf.xml',
    string $transcoder='/usr/lib/freeswitch/mod/mod_bcg729.so'
): bool {
    if(!file_exists($path))return false;
    if(is_link($path)||!is_file($path))throw new RuntimeException('The native module configuration needs manual review.');
    $before=stat($path);$xml=file_get_contents($path);
    if($xml===false||strlen($xml)>1048576||preg_match('/<!\s*(?:DOCTYPE|ENTITY)/i',$xml))throw new RuntimeException('The native module configuration is invalid.');
    $old=libxml_use_internal_errors(true);
    try{$doc=new DOMDocument();$doc->preserveWhiteSpace=true;$valid=$doc->loadXML($xml,LIBXML_NONET);}
    finally{libxml_clear_errors();libxml_use_internal_errors($old);}
    if(!$valid)throw new RuntimeException('The native module configuration is malformed.');
    $xpath=new DOMXPath($doc);
    $active=$xpath->query('/configuration/modules/load[@module="mod_bcg729"]');
    $passthrough=$xpath->query('/configuration/modules/load[@module="mod_g729"]');
    if(!$active->length||!$passthrough->length||!is_file($transcoder)||is_link($transcoder))return false;
    foreach(iterator_to_array($passthrough) as $node)$node->parentNode->replaceChild(
        $doc->createComment(' OpenWeb PBX: mod_g729 passthrough disabled; the installed mod_bcg729 provides G.729 audio. '),$node);
    $updated=$doc->saveXML();if($updated===false)throw new RuntimeException('The native module configuration could not be updated.');
    $temporary=tempnam(dirname($path),'.openweb-codec-');
    if($temporary===false)throw new RuntimeException('The native module configuration could not be staged.');
    $stream=null;
    try{
        $stream=fopen($temporary,'wb');
        if(!$stream||fwrite($stream,$updated)!==strlen($updated)||!fflush($stream)||!fsync($stream))throw new RuntimeException('The native module configuration could not be written.');
        fclose($stream);$stream=null;
        if(!chown($temporary,$before['uid'])||!chgrp($temporary,$before['gid'])||!chmod($temporary,$before['mode']&07777))throw new RuntimeException('The native module permissions could not be preserved.');
        clearstatcache(true,$path);$current=stat($path);
        if(is_link($path)||$current['dev']!==$before['dev']||$current['ino']!==$before['ino']||file_get_contents($path)!==$xml)throw new RuntimeException('The native module configuration changed during the update.');
        if(!rename($temporary,$path))throw new RuntimeException('The native module configuration could not be replaced.');
        $directory=fopen(dirname($path),'r');
        if(!$directory)throw new RuntimeException('The native module configuration directory is unavailable.');
        try{if(!fsync($directory))throw new RuntimeException('The native module configuration directory could not be synced.');}finally{fclose($directory);}
    }finally{if(is_resource($stream))fclose($stream);if(is_file($temporary))unlink($temporary);}
    return true;
}
