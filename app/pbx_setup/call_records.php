<?php
if(PHP_SAPI!=='cli'){http_response_code(404);exit;}$no_session=true;
require dirname(__DIR__,2).'/resources/require.php';
try{$counts=(new pbx_call_records)->tick();echo json_encode($counts,JSON_THROW_ON_ERROR)."\n";if($counts['retained'])exit(1);}catch(Throwable){fwrite(STDERR,"Call records will retry.\n");exit(1);}
