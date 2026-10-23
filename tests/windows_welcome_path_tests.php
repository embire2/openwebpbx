<?php
/** Actual PHP path predicate, using normalized Windows strings; no DB/runtime. */
if(PHP_SAPI!=='cli')exit(2);
require_once __DIR__.'/windows_welcome_paths.php';
$expected='C:/ProgramData/OpenWebPBX/native-qualification/'.str_repeat('a',24);
$input=$expected.'/input.json';$work=$expected.'/evidence/welcome-'.str_repeat('b',24);$checks=0;
$check=static function(bool $value)use(&$checks):void{if(!$value)throw new RuntimeException('Windows welcome path control failed.');$checks++;};
$old=static fn(string $i,string $w,string $e):bool=>strcasecmp(dirname($i),$e)===0&&basename($i)==='input.json'&&str_starts_with(strtolower($w),strtolower($e.'/welcome-'));
$check(!$old($input,$work,$expected));
$check(windows_welcome_owned_paths($input,$work,$expected));
$check(windows_welcome_owned_paths(strtolower($input),strtolower($work),$expected));
foreach([
 [$expected.'/other.json',$work],[$expected.'/input.json.extra',$work],[$expected.'/other/input.json',$work],
 [$input,$expected.'/welcome-'.str_repeat('b',24)],[$input,$work.'/child'],
 [$input,$expected.'/evidence-extra/welcome-'.str_repeat('b',24)],
 [$input,$expected.'/evidence/welcome-'.str_repeat('b',23)],[$input,$expected.'/evidence/welcome-'.str_repeat('b',25)],
 [$input,$expected.'/evidence/welcome-'.str_repeat('z',24)],[$input,$expected.'/evidence/welcome-'.str_repeat('B',24)],
 [$input,$expected.'extra/evidence/welcome-'.str_repeat('b',24)],
 [$input,str_replace(str_repeat('a',24),str_repeat('c',24),$work)],
]as[$i,$w])$check(!windows_welcome_owned_paths($i,$w,$expected));
echo 'PASS '.$checks." actual PHP welcome-path controls; normalized-path fixture only, native dispatch unqualified\n";
