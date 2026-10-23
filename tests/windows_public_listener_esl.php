<?php
require dirname(__DIR__).'/packaging/windows/public-listeners-esl.php';
try{$client=new windows_public_listener_esl('127.0.0.1',(int)$argv[1],'fixture-secret');$value=$client->api('sofia status profile internal');if($value!=="fixture bounded result\n")throw new RuntimeException('Unexpected API result.');echo "passed\n";}catch(Throwable){echo "refused\n";exit(1);}
