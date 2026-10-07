<?php
/** Private data paths shared by Windows and Debian installations. */
class pbx_paths {
    public static function host(): string {return (string)config::load()->get('openweb.public_host','call.openweb.co.za');}
    public static function url(): string {return rtrim((string)config::load()->get('openweb.public_url','https://'.self::host()),'/');}
    public static function address(): string {return (string)config::load()->get('openweb.public_ip',self::host());}
    public static function state(): string {
        return PHP_OS_FAMILY==='Windows'?str_replace('\\','/',getenv('ProgramData')?:'C:/ProgramData').'/OpenWebPBX':'/var/lib/openwebpbx';
    }
    public static function key(): string {return str_replace('\\','/',dirname(config::find())).'/openweb-template.key';}
    public static function storage(): string {return rtrim(str_replace('\\','/',(string)config::load()->get('switch.storage.dir','/var/lib/freeswitch/storage')),'/');}
    public static function media(): string {return self::storage().'/openwebpbx';}
    public static function voicemail(): string {return rtrim(str_replace('\\','/',(string)config::load()->get('switch.voicemail.dir',self::storage().'/voicemail')),'/');}
    public static function uploads(): string {return self::state().'/uploads';}
    public static function contains(string $root,string $file): bool {
        $root=realpath($root);$file=realpath($file);if($root===false||$file===false)return false;
        $root=rtrim(str_replace('\\','/',$root),'/').'/';$file=str_replace('\\','/',$file);
        if(PHP_OS_FAMILY==='Windows'){$root=strtolower($root);$file=strtolower($file);}
        return str_starts_with($file,$root);
    }
}
