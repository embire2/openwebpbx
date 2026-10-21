<?php
// Read-only native module/codec checks on the disposable Windows runner.
if(PHP_SAPI!=='cli'||PHP_OS_FAMILY!=='Windows'||getenv('GITHUB_ACTIONS')!=='true'||getenv('RUNNER_ENVIRONMENT')!=='github-hosted'||getenv('GITHUB_REPOSITORY')!=='embire2/openwebpbx')exit(2);
require 'C:/OpenWebPBX/web/resources/require.php';
$conference=trim((string)event_socket::api('module_exists mod_conference'))==='true';
$hash=trim((string)event_socket::api('module_exists mod_hash'))==='true';
$codecs=json_decode((string)event_socket::api('show codecs as json'),true,32,JSON_THROW_ON_ERROR);
$vp8=count(array_filter($codecs['rows']??[],static fn($row)=>($row['type']??'')==='codec'&&($row['name']??'')==='VP8 Video'))>0;
if(!$conference||!$vp8){fwrite(STDERR,"The installed meeting mixer or VP8 video codec is unavailable.\n");exit(1);}
if(!$hash){fwrite(STDERR,"The installed native shared call limiter is unavailable.\n");exit(1);}
echo json_encode(['conference_module'=>true,'vp8_video_codec'=>true,'hash_module'=>true],JSON_THROW_ON_ERROR),PHP_EOL;
