<?php
/** Actual token compatibility for binary requests, without a database or HTTP body. */
if(PHP_SAPI!=='cli')exit;
require_once dirname(__DIR__).'/resources/classes/token.php';
require_once dirname(__DIR__).'/resources/classes/pbx_protection.php';
$_SESSION=[];$_REQUEST=[];$count=0;
$check=function(bool $ok,string $message)use(&$count){if(!$ok)throw new RuntimeException($message);$count++;};
$path='/app/pbx_protection/index.php';$issued=(new token)->create($path);
$before=$_SESSION;
$check(pbx_protection::uploadToken($issued['name'],$issued['hash']),'ordinary form token accepted in headers');
$check($_SESSION===$before,'gate leaves token session byte structure unchanged');
$check($_REQUEST===[],'no fabricated query or form fields');
$check(!pbx_protection::uploadToken(str_repeat('a',64),$issued['hash']),'wrong header name refused');
$check(!pbx_protection::uploadToken($issued['name'],str_repeat('b',64)),'wrong header hash refused');
$check(!pbx_protection::uploadToken($issued['name'],'!'.$issued['hash']),'noncanonical hash refused');
$other=(new token)->create('/app/pbx_api_keys/index.php');
$check(!pbx_protection::uploadToken($other['name'],$other['hash']),'another page token refused');
$_REQUEST=[$issued['name']=>'malicious-query-value'];
$check(pbx_protection::uploadToken($issued['name'],$issued['hash'],true),'valid header not overridden by query pollution');
$check($_SESSION['tokens'][$path][0]['validated']===true,'completed upload validates ordinary form token');
(new token)->create('/app/pbx_api_keys/index.php');
$check(!pbx_protection::uploadToken($issued['name'],$issued['hash']),'normal subsequent form issuance retires consumed token');
echo 'PASS: '.$count." binary upload CSRF token controls\n";
