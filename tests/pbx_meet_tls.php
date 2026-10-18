<?php
/** Actual OpenSSL/filesystem checks; no application database/configuration is loaded. */
if(PHP_SAPI!=='cli')exit;
require dirname(__DIR__).'/resources/classes/pbx_meet_install.php';
$n=0;$check=static function($v,$why)use(&$n){if(!$v)throw new RuntimeException($why);$n++;};
$refuse=static function($f)use($check){$failed=false;try{$f();}catch(RuntimeException){$failed=true;}$check($failed,'Unsafe TLS state refused');};
$root=sys_get_temp_dir().'/openweb-meet-tls-'.bin2hex(random_bytes(6));mkdir($root,0700);$mask=umask(0077);
$remove=static function($path)use(&$remove){if(is_dir($path)&&!is_link($path)){foreach(scandir($path)as$f)if($f!=='.'&&$f!=='..')$remove($path.'/'.$f);rmdir($path);}else unlink($path);};
try{
 $result=pbx_meet_install::tls($root.'/engine',$root.'/state');$pem=$result['certificate'];$ca=$result['trust'];
 $bytes=file_get_contents($pem);$trust=file_get_contents($ca);$key=openssl_pkey_get_private($bytes);$cert=openssl_x509_read($bytes);
 $check($key&&$cert&&openssl_x509_check_private_key($cert,$key),'Actual private key matches generated certificate');
 openssl_x509_export($cert,$public);$check($public===$trust,'Trust pin is exactly the public certificate');
 $check((fileperms($pem)&0777)===0640&&(fileperms($ca)&0777)===0644,'Private/public file permissions are explicit under restrictive umask');
 $check((fileperms(dirname($pem))&0777)===0750,'New private directory is service-traversable under restrictive umask');
 $before=[hash_file('sha256',$pem),hash_file('sha256',$ca),filemtime($pem),filemtime($ca),fileowner($pem),filegroup($pem)];
 pbx_meet_install::tls($root.'/engine',$root.'/state');
 $check($before===[hash_file('sha256',$pem),hash_file('sha256',$ca),filemtime($pem),filemtime($ca),fileowner($pem),filegroup($pem)],'Repeat TLS install preserves key bytes, timestamps and owners');
 file_put_contents($root.'/custom.wav','customer-owned');
 file_put_contents($ca,'mismatching trust');$refuse(fn()=>pbx_meet_install::tls($root.'/engine',$root.'/state'));
 $check(file_get_contents($pem)===$bytes&&file_get_contents($ca)==='mismatching trust','Mismatching pin refuses without rotating/replacing either file');
 file_put_contents($ca,$trust);
 mkdir($root.'/linked');symlink($root.'/engine',$root.'/linked/engine');$refuse(fn()=>pbx_meet_install::tls($root.'/linked/engine',$root.'/state'));
 mkdir($root.'/orphan');file_put_contents($root.'/orphan/meet-ca.pem',$trust);$refuse(fn()=>pbx_meet_install::tls($root.'/absent-engine',$root.'/orphan'));
 $check(!file_exists($root.'/absent-engine'),'Orphaned trust refuses before creating private directories/files');
 file_put_contents($root.'/not-directory','preserve');$refuse(fn()=>pbx_meet_install::tls($root.'/not-directory/engine',$root.'/other-state'));
 mkdir($root.'/ca-directory');mkdir($root.'/ca-directory/meet-ca.pem');$refuse(fn()=>pbx_meet_install::tls($root.'/new-engine',$root.'/ca-directory'));
 $check(!file_exists($root.'/new-engine'),'Nonordinary CA target refuses before creating a private key');
 $check(file_get_contents($root.'/custom.wav')==='customer-owned','Unrelated custom audio remains exact');
 echo 'PASS '.$n." actual OpenSSL/filesystem TLS identity and refusal controls\n";
}finally{umask($mask);$remove($root);}
