<?php
require_once dirname(__DIR__,2).'/resources/require.php';
require_once PROJECT_ROOT.'/resources/check_auth.php';
$setup=new pbx_setup;
if(!$setup->canManage()){http_response_code(403);exit('Access denied.');}
header('Cache-Control: no-store');header('Referrer-Policy: no-referrer');
pbx_admin::openPreferred();$admin=new pbx_admin;
$view=is_string($_GET['view']??null)?$_GET['view']:'overview';
if(isset($_GET['audio'])){
    try{$file=$admin->mediaFile((string)$_GET['audio']);$size=filesize($file['file_path']);$start=0;$end=$size-1;
        if(isset($_SERVER['HTTP_RANGE'])&&preg_match('/^bytes=(\d+)-(\d*)$/D',$_SERVER['HTTP_RANGE'],$m)){$start=(int)$m[1];$end=$m[2]!==''?min((int)$m[2],$end):$end;if($start>$end||$start>=$size){http_response_code(416);exit;}http_response_code(206);header('Content-Range: bytes '.$start.'-'.$end.'/'.$size);}
        header('Content-Type: audio/wav');header('X-Content-Type-Options: nosniff');header('Accept-Ranges: bytes');header('Content-Length: '.($end-$start+1));session_write_close();$f=fopen($file['file_path'],'rb');fseek($f,$start);$left=$end-$start+1;while($left>0&&!feof($f)){$buf=fread($f,min(1048576,$left));echo $buf;$left-=strlen($buf);}fclose($f);exit;
    }catch(Throwable){http_response_code(404);exit('Audio unavailable.');}
}
if(in_array($view,['wizard','review','import','import_preview'],true)||!$admin->restored()){$openweb_guided=true;require __DIR__.'/guided.php';exit;}
$operations=new pbx_operations;
$key=is_string($_GET['edit']??null)?$_GET['edit']:'';$error='';$credentials=null;
$types=['users'=>'user','voice'=>'trunk','departments'=>'department','hours'=>'hours','queues'=>'queue','ring_groups'=>'ring_group','receptionists'=>'receptionist','outbound'=>'outbound','incoming'=>'incoming','scripts'=>'script'];
if($_SERVER['REQUEST_METHOD']==='POST'){
    try{
        if(!(new token)->validate('/app/pbx_setup/index.php')){http_response_code(403);throw new RuntimeException('Your form expired. Refresh the page.');}
        if(($_POST['action']??'')==='switch'){$setup->switchDomain((string)($_POST['domain']??''));header('Location: /app/pbx_setup/');exit;}
        if(($_POST['action']??'')==='job_action'){$operations->jobAction((string)($_POST['job']??''),(string)($_POST['job_action']??''));$_SESSION['pbx_setup_notice']='Call request updated.';header('Location: /app/pbx_setup/?view='.($view==='wakeups'?'wakeups':'callbacks'));exit;}
        elseif(($_POST['action']??'')==='hotel_action'){$hotel=$_POST;$hotel['action']=$_POST['hotel_action']??'';$operations->hotelAction($hotel);$_SESSION['pbx_setup_notice']='Hotel settings updated.';header('Location: /app/pbx_setup/?view=hotel');exit;}
        elseif(($_POST['action']??'')==='credentials')$credentials=$admin->credentials($key);
        elseif(($_POST['action']??'')==='upload_audio'){$admin->uploadAudio($_FILES['prompt']??[]);$_SESSION['pbx_setup_notice']='Audio uploaded. Choose it as the prompt in a queue or digital receptionist.';header('Location: /app/pbx_setup/?view=handling');exit;}
        elseif(($_POST['action']??'')==='delete'&&isset($types[$view])){if(empty($_POST['confirm_delete']))throw new InvalidArgumentException('Confirm deletion.');$admin->delete($types[$view],$key);$_SESSION['pbx_setup_notice']='Deleted.';header('Location: /app/pbx_setup/?view='.rawurlencode($view));exit;}
        elseif(($_POST['action']??'')==='save'&&isset($types[$view])){$admin->save($types[$view],$key,$_POST);$_SESSION['pbx_setup_notice']='Saved.';header('Location: /app/pbx_setup/?view='.rawurlencode($view));exit;}
        else throw new InvalidArgumentException('Choose an action.');
    }catch(PDOException){$error='The change could not be saved. Check the details and try again.';}catch(Throwable $ex){$error=$ex->getMessage();}
}
$c=$admin->config();$report=$admin->report();$services=$admin->services();$notice=$_SESSION['pbx_setup_notice']??'';unset($_SESSION['pbx_setup_notice']);
$labels=['overview'=>'Dashboard','users'=>'Users','phones'=>'Phones','voice'=>'Voice & Chat','outbound'=>'Outbound Rules','departments'=>'Departments','hours'=>'Office Hours','handling'=>'Call Handling','queues'=>'Call Queues','ring_groups'=>'Ring Groups','receptionists'=>'Digital Receptionists','incoming'=>'DID Numbers','scripts'=>'Call Scripts','contacts'=>'Contacts','reports'=>'Reports','recordings'=>'Recordings','voicemails'=>'Voicemail','settings'=>'System','callbacks'=>'Queue Callbacks','hotel'=>'Hotel Services','wakeups'=>'Wake-up Calls'];
if(!isset($labels[$view]))$view='overview';
$e=static fn($s)=>htmlspecialchars(is_scalar($s)?(string)$s:'',ENT_QUOTES,'UTF-8');
$departmentName=static fn($name)=>in_array($name,['__DEFAULT','__DEFAULT__'],true)?'Default':($name==='__OW_CLIENTS'?'OpenWeb Clients':$name);
$token=(new token)->create('/app/pbx_setup/index.php');$csrf=static function()use($e,$token){echo '<input type="hidden" name="'.$e($token['name']).'" value="'.$e($token['hash']).'">';};
$input=static function(string $name,string $label,mixed $value='',string $type='text',string $extra='')use($e){echo '<label>'.$e($label).'<input type="'.$e($type).'" name="'.$e($name).'" value="'.$e($value).'" '.$extra.'></label>';};
$check=static function(string $name,string $label,bool $value=false)use($e){echo '<label class="setup-check-label"><input type="checkbox" name="'.$e($name).'" value="1" '.($value?'checked':'').'><span>'.$e($label).'</span></label>';};
$select=static function(string $name,string $label,array $choices,mixed $value='',string $extra='')use($e){echo '<label>'.$e($label).'<select name="'.$e($name).'" '.$extra.'>';foreach($choices as $id=>$title)echo '<option value="'.$e($id).'" '.((string)$id===(string)$value?'selected':'').'>'.$e($title).'</option>';echo '</select></label>';};
$dest=static function(string $name,string $label,array $d=[])use($admin,$c,$select,$input){$select($name,$label,$admin->destinations($c),($d['type']??'None').':'.($d['number']??''),'data-destination');echo '<div data-external>';$input($name.'_external','External Number',$d['external']??'','tel');echo '</div>';};
$members=static function(array $selected)use($c,$check){$numbers=array_map('strval',array_column($selected,'number'));echo '<div class="admin-members">';foreach($c['users'] as $n=>$u)$check('members[]',$n.' · '.$u['name'],in_array((string)$n,$numbers,true));echo '</div>';};
$audioChoices=[''=>'None'];$audioIds=[];foreach($admin->media('prompts') as $audio){$audioChoices[$audio['media_uuid']]=$audio['title'];$audioIds[$audio['file_path']]=$audio['media_uuid'];}
$find=static function(array $rows,string $id,string $field='number'): ?array{foreach($rows as $r)if((string)($r[$field]??'')===$id)return $r;return null;};
$table=static function(array $headers,array $rows)use($e){echo '<div class="setup-table-wrap"><table class="setup-table"><thead><tr>';foreach($headers as $h)echo '<th>'.$e($h).'</th>';echo '</tr></thead><tbody>';foreach($rows as $row){echo '<tr data-search-row>';foreach($row as $cell)echo '<td>'.$cell.'</td>';echo '</tr>';}if(!$rows)echo '<tr><td colspan="'.count($headers).'">No items.</td></tr>';echo '</tbody></table></div>';};
$editLink=static fn($v,$id,$title)=>'<a href="?view='.$e($v).'&amp;edit='.$e($id).'">'.$e($title).'</a>';
$newLink=static fn($v,$title)=>'<a class="setup-button primary" href="?view='.$e($v).'&amp;edit=new">'.$e($title).'</a>';
$toolbar=static function(string $new=''){echo '<div class="admin-toolbar setup-form"><input type="search" data-search placeholder="Search" aria-label="Search this page">'.$new.'</div>';};
$department=static function(string $number)use($c): array{foreach($c['departments'] as $d)foreach($d['members'] as $m)if((string)$m['number']===$number&&$m['primary'])return $d;return ['number'=>'','name'=>''];};
$document['title']=$labels[$view].' · Admin';require_once PROJECT_ROOT.'/resources/header.php';
?>
<link rel="stylesheet" href="/app/pbx_setup/setup.css?v=3"><script src="/app/pbx_setup/admin.js?v=1" defer></script>
<main class="pbx-setup"><header class="setup-heading"><div><span class="setup-eyebrow">OPENWEB PBX · 1.0.2</span><h1>Admin</h1></div><form method="post" class="setup-form admin-switch"><?php $csrf(); ?><input type="hidden" name="action" value="switch"><select name="domain" aria-label="PBX"><?php foreach($services as $s): ?><option value="<?= $e($s['domain_uuid']) ?>" <?= $s['domain_uuid']===$_SESSION['domain_uuid']?'selected':'' ?>><?= $e($s['tenant_name'].' · '.$s['service_name']) ?></option><?php endforeach; ?></select><button class="setup-button" type="submit">Open</button></form></header>
<div class="setup-shell"><nav class="setup-nav" aria-label="Admin pages">
<?php foreach(['overview'=>'fa-chart-simple','users'=>'fa-users','phones'=>'fa-phone','voice'=>'fa-phone-volume','outbound'=>'fa-arrow-up-right-from-square','departments'=>'fa-building','hours'=>'fa-business-time','handling'=>'fa-diagram-project','contacts'=>'fa-address-book','reports'=>'fa-chart-column','recordings'=>'fa-microphone','voicemails'=>'fa-voicemail','import'=>'fa-hard-drive','hotel'=>'fa-hotel','settings'=>'fa-gear'] as $v=>$icon):$active=$view===$v||($v==='handling'&&in_array($view,['queues','ring_groups','receptionists','scripts','callbacks'],true))||($v==='voice'&&$view==='incoming'); ?><a class="<?= $active?'selected':'' ?>" href="?view=<?= $v ?>"><i class="fa-solid <?= $icon ?>" aria-hidden="true"></i><?= $e($labels[$v]??'Backup & Restore') ?></a><?php endforeach; ?></nav><div class="setup-content">
<?php if($error): ?><div class="setup-message error" role="alert"><?= $e($error) ?></div><?php endif; ?><?php if($notice): ?><div class="setup-message" role="status"><?= $e($notice) ?></div><?php endif; ?>
<section class="setup-card"><div class="admin-card-title"><h2><?= $e($labels[$view]) ?></h2><?php if($key): ?><a class="setup-button" href="?view=<?= $e($view) ?>">Back</a><?php endif; ?></div>
<?php if($key&&isset($types[$view])):
    $row=$key==='new'?[]:match($view){'users'=>$c['users'][$key]??null,'voice'=>$c['trunks'][$key]??null,'departments','hours'=>$find($c['departments'],$key),'queues'=>$find($c['queues'],$key),'ring_groups'=>$find($c['ring_groups'],$key),'receptionists'=>$find($c['receptionists'],$key),'scripts'=>$find($c['scripts'],$key),'outbound'=>$find($c['outbound_rules'],$key,'rule_id'),'incoming'=>$find($c['inbound_rules'],$key,'rule_id'),default=>null};
    if($row===null): ?><p>This item is not in your PBX.</p><?php else: ?>
    <form method="post" class="setup-form admin-form-tabs"><?php $csrf(); ?><input type="hidden" name="action" value="save">
    <?php require __DIR__.'/edit.php'; ?>
    <div class="setup-actions"><button class="setup-button primary" type="submit">Save</button><a class="setup-button" href="?view=<?= $e($view) ?>">Cancel</a></div></form>
    <?php if($credentials): ?><div class="setup-message admin-credentials"><strong>Phone Provisioning</strong><dl class="setup-review"><?php foreach(['server'=>'Server','extension'=>'Extension','account'=>'Authentication ID','password'=>'Authentication Password','domain'=>'Domain'] as $f=>$label): ?><div><dt><?= $label ?></dt><dd><?= $e($credentials[$f]) ?></dd></div><?php endforeach; ?></dl></div><?php endif; ?>
    <?php endif; ?>
    <?php if($row!==null&&$key!=='new'&&in_array($view,['users','queues','ring_groups','receptionists','outbound'],true)): ?><details><summary>Delete</summary><form method="post" class="setup-form"><?php $csrf(); ?><input type="hidden" name="action" value="delete"><?php $check('confirm_delete','Delete this item permanently'); ?><button type="submit" class="setup-button danger">Delete</button></form></details><?php endif; ?>
<?php elseif(in_array($view,['callbacks','hotel','wakeups'],true)): require __DIR__.'/operations.php';
elseif($view==='users'):
    $toolbar($newLink('users','Add User'));$rows=[];foreach($c['users'] as $n=>$u)$rows[]=[$editLink('users',$n,$u['name']),$e($n),$e($u['email']),$e($departmentName($department((string)$n)['name'])),$e($u['profile']),$u['enabled']?'Enabled':'Disabled'];$table(['Name','Extension','Email','Department','Status','Enabled'],$rows);
elseif($view==='voice'):
    $toolbar($newLink('voice','Add SIP Trunk'));$rows=[];foreach($c['trunks'] as $n=>$t)$rows[]=[$editLink('voice',$n,$t['name']),$e($t['main_number']),$e($t['host']),$t['enabled']?'Enabled':'Off'];$table(['SIP Trunk','Main Trunk Number','Server','Status'],$rows);
?> <a class="setup-button" href="?view=incoming">DID Numbers</a>
<?php elseif($view==='phones'):
    $toolbar();$rows=[];foreach($c['phones'] as $r)$rows[]=[$e($r['number']),$e($c['users'][$r['number']]['name']),$e(str_contains($r['template'],'fanvil')?'Fanvil':'Generic IP Phone'),$e($r['mac']),$editLink('users',$r['number'],'Phone Provisioning')];$table(['Extension','User','Phone','MAC Address','Configure'],$rows);
elseif(in_array($view,['departments','hours'],true)):
    $toolbar($view==='departments'?$newLink('departments','Add Department'):'');$rows=[];foreach($c['departments'] as $r)$rows[]=[$editLink($view,$r['number'],$departmentName($r['name'])),$e(count($r['members'])),$e(str_replace('_',' ',$r['timezone'])),($r['hours']['type']??'')==='AllHours'?'Always Open':'Office Hours'];$table(['Department','Members','Timezone','Hours'],$rows);
elseif(in_array($view,['handling','queues','ring_groups','receptionists','scripts'],true)):
    if($view==='handling'): ?><div class="setup-actions"><a class="setup-button primary" href="?view=queues&amp;edit=new">Add Call Queue</a><a class="setup-button" href="?view=ring_groups&amp;edit=new">Add Ring Group</a><a class="setup-button" href="?view=receptionists&amp;edit=new">Add Digital Receptionist</a><a class="setup-button" href="?view=callbacks">Queue Callbacks</a></div><?php endif;
    $toolbar($view==='queues'?$newLink('queues','Add Call Queue'):($view==='ring_groups'?$newLink('ring_groups','Add Ring Group'):($view==='receptionists'?$newLink('receptionists','Add Digital Receptionist'):'')));$rows=[];foreach(['queues'=>'Call Queue','ring_groups'=>'Ring Group','receptionists'=>'Digital Receptionist','scripts'=>'Call Script'] as $kind=>$title){if($view!=='handling'&&$view!==$kind)continue;foreach($c[$kind] as $r)$rows[]=[$editLink($kind,$r['number'],$r['name']),$e($r['number']),$title,$e($department($r['number'])['name'])];}$table(['Name','Extension','Type','Department'],$rows);
elseif($view==='outbound'):
    $toolbar($newLink('outbound','Add Outbound Rule'));$rows=[];foreach($c['outbound_rules'] as $i=>$r)$rows[]=[$e($i+1),$editLink('outbound',$r['rule_id'],$r['name']),$e($r['prefix']?:'Any'),$e($r['lengths']?:'Any'),$e(implode(', ',array_map(fn($route)=>$c['trunks'][$route['trunk_id']]['name'],$r['routes'])))];$table(['Order','Name','Prefix','Length','Routes'],$rows);
elseif($view==='incoming'):
    $toolbar($newLink('incoming','Add DID Number'));$choices=$admin->destinations($c);$rows=[];foreach($c['inbound_rules'] as $r){$d=$r['office'];$rows[]=[$editLink('incoming',$r['rule_id'],$r['number']?:'All Calls'),$e($c['trunks'][$r['trunk_id']]['name']),$e($choices[$d['type'].':'.$d['number']]??$d['external']),$r['enabled']?'Enabled':'Off'];}$table(['DID Number','SIP Trunk','Destination','Status'],$rows);
elseif($view==='contacts'):
    $toolbar();$rows=[];foreach($c['contacts'] as $r)$rows[]=[$e(trim($r['first_name'].' '.$r['last_name'])),$e($r['company']),$e($r['phone']),$e($r['owner'])];$table(['Name','Company','Phone','User'],$rows);
elseif($view==='reports'):
    $page=max(0,(int)($_GET['page']??0));$rows=[];foreach($admin->history($page) as $r)$rows[]=[$e($r['start_time']),$e($r['owner_number']),$e($r['party_number']),$e($r['party_name']),$e($r['call_type']),$e($r['end_status'])];$table(['Time','User','Number','Name','Type','Result'],$rows);
?> <div class="setup-actions"><?php if($page>0): ?><a class="setup-button" href="?view=reports&amp;page=<?= $page-1 ?>">Previous</a><?php endif; ?><a class="setup-button" href="?view=reports&amp;page=<?= $page+1 ?>">Next</a><a class="setup-button" href="/app/xml_cdr/xml_cdr.php">Live Call Reports</a></div>
<?php elseif(in_array($view,['recordings','voicemails'],true)):
    $page=max(0,(int)($_GET['page']??0));$rows=[];foreach($admin->media($view,$page) as $r)$rows[]=[$e($r['created_at']??''),$e($r['owner_number']??''),$e($r['title']),'<audio class="admin-audio" controls preload="none" src="?audio='.$e($r['media_uuid']).'">Audio</audio>'];$table(['Time','User','File','Play'],$rows);
?> <div class="setup-actions"><?php if($page>0): ?><a class="setup-button" href="?view=<?= $view ?>&amp;page=<?= $page-1 ?>">Previous</a><?php endif; ?><a class="setup-button" href="?view=<?= $view ?>&amp;page=<?= $page+1 ?>">Next</a></div>
<?php elseif($view==='settings'): ?><div class="setup-link-list"><?php if(permission_exists('smtp_settings_manage')): ?><a class="setup-link" href="/app/smtp_settings/"><i class="fa-solid fa-envelope"></i><div><strong>Email</strong><span>Outgoing mail server and IP Authentication.</span></div></a><?php endif; ?><a class="setup-link" href="?view=import"><i class="fa-solid fa-hard-drive"></i><div><strong>Backup & Restore</strong></div></a><a class="setup-link" href="/app/tenant_services/"><i class="fa-solid fa-building"></i><div><strong>Tenants & Templates</strong></div></a><a class="setup-link" href="?view=wizard"><i class="fa-solid fa-plus"></i><div><strong>Add PBX</strong></div></a><a class="setup-link" href="/core/users/users.php"><i class="fa-solid fa-user-shield"></i><div><strong>Administrators</strong></div></a></div>
<?php else: ?>
<p><?= ($c['origin']??'')==='OpenWeb PBX'?'Your OpenWeb PBX is ready to configure.':'Restored from your 3CX V20 backup.' ?></p><div class="setup-counts"><?php foreach(['Users'=>count($c['users']),'SIP Trunks'=>count($c['trunks']),'Call Queues'=>count($c['queues']),'Digital Receptionists'=>count($c['receptionists'])] as $label=>$count): ?><div><strong><?= $count ?></strong><span><?= $label ?></span></div><?php endforeach; ?></div>
<div class="setup-message warning"><strong>Connect Your Phones and Trunks</strong><p>Use Phone Provisioning under Users to connect phones. Check your provider details under Voice &amp; Chat, then enable incoming numbers under DID Numbers.</p></div><h3><?= ($c['origin']??'')==='OpenWeb PBX'?'PBX Overview':'Restore Report' ?></h3>
<?php $rows=[];foreach(['users'=>'Users','trunks'=>'SIP Trunks','departments'=>'Departments','queues'=>'Call Queues','receptionists'=>'Digital Receptionists','ring_groups'=>'Ring Groups','phones'=>'Phones','inbound_rules'=>'DID Numbers','outbound_rules'=>'Outbound Rules','recordings'=>'Recordings','voicemail_messages'=>'Voicemail Messages','voicemail_greetings'=>'Voicemail Greetings','prompts'=>'Audio Files','call_history'=>'Call History','contacts'=>'Contacts'] as $k=>$label)$rows[]=[$label,$e($report[$k]??0)];$table(['Restored','Items'],$rows);if(!empty($report['notes'])): ?><h3>Needs Attention</h3><?php $rows=[];foreach($report['notes'] as $n)$rows[]=[$e($n['category']),$e($n['count']),$e($n['reason'])];$table(['Item','Count','Details'],$rows);endif; ?>
<?php endif; ?>
<?php if($view==='handling'&&$key===''): ?><details><summary>Upload Audio</summary><form method="post" enctype="multipart/form-data" class="setup-form"><?php $csrf(); ?><input type="hidden" name="action" value="upload_audio"><div class="setup-fields"><label>Prompt<input type="file" name="prompt" accept=".wav" required><small>WAV audio, up to 25 MB.</small></label></div><button class="setup-button" type="submit">Upload</button></form></details><?php endif; ?>
</section></div></div></main>
<?php require_once PROJECT_ROOT.'/resources/footer.php'; ?>
