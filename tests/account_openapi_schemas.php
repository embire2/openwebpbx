<?php
/** Adds the implemented personal/department operations to the deterministic v2 export. */
$add('/capabilities','GET','any','Inspect current key boundary and available API families');
foreach(pbx_account_api::ROUTES as $path=>[$verb,$scope,$summary]){
    $params=str_contains($path,'{id}')?[$id]:[];
    if($verb==='GET'&&in_array($path,['/me/calls','/staff/history','/staff/media'],true))$params[]=['name'=>'page','in'=>'query','schema'=>['type'=>'integer','minimum'=>0,'maximum'=>10000]];
    if($path==='/staff/media')$params[]=['name'=>'category','in'=>'query','schema'=>['enum'=>['recordings','voicemails','prompts']]];
    if($path==='/staff/queue-report')$params[]=['name'=>'days','in'=>'query','schema'=>['type'=>'integer','minimum'=>1,'maximum'=>90,'default'=>7]];
    $add($path,$verb,$scope,$summary,$params);
    $paths[$path][strtolower($verb)]['tags']=[str_starts_with($path,'/me')?'End users':'Department staff'];
    $paths[$path][strtolower($verb)]['description'].=' Identity is derived from the key owner’s current staff binding. Caller-supplied user/domain/extension UUIDs cannot change identity. Department authority is checked again by the same business rules as My PBX.';
    if(str_ends_with($path,'/audio'))$paths[$path]['get']['responses']['200']['content']=['audio/wav'=>['schema'=>['type'=>'string','format'=>'binary']],'audio/mpeg'=>['schema'=>['type'=>'string','format'=>'binary']]];
}
foreach(['users','queues','ring-groups','receptionists','trunks','office-hours'] as $resource){
    $base='/staff/'.$resource;
    foreach([[$base,'GET'],[$base.'/{id}','GET'],[$base,'POST'],[$base.'/{id}','POST'],[$base.'/{id}','DELETE']] as [$path,$verb]){
        if($resource==='office-hours'&&($path===$base&&$verb==='POST'||$verb==='DELETE'))continue;
        if($resource==='trunks'&&$verb==='DELETE')continue;
        $add($path,$verb,$verb==='GET'?'staff:read':'staff:write','Department-scoped '.$verb.' '.$resource,str_contains($path,'{id}')?[$id]:[]);
        $paths[$path][strtolower($verb)]['tags']=['Department staff'];
    }
}
foreach([['/pbx/{domain_uuid}/contacts','GET'],['/pbx/{domain_uuid}/contacts','POST'],['/pbx/{domain_uuid}/contacts/{id}','POST'],['/pbx/{domain_uuid}/contacts/{id}','DELETE']] as [$path,$verb])$add($path,$verb,$verb==='GET'?'pbx:read':'pbx:write','Manage company or personal PBX contacts',str_contains($path,'{id}')?[$domain,$id]:[$domain]);
$str=static fn($max=200)=>['type'=>'string','maxLength'=>$max];
$obj=static fn($props,$required=[])=>['type'=>'object','properties'=>$props,'required'=>$required,'additionalProperties'=>false];
$spec['components']['schemas']['ContactSave']=$obj(['first_name'=>$str(100),'last_name'=>$str(100),'company'=>$str(200),'phone'=>['type'=>'string','pattern'=>'^\\+?[0-9*#]{1,32}$'],'email'=>['type'=>'string','maxLength'=>254],'owner'=>['type'=>'string','description'=>'PBX administration only: empty for a company contact or an extension in this PBX. Personal endpoints always assign the key owner.']],['phone']);
$spec['components']['schemas']['PersonalStatus']=$obj(['status'=>$str(50),'minutes'=>['type'=>'integer','enum'=>[0,15,30,60,120,240,480]]],['status']);
$spec['components']['schemas']['PersonalQueue']=$obj(['number'=>['type'=>'string','pattern'=>'^[0-9]{2,10}$'],'joined'=>['type'=>'boolean']],['number','joined']);
$spec['components']['schemas']['PersonalAppPassword']=$obj(['current_password'=>['type'=>'string','format'=>'password'],'new_password'=>['type'=>'string','format'=>'password','minLength'=>12,'maxLength'=>128]],['current_password','new_password']);
$spec['components']['schemas']['CallControl']=$obj(['call'=>['type'=>'string','format'=>'uuid'],'operation'=>['enum'=>['hold','resume','transfer','pickup','park','end']],'target'=>$str(20)],['call','operation']);
$spec['components']['schemas']['PersonalSpeedDials']=$obj([]);
for($slot=1;$slot<=9;$slot++){foreach(['label'=>80,'number'=>17] as $name=>$max)$spec['components']['schemas']['PersonalSpeedDials']['properties']['speed_'.$name.'_'.$slot]=$str($max);}
$spec['components']['schemas']['StaffGrant']=$obj(['number'=>$str(10),'department'=>$str(100),'role'=>['enum'=>['user','receptionist','supervisor','department_admin','manager']],'email'=>['type'=>'string','format'=>'email'],'email_invitation'=>['type'=>'boolean']],['number','department','role','email']);
$contracts26=[
 ['/me/status','PersonalStatus',['status'=>'Available','minutes'=>30]],
 ['/me/queues','PersonalQueue',['number'=>'8000','joined'=>true]],
 ['/me/app-password','PersonalAppPassword',['current_password'=>'current-app-password-42','new_password'=>'new-long-app-password-43']],
 ['/me/contacts/create','ContactSave',['first_name'=>'Example','phone'=>'0315550100']],
 ['/me/contacts/{id}','ContactSave',['first_name'=>'Example','phone'=>'0315550101']],
 ['/pbx/{domain_uuid}/contacts','ContactSave',['company'=>'Example supplier','phone'=>'0315550100','owner'=>'']],
 ['/pbx/{domain_uuid}/contacts/{id}','ContactSave',['company'=>'Example supplier','phone'=>'0315550101','owner'=>'']],
 ['/me/call-control','CallControl',['call'=>'10000000-0000-4000-8000-000000000001','operation'=>'hold']],
 ['/staff/call-control','CallControl',['call'=>'10000000-0000-4000-8000-000000000001','operation'=>'hold']],
 ['/me/speed-dials/{id}','PersonalSpeedDials',['speed_label_1'=>'Reception','speed_number_1'=>'0315550100']],
 ['/staff/roles/grant','StaffGrant',['number'=>'1001','department'=>'7000','role'=>'user','email'=>'user@example.com']],
];
foreach($contracts26 as [$path,$schema,$example])$paths[$path]['post']['requestBody']['content']['application/json']=['schema'=>['$ref'=>'#/components/schemas/'.$schema],'example'=>$example];
foreach([['/me/voicemail/{id}','delete','confirm_delete'],['/me/contacts/{id}/delete','post','confirm_delete'],['/me/devices/{id}','delete','confirm_revoke'],['/me/phone-qr-reset','post','confirmed'],['/me/meetings/{id}/cancel','post','confirmed']] as [$path,$verb,$field])$paths[$path][$verb]['requestBody']['content']['application/json']=['schema'=>$obj([$field=>['const'=>true]],[$field]),'example'=>[$field=>true]];
$paths['/me/phone-qr-reset']['post']['description'].=' Also requires me:write and confirmed:true. Reading /me/phone-qr never changes an existing QR code.';
$paths['/me/phone-qr']['post']['description'].=' Returns a private enrollment payload. Keep it secret; viewing or scanning it does not rotate it.';
$paths['/me/app-password']['post']['description'].=' App passwords are independent of desk-phone SIP passwords. Existing app password verification and device revocation behavior are retained.';
$paths['/me/speed-dials/{id}']['post']['description'].=' id is one of your linked account_uuid values from GET /me/speed-dials. Slots omitted from the complete save are cleared, as on My PBX.';
$paths['/keys']['post']['description'].=' Personal/department keys use me:* or staff:* plus optional keys:manage and cannot mix in administrator scopes. Dashboard personal keys are automatically bound to the current web account’s PBX.';
foreach($paths as $path=>&$verbs)foreach($verbs as &$op){$op['tags']??=[str_starts_with($path,'/instance')?'Instance administrators':(str_starts_with($path,'/pbx/')?'PBX administrators':'Tenant administrators and resellers')];}unset($op,$verbs);

// Request fields come from the same validated business methods used by the dashboard.
$source=file_get_contents(dirname(__DIR__).'/resources/classes/pbx_admin.php');
$methods=['users'=>['saveUser','UserSave',['name']],'trunks'=>['saveTrunk','TrunkSave',['name','host']],'departments'=>['saveDepartment','DepartmentSave',['name']],'office-hours'=>['saveHours','OfficeHoursSave',[]],'queues'=>['saveHandling','HandlingSave',['name','number']],'ring-groups'=>['saveHandling','HandlingSave',['name','number']],'receptionists'=>['saveHandling','HandlingSave',['name','number']],'outgoing-rules'=>['saveOutbound','OutgoingRuleSave',['name']],'dids'=>['saveDid','DidSave',['revision','number','trunk_id','destination']],'scripts'=>['saveScript','ScriptSave',[]]];
foreach($methods as $resource=>[$method,$schemaName,$required]){
    if(!preg_match('~(?:public|private) function '.preg_quote($method,'~').'\\([^\\n]+~',$source,$match,PREG_OFFSET_CAPTURE))continue;
    $start=$match[0][1];$rest=substr($source,$start+strlen($match[0][0]));preg_match('~\\n    (?:public|private|protected) function ~',$rest,$next,PREG_OFFSET_CAPTURE);$body=substr($source,$start,strlen($match[0][0])+($next[0][1]??strlen($rest)));
    preg_match_all("~\\\$in\\['([^']+)'\\]|\\\$input\\['([^']+)'\\]|\\\$in,'([^']+)'|\\\$input,'([^']+)'~",$body,$fields26,PREG_SET_ORDER);$props=[];
    foreach($fields26 as $field){$name='';foreach(array_slice($field,1) as $part)if($part!==''){$name=$part;break;}if($name==='')continue;
        $type=in_array($name,['members','departments','periods','break_periods','days','holidays','routes','department_ids','caller_ranges','options','pin_routes','codecs'],true)?'array':(in_array($name,['timeout','override_minutes'],true)?'integer':'string');
        $props[$name]=['type'=>$type];if($type==='array')$props[$name]['items']=new stdClass;
        if(in_array($name,['enabled','register','voicemail_enabled','auto_status','record_calls','send_welcome','always_open','use_holiday','publish_information','ring_mobile','internal_after_hours','department_options_present','departments_present','caller_restrictions_present','internal_hours_present','apply_override'],true))$props[$name]=['type'=>['boolean','string']];
        if(in_array($name,['password','app_password'],true))$props[$name]['format']='password';
    }
    $spec['components']['schemas'][$schemaName]=['type'=>'object','properties'=>$props?:new stdClass,'required'=>$required,'additionalProperties'=>true,'description'=>'Validated dashboard fields. Send the complete intended settings on edits. Department assignment and references must belong to this PBX; secrets are write-only. Optional additional fields include the corresponding dashboard destination/routing fields.'];
    foreach(['/pbx/{domain_uuid}/'.$resource,'/pbx/{domain_uuid}/'.$resource.'/{id}','/staff/'.$resource,'/staff/'.$resource.'/{id}'] as $path)if(isset($paths[$path]['post']))$paths[$path]['post']['requestBody']['content']['application/json']['schema']=['$ref'=>'#/components/schemas/'.$schemaName];
}
$paths['/pbx/{domain_uuid}/users']['post']['requestBody']['content']['application/json']['example']=['name'=>'Example User','email'=>'user@example.com','enabled'=>true,'voicemail_enabled'=>true,'timeout'=>30];
$paths['/pbx/{domain_uuid}/trunks']['post']['requestBody']['content']['application/json']['example']=['name'=>'Example Provider','host'=>'sip.provider.example','authentication'=>'password','username'=>'provider-account','password'=>'replace-with-provider-secret','transport'=>'udp','enabled'=>false,'register'=>true];
$paths['/pbx/{domain_uuid}/dids']['post']['description'].=' First POST actions/did-editor with id:new and trunk. Use its current revision, then send number,trunk_id,destination (for example Extension:1000 or the Call Me Back choice returned by the editor), external when forwarding, enabled and the chosen hours fields. Existing routes use the same single editor.';
$paths['/me/meetings/{id}/invite']['post']['description'].=' Also requires me:write because this explicitly replaces the invitation.';
$spec['tags']=array_map(static fn($name)=>['name'=>$name],['Tenant administrators and resellers','PBX administrators','Department staff','End users','Instance administrators']);
