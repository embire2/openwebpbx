-- Dependency-controlled source tests; these do not claim actual SIP/media.
local M=dofile('app/switch/resources/scripts/app/xml_handler/resources/scripts/directory/mobile_media.lua')
local V=dofile('app/switch/resources/scripts/app/pbx_services/mobile_video.lua')
local count=0
local function check(value,message)assert(value,message);count=count+1 end
local user='owm-'..string.rep('a',32);local other='owm-'..string.rep('b',32)
local domain='11111111-1111-1111-1111-111111111111'
local extension='22222222-2222-2222-2222-222222222222'
local from_extension='33333333-3333-3333-3333-333333333333'
local a='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';local b='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
local allowed={[user]={domain_uuid=domain,extension_uuid=extension,domain_name='pbx.test'}}
check(M.present('sofia/internal/sip:'..user..'@192.0.2.1',allowed),'owned app contact detected')
check(M.present('sofia/internal/sips:'..user..'@192.0.2.1;transport=tls',allowed),'secure contact detected')
for _,contact in ipairs({'error/user_not_registered','sofia/internal/sip:1000@192.0.2.1','sofia/internal/sip:'..other..'@192.0.2.1','sofia/internal/sip:owm-a@192.0.2.1','sofia/internal/sip:owm-'..string.rep('a',33)..'@192.0.2.1'})do check(not M.present(contact,allowed),'ordinary/unowned/invalid contacts preserved')end
local secure=M.suffix(allowed,user,'pbx.test','pbx.test')
for _,part in ipairs({'rtp_secure_media=mandatory,','rtp_secure_media_outbound=mandatory,','rtp_secure_media_suites=AES_CM_128_HMAC_SHA1_80,','openweb_video_device='..user,'openweb_video_domain='..domain,'openweb_video_extension='..extension,"execute_on_post_originate_openweb_video='lua app/pbx_services/mobile_video.lua'"})do check(secure:find(part,1,true),'scoped secure contact '..part)end
check(not secure:find('rtp_pass_codecs',1,true)and not secure:find('execute_on_answer',1,true),'no forwarding on auth or losing answered fork')
check(M.suffix(allowed,user,'alias.test','pbx.test')=='','other realm preserved')
check(M.suffix(allowed,other,'pbx.test','pbx.test')=='','other device preserved')
check(M.suffix(allowed,'1000','pbx.test','pbx.test')=='','desk phone preserved')
local calls=0
local db={query=function(_,sql,args,row)
 calls=calls+1;check(args.domain==domain and args.extension==extension,'exact tenant/extension scope')
 for _,predicate in ipairs({'m.revoked_at is null','m.expires_at>now()',"e.enabled='true'","d.domain_enabled='true'","r.config->>'realm'=d.domain_name","u.value->>'auth_id'=e.extension","u.value->>'enabled'='true'",'not t.enabled'})do check(sql:find(predicate,1,true),'active identity predicate '..predicate)end
 row({sip_username=user,domain_name='pbx.test'});row({sip_username='1000'});row({sip_username='owm-short'})
end}
local actual=M.accounts(db,domain,extension)
check(calls==1 and actual[user].domain_uuid==domain and actual[user].extension_uuid==extension and not actual['1000']and not actual['owm-short'],'returned metadata scoped to exact extension')
local duplicate={query=function(_,sql,args,row)row({sip_username=user,domain_name='pbx.test'});row({sip_username=user,domain_name='pbx.test'})end}
check(not M.accounts(duplicate,domain,extension)[user],'ambiguous restored identity excluded')
check(not M.active(duplicate,domain,extension,user,'pbx.test'),'ambiguous pair identity excluded')
check(not M.identity(duplicate,domain,user,'pbx.test'),'ambiguous authenticated identity excluded')
local resolved=M.identity({query=function(_,sql,args,row)
 check(args.extension==nil and args.domain==domain and args.user==other and args.realm=='pbx.test','authenticated identity resolves without mutable channel extension')
 check(not sql:find('m.extension_uuid=:extension',1,true),'identity SQL derives extension from exact app credentials')
 row({sip_username=other,domain_uuid=domain,extension_uuid=from_extension,domain_name='pbx.test'})
end},domain,other,'pbx.test')
check(resolved.extension_uuid==from_extension,'authenticated identity retains its own extension')
local auth=assert(io.open('app/switch/resources/scripts/app/xml_handler/resources/scripts/directory/mobile.lua')):read('*a')
check(not auth:find('rtp_pass_codecs',1,true),'mobile auth never enables partner forwarding')
local flags={'rtp_pass_codecs_on_stream_change','rtp_pass_codecs_on_reinvite'}
for _,agent in ipairs({'OpenWebPBX-Android/1.0.16','OpenWebPBX-Android/1.0.17','OpenWebPBX-Android/1.1.0','OpenWebPBX-Android/2.0.0','OpenWebPBX-Android/12.34.567'})do check(V.video_capable_agent(agent),'released current/future version capability '..agent)end
check(not V.video_capable_agent(nil)and not V.video_capable_agent(false),'missing/nonstring capability refused')
for _,agent in ipairs({'','OpenWebPBX-Android/1.0.15','OpenWebPBX-Android/0.99.999','OpenWebPBX-Android/1.0.0','OpenWebPBX-Android/01.0.16','OpenWebPBX-Android/1.00.16','OpenWebPBX-Android/1.0.016','OpenWebPBX-Android/1.0','OpenWebPBX-Android/1.0.16.0','OpenWebPBX-Android/1.0.16-beta.1','OpenWebPBX-Android/1.0.16+unknown','OpenWebPBX-Android/1.0.-16','OpenWebPBX-Android/1000000.0.0','OpenWebPBX-Android/'..string.rep('9',100)..'.0.0','openwebpbx-android/1.0.16','OtherApp/2.0.0','OpenWebPBX-Android/1.0.16 extra','OpenWebPBX-Android/1.0.16\n'})do check(not V.video_capable_agent(agent),'unknown/older/malformed capability refused '..agent)end
local function fixture()
 local channels={
  [a]={signal_bond=b,sip_authorized='true',openweb_mobile_device='true',domain_uuid=domain,domain_name='pbx.test',sip_auth_realm='pbx.test',sip_auth_username=other,extension_uuid=from_extension,sip_user_agent='OpenWebPBX-Android/1.0.16',execute_on_answer='record_session keep.wav',execute_on_post_bridge='lua keep.lua'},
  [b]={originating_leg_uuid=a,openweb_video_domain=domain,openweb_video_extension=extension,openweb_video_device=user,sip_invite_domain='pbx.test',sip_user_agent='OpenWebPBX-Android/1.0.16',execute_on_answer='lua keep-answer.lua'}
 }
 local fail_set=false;local changed_bond=false;local queries={};local ready=true;local state='CS_CONSUME_MEDIA';local exists=true
 local api={execute=function(_,command,arg)
  if command=='uuid_exists'then return exists and channels[arg]and 'true'or 'false'end
  local id,key=arg:match('^(%S+) (.*)$')
  if command=='uuid_getvar'then return channels[id]and channels[id][key]or '_undef_'end
  if command=='uuid_setvar_multi'then
   if fail_set then return '-ERR channel unavailable'end
   for part in arg:sub(#id+2):gmatch('[^;]+')do local k,v=part:match('^([^=]+)=(.*)$');channels[id][k]=v~=''and v or nil end
   if changed_bond then channels[a].signal_bond='cccccccc-cccc-cccc-cccc-cccccccccccc'end
   return '+OK'
  end
  error(command)
 end}
 local session={get_uuid=function()return b end,ready=function()return ready end,getState=function()return state end,getVariable=function(_,key)return channels[b][key]end,setVariable=function(_,key,v)channels[b][key]=v end}
 local media={active=function(_,d,e,u,r)queries[#queries+1]={d,e,u,r};return r=='pbx.test' end,
 identity=function(_,d,u,r)queries[#queries+1]={d,from_extension,u,r};return{sip_username=u,domain_uuid=d,extension_uuid=from_extension,domain_name=r}end}
 return {channels=channels,session=session,api=api,media=media,queries=queries,
 fail=function()fail_set=true end,change_bond=function()changed_bond=true end,unready=function()ready=false end,
 set_state=function(_,v)state=v end,disappear=function()exists=false end}
end
local f=fixture()
f.channels[a][flags[1]]='false';f.channels[b][flags[2]]='yes'
check(V.run(f.session,f.api,{},f.media),'selected exact active pair enabled')
check(#f.queries==2 and f.queries[1][1]==domain and f.queries[1][2]==extension and f.queries[1][3]==user and f.queries[2][2]==from_extension and f.queries[2][3]==other,'both active identities checked independently')
for _,id in ipairs({a,b})do for _,key in ipairs(flags)do check(f.channels[id][key]=='true','forward both flags on both selected legs')end end
check(f.channels[a].execute_on_answer=='record_session keep.wav'and f.channels[a].execute_on_post_bridge=='lua keep.lua'and f.channels[b].execute_on_answer=='lua keep-answer.lua','existing recording and bridge hooks preserved')
check(V.run(f.session,f.api,{},f.media),'repeat selected hook idempotent')
check(V.cleanup(f.session,f.api,a),'bridge cleanup completes')
check(f.channels[a][flags[1]]=='false'and f.channels[a][flags[2]]==nil and f.channels[b][flags[1]]==nil and f.channels[b][flags[2]]=='yes','exact prior forwarding policy restored on both legs')
check(not f.channels[a].openweb_mobile_video_peer and not f.channels[b].openweb_mobile_video_peer and not f.channels[a].execute_on_post_bridge_openweb_video and not f.channels[b].execute_on_post_bridge_openweb_video,'owned cleanup markers removed')
check(f.channels[a].execute_on_answer=='record_session keep.wav'and f.channels[a].execute_on_post_bridge=='lua keep.lua','unrelated hooks survive cleanup')
local negative={
 function(x)x.channels[a].signal_bond='cccccccc-cccc-cccc-cccc-cccccccccccc'end,
 function(x)x.channels[b].originating_leg_uuid='invalid'end,
 function(x)x.channels[a].sip_authorized='false'end,
 function(x)x.channels[a].openweb_mobile_device=nil end,
 function(x)x.channels[a].openweb_provider_origin='true'end,
 function(x)x.channels[a].sip_user_agent='OpenWebPBX-Android/1.0.15'end,
 function(x)x.channels[b].sip_user_agent='OpenWebPBX-Android/1.0.15'end,
 function(x)x.channels[a].sip_user_agent=nil end,
 function(x)x.channels[b].sip_user_agent='OtherApp/2.0.0'end,
 function(x)x.channels[a].domain_uuid=extension end,
 function(x)x.channels[a].sip_auth_realm='alias.test'end,
 function(x)x.channels[a].domain_name='alias.test'end,
 function(x)x.channels[a].sip_auth_username='1000'end,
 function(x)x.channels[b].openweb_video_device='1000'end,
 function(x)x.channels[b].openweb_video_domain='invalid'end,
 function(x)x.channels[b].openweb_video_extension='invalid'end,
 function(x)x.channels[b].sip_invite_domain='alias.test'end,
 function(x)x.media.active=function()return false end end,
 function(x)x.media.active=function()error('database unavailable')end end,
 function(x)x.media.identity=function()return nil end end,
 function(x)x.media.identity=function()return{sip_username=other,domain_uuid=extension,extension_uuid=from_extension,domain_name='pbx.test'}end end,
 function(x)x.media.identity=function()return{sip_username=other,domain_uuid=domain,extension_uuid=from_extension,domain_name='alias.test'}end end,
 function(x)x.media.identity=function()return{sip_username=user,domain_uuid=domain,extension_uuid=from_extension,domain_name='pbx.test'}end end,
 function(x)x.media.identity=function()return{sip_username=other,domain_uuid=domain,extension_uuid='invalid',domain_name='pbx.test'}end end,
 function(x)x.channels[a].execute_on_post_bridge_openweb_video='lua unexpected.lua'end,
 function(x)x.channels[b].openweb_mobile_video_peer=extension end,
 function(x)x.channels[a][flags[1]]='value;unsafe'end,
 function(x)x:set_state('CS_HANGUP')end,
 function(x)x:set_state('CS_REPORTING')end,
 function(x)x:set_state('CS_DESTROY')end,
 function(x)x:set_state('CS_RESET')end,
 function(x)x:set_state('CS_NONE')end,
 function(x)x:set_state('ERROR')end,
 function(x)x:disappear()end,
}
for index,mutate in ipairs(negative)do
 local x=fixture();mutate(x)
 local ok,result=pcall(V.run,x.session,x.api,{},x.media)
 check(not ok or not result,'invalid pair denied '..index)
 check(x.channels[a][flags[1]]~='true'and x.channels[b][flags[1]]~='true','denied pair leaves forwarding unchanged '..index)
end
local x=fixture();x:change_bond();check(not V.run(x.session,x.api,{},x.media),'selection change during preparation fails closed')
check(not x.channels[a].openweb_mobile_video_peer and not x.channels[b].openweb_mobile_video_peer and not x.channels[a][flags[1]],'selection change rolls back prepared markers')
x=fixture();x:fail();check(not V.run(x.session,x.api,{},x.media),'missing originator during write fails closed')
check(not x.channels[b][flags[1]]and not x.channels[b].openweb_mobile_video_peer,'failed write never enables callee forwarding')
x=fixture();check(V.run(x.session,x.api,{},x.media),'pair for stale cleanup control enabled')
x.channels[b].openweb_mobile_video_peer=extension
check(not V.cleanup(x.session,x.api,a)and x.channels[a][flags[1]]=='true','stale old cleanup cannot affect a newer ownership marker')
x=fixture();check(V.run(x.session,x.api,{},x.media),'pair for changed custom policy control enabled')
x.channels[a][flags[1]]='false';check(V.cleanup(x.session,x.api,a)and x.channels[a][flags[1]]=='false','cleanup preserves later explicit custom flag change')
x=fixture();x:unready()
check(not x.session:ready()and x.session:getState()=='CS_CONSUME_MEDIA','fixture models native pending transition with ready false')
check(V.run(x.session,x.api,{},x.media),'selected extant pair enabled while native state transition is pending')
check(x.channels[a][flags[1]]=='true'and x.channels[b][flags[1]]=='true','pending transition enables both selected legs')
check(V.cleanup(x.session,x.api,a),'pending-transition pair still cleans up')
x=fixture();x.channels[a].extension_uuid=extension
check(V.run(x.session,x.api,{},x.media),'overwritten caller channel extension does not reject genuine authenticated caller')
check(x.queries[2][2]==from_extension and x.queries[2][3]==other,'caller resolves own DB account independently of callee UUID')
check(V.cleanup(x.session,x.api,a),'overwritten caller field still cleans up exact selected pair')
x=fixture();x.channels[a].sip_user_agent='OpenWebPBX-Android/2.0.0';x.channels[b].sip_user_agent='OpenWebPBX-Android/1.1.0'
check(V.run(x.session,x.api,{},x.media),'both authenticated future released clients enable selected-pair forwarding')
check(V.cleanup(x.session,x.api,a),'future-capable pair retains cleanup')
x=fixture();x.channels[a].sip_user_agent='OpenWebPBX-Android/1.0.15'
check(not V.run(x.session,x.api,{},x.media)and #x.queries==2,'capability is checked only after both active DB identity proofs')
check(not x.channels[a].openweb_mobile_video_peer and not x.channels[b].openweb_mobile_video_peer,'mixed old/new pair preserves default media and namespace')
print('PASS '..count..' native-app selected-pair media controls (dependency doubles; actual SIP/SQL/media qualification separate).')
