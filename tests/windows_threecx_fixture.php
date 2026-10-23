<?php
/** Invented V20 Update 9 ZIP; no customer backup or usable provider. */
function windows_threecx_fixture(string $directory):array {
    if(!is_dir($directory)||is_link($directory))throw new InvalidArgumentException('An owned ordinary fixture directory is required.');
    $escape=static fn(string $v)=>htmlspecialchars($v,ENT_XML1|ENT_QUOTES,'UTF-8');
    $users=[['number'=>'9100','auth'=>'source-login-9100','password'=>'  Synthetic & <source> " one  '],['number'=>'9101','auth'=>'source-login-9101','password'=>'Second & " exact source password']];
    $extensions='';foreach($users as$i=>$user){
        $phone=$i===0?'<PhoneDevices><PhoneDevice><MAC>001122334455</MAC><TemplateFilename>fanvil.ph.xml</TemplateFilename><Settings>'.$escape('<PhoneDevice><BLFS><Key value="9101"/></BLFS></PhoneDevice>').'</Settings></PhoneDevice></PhoneDevices>':'';
        $extensions.='<Extension><Number>'.$user['number'].'</Number><FirstName>Fictional '.$user['number'].'</FirstName><AuthID>'.$user['auth'].'</AuthID><AuthPassword>'.$escape($user['password']).'</AuthPassword><VMPIN>991122</VMPIN><VMEnabled>True</VMEnabled><VMEmailOptions>None</VMEmailOptions><CurrentProfile>Available</CurrentProfile><FwdProfiles><FwdProfile><Name>Available</Name><NoAnswerTimeout>20</NoAnswerTimeout></FwdProfile></FwdProfiles>'.$phone.'</Extension>';
    }
    $xml='<PhoneSystem><header><version>20.0.9.995</version></header><Gateways><VoipProvider><Name>Fictional disconnected provider</Name><Host>198.51.100.10</Host><Port>5060</Port><RequireRegistrationFor>InOutCalls</RequireRegistrationFor></VoipProvider></Gateways><Tenants><Tenant><DN>'.$extensions.
        '<RingGroup><Number>9180</Number><Name>Fictional restored group</Name><RingStrategy>RingAll</RingStrategy><RingTime>20</RingTime><Members><Member DN="9101"/><Member DN="9100"/></Members><Destination><To>VoiceMail</To><Internal DN="9100"/></Destination></RingGroup>'.
        '<IVR><Number>9170</Number><Name>Fictional restored menu</Name><PromptFilename>menu.wav</PromptFilename><Timeout>5</Timeout><TimeoutForwardType>RingGroup</TimeoutForwardType><TimeoutForwardDN>9180</TimeoutForwardDN></IVR>'.
        '<ExternalLine><Number>10000</Number><Gateway>Fictional disconnected provider</Gateway><ExternalNumber>999120001</ExternalNumber><DIDNumbers>999120001</DIDNumbers><AuthID>fictional-provider</AuthID><AuthPassword>fictional-unusable-provider</AuthPassword><RoutingRules><ExternalLineRule><RuleName>Fictional restored incoming</RuleName><Conditions><Condition Type="ForwardAll"/></Conditions><ForwardDestinations><OfficeHoursDestination><To>RingGroup</To><Internal DN="9180"/></OfficeHoursDestination><OutOfOfficeHoursDestination><To>VoiceMail</To><Internal DN="9100"/></OutOfOfficeHoursDestination></ForwardDestinations></ExternalLineRule></RoutingRules></ExternalLine>'.
        '</DN></Tenant></Tenants></PhoneSystem>';
    $wav=static function(int $frequency):string{$pcm='';for($i=0;$i<1600;$i++)$pcm.=pack('v',(int)(sin(2*M_PI*$frequency*$i/8000)*10000)&65535);return 'RIFF'.pack('V',36+strlen($pcm)).'WAVEfmt '.pack('VvvVVvv',16,1,1,8000,16000,2,16).'data'.pack('V',strlen($pcm)).$pcm;};
    $media=['vmailprompts/9100/custom greeting.wav'=>$wav(440),'httpprompts/menu.wav'=>$wav(550),'voicemails/9100/vmail_555_1_20261022090000.wav'=>$wav(660),'recordings/example recording.wav'=>$wav(770)];
    $archive=$directory.'/synthetic V20.zip';$zip=new ZipArchive();if($zip->open($archive,ZipArchive::CREATE|ZipArchive::EXCL)!==true)throw new RuntimeException('The synthetic archive could not be created.');
    try{$zip->addFromString('123456Db.xml',$xml);foreach($media as$name=>$bytes)$zip->addFromString($name,$bytes);}finally{$zip->close();}
    return ['archive'=>$archive,'users'=>$users,'media'=>$media];
}
