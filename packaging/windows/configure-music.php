<?php
/** SPDX-License-Identifier: AGPL-3.0-or-later. Administrator-invoked bundled music setup. */
if(PHP_SAPI!=='cli'||PHP_OS_FAMILY!=='Windows')exit(2);
function openweb_music_failure(Throwable $error,string $stage): array {
    $stages=['initialization','bootstrap','music_install','native_default','completion'];
    $types=['RuntimeException','PDOException','Error','TypeError','ValueError','JsonException','ErrorException','Exception'];
    $sources=['configure-music.php','pbx_music.php','pbx_paths.php','database.php','config.php','cache.php','require.php'];
    $source=basename(str_replace('\\','/',$error->getFile()));$type=get_class($error);
    return ['schema'=>1,'stage'=>in_array($stage,$stages,true)?$stage:'initialization',
        'error_type'=>in_array($type,$types,true)?$type:'external_error',
        'source_basename'=>in_array($source,$sources,true)?$source:'external_component',
        'source_line'=>max(1,min(99999,$error->getLine()))];
}
$stage='initialization';
set_exception_handler(static function(Throwable $error)use(&$stage): void {
    fwrite(STDERR,'OPENWEB_MUSIC_FAILURE '.json_encode(openweb_music_failure($error,$stage),JSON_THROW_ON_ERROR).PHP_EOL);
    throw $error;
});
$bundle=$argv[1]??'';$web=$argv[2]??'';$vars=$argv[3]??'';
if($bundle===''||$web===''||!is_file($web.'/resources/require.php'))throw new RuntimeException('Use the complete Windows release and installed web root.');
$stage='bootstrap';
require $web.'/resources/require.php';
$stage='music_install';
pbx_music::install(null,$bundle);
$changed=false;
$stage='native_default';
if($vars!=='')$changed=pbx_music::nativeDefault($vars,(string)config::load()->get('switch.conf.dir',''));
$stage='completion';
echo json_encode(['prepared_music_rates'=>4,'stock_native_default_updated'=>$changed,'explicit_custom_music_preserved'=>true],JSON_THROW_ON_ERROR),PHP_EOL;
