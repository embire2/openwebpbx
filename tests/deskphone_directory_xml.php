<?php
require_once __DIR__.'/../app/extensions/resources/classes/extension.php';
$folder=sys_get_temp_dir().'/openweb-directory-'.bin2hex(random_bytes(8));mkdir($folder,0700);
$source=file_get_contents(__DIR__.'/../app/extensions/resources/classes/extension.php');preg_match_all('/\$row\[\x27([^\x27]+)\x27\]/',$source,$columns);$row=array_fill_keys($columns[1],'');
$password=" leading\t& < > \" ' dollar$5 trailing ";$name='A & B <Office> "Reception"';
$row=array_replace($row,['extension_uuid'=>'00000000-0000-4000-8000-000000000011','extension'=>'auth-100','password'=>$password,'enabled'=>'true','user_context'=>'xml.example.test','voicemail_password'=>'0012','voicemail_enabled'=>'true','call_timeout'=>'20','effective_caller_id_name'=>$name,'directory_full_name'=>$name,'dial_string'=>'${sofia_contact(${dialed_user}@${dialed_domain})}']);
$fakeDatabase=new class($row) {public function __construct(private array $row){} public function select($sql,$parameters,$type){return [$this->row];}};
$fakeSettings=new class($folder) {public function __construct(private string $folder){} public function get($category,$key){return $category==='switch'&&$key==='extensions'?$this->folder:null;}};
$domain_uuid='00000000-0000-4000-8000-000000000001';$_SESSION=['domains'=>[$domain_uuid=>['domain_name'=>'xml.example.test']]];
try {
 $writer=new extension(['domain_uuid'=>$domain_uuid,'domain_name'=>'xml.example.test','database'=>$fakeDatabase,'settings'=>$fakeSettings]);$writer->xml();
 $file=$folder.'/xml.example.test/v_auth-100.xml';$document=new DOMDocument();if(!$document->load($file,LIBXML_NONET))throw new RuntimeException('Actual PHP directory writer produced invalid XML.');$xpath=new DOMXPath($document);
 foreach(['password','reverse-auth-pass'] as $field)if($xpath->query('//param[@name="'.$field.'"]')->item(0)?->getAttribute('value')!==$password)throw new RuntimeException('The PHP directory changed credential bytes.');
 if($xpath->query('//variable[@name="effective_caller_id_name"]')->item(0)?->getAttribute('value')!==$name)throw new RuntimeException('The PHP directory renamed the source caller.');
 if($xpath->query('//param[@name="dial-string"]')->item(0)?->getAttribute('value')!==$row['dial_string'])throw new RuntimeException('Reviewed native dial-string expansion changed.');
 if($xpath->query('//param[@name="vm-password" or @name="vm-a1-hash"]')->length!==0)throw new RuntimeException('Directory published a retired voicemail credential.');
 echo "PASS: actual PHP directory XML parses and preserves password/reverse-password/name with no voicemail PIN and native dial-string bytes.\n";
} finally {foreach(glob($folder.'/xml.example.test/*')?:[] as $p)unlink($p);if(is_dir($folder.'/xml.example.test'))rmdir($folder.'/xml.example.test');foreach(glob($folder.'/*')?:[] as $p)unlink($p);rmdir($folder);}
