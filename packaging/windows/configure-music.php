<?php
/** SPDX-License-Identifier: AGPL-3.0-or-later. Administrator-invoked bundled music setup. */
if(PHP_SAPI!=='cli'||PHP_OS_FAMILY!=='Windows')exit(2);
$bundle=$argv[1]??'';$web=$argv[2]??'';$vars=$argv[3]??'';
if($bundle===''||$web===''||!is_file($web.'/resources/require.php'))throw new RuntimeException('Use the complete Windows release and installed web root.');
require $web.'/resources/require.php';
pbx_music::install(null,$bundle);
$changed=false;
if($vars!=='')$changed=pbx_music::nativeDefault($vars,(string)config::load()->get('switch.conf.dir',''));
echo json_encode(['prepared_music_rates'=>4,'stock_native_default_updated'=>$changed,'explicit_custom_music_preserved'=>true],JSON_THROW_ON_ERROR),PHP_EOL;
