<?php
/** Current additive reseller/protection/API schemas, unchanged business rules. */
if(PHP_SAPI!=='cli'||PHP_OS_FAMILY!=='Windows')exit(2);
set_exception_handler(static function(Throwable $error):void{fwrite(STDERR,"The reseller and recovery schemas could not be prepared.\n");exit(1);});
$web=$argv[1]??'';if($web!=='C:/OpenWebPBX/web'&&$web!=='C:\\OpenWebPBX\\web')throw new RuntimeException('Use the installed Windows web root.');
require $web.'/resources/require.php';
$db=database::new()->db;$db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);
foreach(['pbx_reseller','pbx_protection'] as $app){
    $path=$web.'/app/'.$app.'/resources/install.sql';$size=is_file($path)?filesize($path):false;
    if($size===false||$size<1||$size>2097152)throw new RuntimeException('The bundled schema is unavailable.');
    $sql=file_get_contents($path);if(!is_string($sql)||strlen($sql)!==$size)throw new RuntimeException('The bundled schema could not be read.');
    $db->exec($sql);
}
echo "Reseller packages, scoped API keys and protected recovery are prepared.\n";
