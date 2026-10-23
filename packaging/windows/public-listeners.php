<?php
// SPDX-License-Identifier: AGPL-3.0-or-later
/** Protected Windows CLI-only read-only PG/ESL listener inventory. */
if(PHP_SAPI!=='cli'||PHP_OS_FAMILY!=='Windows')exit(2);
set_exception_handler(static function(Throwable $error): never {fwrite(STDERR,$error instanceof windows_public_listener_review ? "OpenWebPBXPublicListeners:custom_audio_range\n" : "The configured native listener inventory could not be verified.\n");exit(1);});
require __DIR__.'/public-listeners-policy.php';
require __DIR__.'/public-listeners-esl.php';
$root=$argv[1]??'';$configuration=$argv[2]??'';$coreHash=$argv[3]??'';
require $root.'/resources/classes/config.php';$settings=config::load($configuration);
$host=(string)$settings->get('database.0.host','127.0.0.1');$port=(string)$settings->get('database.0.port','5433');$name=(string)$settings->get('database.0.name');$user=(string)$settings->get('database.0.username');
if($settings->get('database.0.type')!=='pgsql'||!in_array($host,['127.0.0.1','::1'],true)||$port!=='5433'||!preg_match('/^[A-Za-z0-9_-]{1,63}$/D',$name)||!preg_match('/^[A-Za-z0-9_-]{1,63}$/D',$user))throw new RuntimeException('Use the protected local PostgreSQL installation.');
$db=new PDO('pgsql:host='.$host.';port='.$port.';dbname='.$name,$user,(string)$settings->get('database.0.password'),[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
$eventPort=(int)$settings->get('switch.event_socket.port',8021);
$esl=new windows_public_listener_esl((string)$settings->get('switch.event_socket.host','127.0.0.1'),$eventPort,(string)$settings->get('switch.event_socket.password'));
echo json_encode(windows_public_listeners::snapshot($db,$esl->api(...),$coreHash,[5433,$eventPort,8087]),JSON_THROW_ON_ERROR),PHP_EOL;
