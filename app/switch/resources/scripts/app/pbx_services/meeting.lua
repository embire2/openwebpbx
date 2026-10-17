-- One admitted room per authenticated browser credential; regular phones stay tenant-bound.
local Database=require 'resources.functions.database'
local identity=require 'resources.functions.mailbox_identity'
local db=Database.new('system');local member,meeting
local function query(sql,args)local rows={};db:query(sql,args,function(r)rows[#rows+1]=r end);return rows[1] end
local call=session:get_uuid()
local function release_member()
 if member then db:query("update v_pbx_meeting_members set call_uuid=null,state=case when state='removed' then 'removed' else 'left' end,seen_at=now() where member_uuid=:id and call_uuid=:call",{id=member.member_uuid,call=call}) end
end
local function refuse()release_member();db:release();if session:ready() then session:hangup('CALL_REJECTED') end end
local auth=session:getVariable('sip_auth_username') or ''
-- This early global extension continues to ordinary routes for numbers that
-- are not an actual meeting on this PBX, including existing 98... numbers.
if not auth:match('^owc%-[a-f0-9]+$') then
 local domain=session:getVariable('domain_uuid') or ''
 if #domain~=36 or not domain:match('^[a-f0-9%-]+$') then db:release();return end
 meeting=query('select meeting_uuid::text,domain_uuid::text from v_pbx_meetings where domain_uuid=:domain and dial_number=:number',{domain=domain,number=session:getVariable('destination_number')})
 if not meeting then db:release();return end
end
if session:getVariable('sip_authorized')~='true' or session:getVariable('provider_origin')=='true' or session:getVariable('openweb_provider_origin')=='true' then refuse();return end
if auth:match('^owc%-[a-f0-9]+$') then
 member=query([[select a.member_uuid::text,a.meeting_uuid::text,a.member_name,a.state,a.role,a.muted::text,p.domain_uuid::text
 from v_pbx_meeting_members a join v_pbx_meetings p using(meeting_uuid) join v_domains d using(domain_uuid)
 where a.sip_username=:auth and d.domain_name=:realm and a.state='admitted' and p.dial_number=:number]],
 {auth=auth,realm=session:getVariable('sip_auth_realm'),number=session:getVariable('destination_number')})
 if not member then refuse();return end
else
 local p=identity.principal(session,db);if not p then refuse();return end
 meeting=query("select meeting_uuid::text,domain_uuid::text from v_pbx_meetings where domain_uuid=:domain and dial_number=:number",{domain=p.domain_uuid,number=session:getVariable('destination_number')})
 if not meeting then refuse();return end
 local api=freeswitch.API();local id=api:execute('create_uuid','');id=id:gsub('%s','')
 local token=api:execute('create_uuid',''):gsub('%s','');local username='phone-'..id:gsub('%-','')
 db:query('begin')
 db:query('select meeting_uuid from v_pbx_meetings where meeting_uuid=:id for update',{id=meeting.meeting_uuid})
 db:query([[insert into v_pbx_meeting_members(member_uuid,meeting_uuid,member_name,role,state,token_hash,sip_username,sip_a1_hash)
 select :id,meeting_uuid,:name,'guest',case when lobby_required then 'waiting' else 'admitted' end,
 md5(:token)||md5(:id),:username,md5(:token) from v_pbx_meetings
 where meeting_uuid=:meeting and ended_at is null and not locked and now() between starts_at-interval '15 minutes' and ends_at
 and (select count(*) from v_pbx_meeting_members where meeting_uuid=:meeting and state in ('waiting','admitted'))<24]],
 {id=id,meeting=meeting.meeting_uuid,name='Phone '..p.number,token=token,username=username})
 db:query('commit')
 member=query('select member_uuid::text,meeting_uuid::text,member_name,state,role,muted::text from v_pbx_meeting_members where member_uuid=:id',{id=id})
 if not member then refuse();return end
 member.domain_uuid=p.domain_uuid
end
local function current()
 return query([[select p.meeting_uuid::text,p.domain_uuid::text,p.video_enabled::text,p.started_at::text,
 extract(epoch from (p.ends_at-now()))::int as remaining,a.state,a.muted::text,a.role
 from v_pbx_meetings p join v_pbx_meeting_members a using(meeting_uuid) join v_domains d using(domain_uuid)
 where a.member_uuid=:id and p.ended_at is null and d.domain_enabled='true' and now() between p.starts_at-interval '15 minutes' and p.ends_at
 and not exists(select 1 from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=d.domain_uuid and not t.enabled)]],{id=member.member_uuid})
end
-- The server-owned marker exists before a host can observe the claimed UUID.
session:setVariable('openweb_meeting_member',member.member_uuid)
db:query('begin')
local open=query([[select p.meeting_uuid::text from v_pbx_meetings p join v_pbx_meeting_members a using(meeting_uuid)
 join v_domains d using(domain_uuid) where a.member_uuid=:id and a.state in ('waiting','admitted')
 and p.ended_at is null and d.domain_enabled='true' and now() between p.starts_at-interval '15 minutes' and p.ends_at
 and not exists(select 1 from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=d.domain_uuid and not t.enabled)
 for update of p]],{id=member.member_uuid})
local claimed
if open then claimed=query([[update v_pbx_meeting_members set call_uuid=:call,seen_at=now()
 where member_uuid=:id and state in ('waiting','admitted') and call_uuid is null returning call_uuid::text]],{call=call,id=member.member_uuid}) end
db:query('commit')
if not claimed or claimed.call_uuid~=call then refuse();return end
meeting=current();if not meeting then refuse();return end
session:answer();session:setVariable('playback_terminators','none')
local until_ms=tonumber(freeswitch.API():getTime())+120000
while session:ready() and meeting and (meeting.state=='waiting' or not meeting.started_at) and tonumber(freeswitch.API():getTime())<until_ms do
 session:execute('playback','tone_stream://%(1000,0,350);loops=1');session:sleep(500);meeting=current()
end
if not session:ready() or not meeting or meeting.state~='admitted' or not meeting.started_at then refuse();return end
session:setVariable('domain_uuid',meeting.domain_uuid)
session:setVariable('openweb_meeting_member',member.member_uuid)
session:setVariable('effective_caller_id_name',member.member_name)
session:setVariable('conference_controls','none')
session:setVariable('conference_moderator_controls','none')
session:setVariable('hangup_after_conference','true')
session:execute('sched_hangup','+'..tostring(math.max(1,tonumber(meeting.remaining) or 1))..' NORMAL_CLEARING')
local flags='waste'..(meeting.video_enabled~='true' and '|vmute|blind' or '')..(meeting.role=='host' and '|moderator' or '')..(meeting.muted=='true' and '|mute' or '')
session:execute('conference','owmeet-'..meeting.meeting_uuid..'@openweb-meet+'..'flags{'..flags..'}')
release_member();db:release();if session:ready() then session:hangup('NORMAL_CLEARING') end
