-- OpenWeb PBX: restored V20 calling behavior. No customer settings belong in this file.
local args=...
-- A scheduled exit belongs only to this caller's current wait. It must never
-- interrupt an answered bridge or a later queue visit on the same channel.
if args and args[2]=='queue_limit' then
    local function uuid(v)return type(v)=='string' and #v==36 and v:match('^[a-f0-9%-]+$')end
    local domain,queue,id,token=args[3],args[4],args[5],args[6]
    if uuid(domain) and uuid(id) and uuid(token) and type(queue)=='string' and #queue<=10 and queue:match('^%d%d%d*$') then
        local api=freeswitch.API()
        local function get(name)return (api:execute('uuid_getvar',id..' '..name) or ''):gsub('%s+$','')end
        if api:execute('uuid_exists',id):gsub('%s+$','')=='true' and get('domain_uuid')==domain
          and get('queue_extension')==queue and get('openweb_queue_limit_token')==token
          and get('openweb_queue_waiting')=='true' and get('cc_agent_bridged')~='true' and get('cc_agent_found')~='true' then
            -- mod_callcenter resumes MOH after uuid_break. Its DTMF exit is
            -- caller-local and cancels outstanding agent offers before return.
            api:execute('uuid_recv_dtmf',id..' D')
        end
    end
    return
end
if not session or not session:ready() then return end
local Database=require 'resources.functions.database'
local json=require 'resources.functions.lunajson'
local P=loadfile(scripts_dir..'/app/pbx_setup/policy.lua')()
local attempts=loadfile(scripts_dir..'/app/pbx_setup/provider_attempts.lua')()
local registered=loadfile(scripts_dir..'/app/pbx_setup/registered.lua')()
local Q=loadfile(scripts_dir..'/app/pbx_setup/core_queue.lua')()
local queue_runtime=loadfile(scripts_dir..'/app/pbx_setup/queue_runtime.lua')()
local agent_contact=loadfile(scripts_dir..'/app/pbx_setup/core_agent_contact.lua')()
local mobile_contact=loadfile(scripts_dir..'/app/pbx_setup/mobile_contact.lua')()
local db=Database.new('system')
local api=freeswitch.API()
local domain=session:getVariable('domain_uuid') or ''
local config
db:query([[select r.config from v_pbx_restore r join v_domains d using(domain_uuid)
    where r.domain_uuid=:domain and d.domain_enabled='true' and not exists
    (select 1 from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=r.domain_uuid and not t.enabled)]],
    {domain=domain},function(row) config=json.decode(row.config) end)
if not config then db:release();session:hangup('UNALLOCATED_NUMBER');return end
local realm=config.realm
local contact_realms=loadfile(scripts_dir..'/app/xml_handler/resources/scripts/directory/contact_realms.lua')()
local owned_realms=contact_realms.realms(db,domain,realm)
if not P.realm_config(config,owned_realms) then db:release();session:hangup('CALL_REJECTED');return end
local mode,key=args[2],args[3]
local caller=session:getVariable('effective_caller_id_number') or session:getVariable('caller_id_number') or ''
local auth=session:getVariable('sip_auth_username') or session:getVariable('user_name')
local authenticated_user=false
-- An incoming provider may present an Authorization user resembling a local
-- user. It remains external after transfers within this tenant's dialplan.
local auth_realm=session:getVariable('sip_auth_realm')
if type(auth)=='string' and auth~='' and (not auth_realm or P.realm_allowed(owned_realms,auth_realm)) and mode~='incoming' and session:getVariable('openweb_provider_origin')~='true' then
    for number,u in pairs(config.users) do if u.enabled and u.auth_id==auth then caller=number;authenticated_user=true;break end end
    if not authenticated_user and auth:match('^owm%-[a-f0-9]+$') then
        local extension
        db:query([[select m.extension_uuid from v_pbx_mobile_devices m join v_extensions e using(extension_uuid)
            where m.domain_uuid=:domain and e.domain_uuid=:domain and e.enabled='true' and m.sip_username=:auth
            and m.revoked_at is null and m.expires_at>now()]],{domain=domain,auth=auth},function(r) extension=r.extension_uuid end)
        for number,u in pairs(config.users) do if extension and u.enabled and u.extension_uuid==extension then caller=number;authenticated_user=true;break end end
        if not authenticated_user then db:release();session:hangup('CALL_REJECTED');return end
    end
end
local internal=authenticated_user and mode~='incoming'
-- Server-derived scope markers; raw caller ID and SIP headers never grant staff access.
session:setVariable('openweb_scope_origin',authenticated_user and tostring(caller) or '')
session:setVariable('openweb_scope_target',tostring(key or ''))
session:setVariable('openweb_scope_service',tostring(key or ''))
if mode=='record_user' then internal=session:getVariable('openweb_call_internal')=='true' end
if authenticated_user and mode~='incoming' and mode~='record_user' then session:setVariable('call_direction','local') end
local function clock(zone)
    local result=api:execute('strftime_tz',(zone or 'Africa/Johannesburg')..' %w_%H:%M_%Y-%m-%d')
    local day,time,date=result:match('^(%d)_(%d%d:%d%d)_(%d%d%d%d%-%d%d%-%d%d)')
    if not day then error('Office-hours clock unavailable') end
    return tonumber(day),time,date
end
local depth=tonumber(session:getVariable('openweb_route_depth') or '0')
session:setVariable('openweb_route_depth',tostring(depth+1))
if depth>=20 then db:release();session:hangup('EXCHANGE_ROUTING_ERROR');return end
session:setVariable('domain_name',realm)
session:setVariable('hangup_after_bridge','false')
session:setVariable('continue_on_fail','true')
local route,run_user,run_group,run_queue,run_ivr,run_outbound
local queue_cleanup
local function hotel_room(number)
    local room
    db:query('select occupied,do_not_disturb from v_pbx_hotel_rooms where domain_uuid=:domain and number=:number',{domain=domain,number=tostring(number)},function(r) room=r end)
    return room
end
local function voicemail(number,check)
    local u=config.users[tostring(number)]
    if not u or not u.voicemail_enabled then session:hangup('NO_ANSWER');return end
    local room=hotel_room(number)
    if room and room.occupied~='t' and room.occupied~='true' then session:hangup('CALL_REJECTED');return end
    session:answer();session:setVariable('voicemail_id',tostring(number))
    -- The native voicemail application dispatches caller recording as "save".
    -- An unknown action answers the channel but returns without greeting/recording.
    session:setVariable('voicemail_action',check and 'check' or 'save')
    session:execute('lua','app.lua voicemail')
end
local function record(u,external)
    if not u.record_calls or session:getVariable('openweb_recording')=='true' then return end
    if u.record_external_only and internal and not external then return end
    local id=session:getVariable('uuid')
    if not id or not id:match('^[a-f0-9%-]+$') then return end
    local dir=storage_dir..'/openwebpbx/'..domain
    session:setVariable('openweb_recording','true');session:setVariable('record_path',dir)
    session:setVariable('record_name',id..'.wav');session:setVariable('record_stereo','true')
    local path=dir..'/'..id..'.wav'
    session:execute('record_session',path)
    db:query([[insert into v_pbx_media(media_uuid,domain_uuid,category,source_path,file_path,title,owner_number,created_at)
        values(:id,:domain,'recordings',:source,:path,:title,:owner,now()) on conflict do nothing]],
        {id=id,domain=domain,source='calls/'..id..'.wav',path=path,title='Call '..tostring(u.number),owner=tostring(u.number)})
end
local function outbound_contact(number,rule_route,owner)
    local t=config.trunks[tostring(rule_route.trunk_id)]
    if not t then return nil end
    if type(t.gateway_uuid)~='string' or #t.gateway_uuid~=36 or not t.gateway_uuid:match('^[a-fA-F0-9%-]+$') then return nil end
    local native
    db:query('select enabled,register,from_domain,from_user,username,proxy,outbound_proxy,register_transport,profile from v_gateways where gateway_uuid=:id and domain_uuid=:domain',{id=t.gateway_uuid,domain=domain},function(row) native=row end)
    if not native or not P.gateway_available(native,api:execute('sofia','status gateway '..t.gateway_uuid)) then return nil end
    return P.outbound_leg(t,rule_route,number,config.users[tostring(owner or caller)],caller,domain,realm,native)
end
local mobile_wake=loadfile(scripts_dir..'/app/pbx_setup/mobile_wake.lua')()
local function user_contact(u,timeout,queue)
    local profile=P.profile(config,u.number,clock)
    if queue and (agent_contact.push(db,domain,u) or mobile_contact.enabled(u,profile)) then
        -- The native queue expands this against the member actually offered,
        -- rather than the last caller who refreshed the shared agent contact.
        local dial=agent_contact.dial(domain,realm,u,{number=queue,ring_timeout=timeout},'${uuid}',nil,'${openweb_call_internal}')
        if dial then return dial end
    end
    local call=queue and '${uuid}' or session:getVariable('uuid');local origin=queue and '${openweb_call_internal}' or tostring(internal)
    local variables='extension_uuid='..u.extension_uuid..',openweb_scope_origin='..(queue and '${openweb_scope_origin}' or tostring(authenticated_user and caller or ''))..',openweb_scope_target='..u.number..',sip_h_X-OpenWeb-Push-ID='..call..',rtp_secure_media=optional:AES_CM_128_HMAC_SHA1_80,leg_timeout='..timeout..',domain_uuid='..domain..',domain_name='..realm..',openweb_call_internal='..origin
    if u.record_calls and not (u.record_external_only and internal) then
        variables=variables..",execute_on_answer='lua app.lua pbx_setup record_user "..u.number.."'"
    end
    if queue then variables=variables..",api_on_answer='lua app/pbx_setup/core_queue_answer.lua "..domain..' '..queue..' '..call..' '..u.number.."'"
    else variables=variables..",api_on_answer='uuid_setvar "..call..' openweb_scope_target '..u.number.."'" end
    local phone='['..variables..']user/'..u.auth_id..'@'..realm
    if not queue and mobile_contact.available(db,api,P,domain,config,u,profile) then
        local mobile=mobile_contact.dial(domain,realm,u,timeout,session:getVariable('uuid'),internal)
        if mobile then
            -- The loopback app endpoint pre-answers before Lua starts. It is
            -- only a candidate until its ordinary provider leg answers.
            session:setVariable('ignore_early_media','true')
            if registered(db,api,P,domain,u,realm) then return phone..','..mobile end
            return mobile
        end
    end
    return phone
end
run_outbound=function(number,owner)
    local origin=tostring(owner or caller)
    local emergency=P.emergency(config,number)
    if emergency and (not authenticated_user or origin~=tostring(caller)) then session:hangup('CALL_REJECTED');return end
    local room=hotel_room(origin)
    if not emergency and room and room.occupied~='t' and room.occupied~='true' then session:hangup('CALL_REJECTED');return end
    if not number:match('^%+?[%d*#]+$') then session:hangup('UNALLOCATED_NUMBER');return end
    local rule=emergency or P.outbound(config,number,origin)
    if not rule then session:hangup('CALL_REJECTED');return end
    for _,r in ipairs(rule.routes) do
        local contact=outbound_contact(number,r,origin)
        contact=contact and P.track_answer(contact,session:getVariable('uuid'))
        local observation=attempts.begin(db,api,session,domain,config.trunks[tostring(r.trunk_id)],origin,number,contact~=nil)
        contact=attempts.contact(observation,contact)
        if contact then
            session:setVariable('call_direction','outbound')
            session:setVariable('provider_uuid',config.trunks[tostring(r.trunk_id)].gateway_uuid)
            if emergency then session:setVariable('openweb_emergency_call','true') end
            -- Directory call_timeout belongs to the user's incoming ring
            -- profile. FreeSWITCH also reads it on the caller's provider
            -- originate, so explicitly give each provider attempt its own
            -- bounded setup/ringing window, including forwarded calls.
            local timeout=60
            if mode=='mobile' then timeout=math.min(timeout,math.max(0,(tonumber(session:getVariable('openweb_mobile_deadline')) or 0)-os.time())) end
            if timeout<=0 then session:hangup('NO_ANSWER');return end
            session:setVariable('call_timeout',tostring(timeout))
            contact='{openweb_scope_origin='..origin..',openweb_scope_target='..origin..',originate_timeout='..timeout..',progress_timeout='..timeout..'}'..contact:gsub('^%[','[leg_timeout='..timeout..',',1)
            if config.users[origin] then record(config.users[origin],true) end
            session:setVariable('originate_disposition','')
            session:setVariable('last_bridge_proto_specific_hangup_cause','')
            session:setVariable('sip_invite_failure_status','')
            session:setVariable('openweb_provider_answered','false')
            session:execute('bridge',contact)
            local cause=session:getVariable('originate_disposition')
            local answered=cause=='SUCCESS' or session:getVariable('openweb_provider_answered')=='true'
            local retry=session:ready() and not answered and P.failover(cause,session:getVariable('last_bridge_proto_specific_hangup_cause'),session:getVariable('openweb_provider_answered'),session:getVariable('sip_invite_failure_status'))
            attempts.finish(db,observation,cause,session:getVariable('last_bridge_proto_specific_hangup_cause'),session:getVariable('sip_invite_failure_status'),answered,session:ready(),retry)
            if not session:ready() or answered then return end
            if not retry then
                session:hangup(cause or 'NORMAL_TEMPORARY_FAILURE');return
            end
        end
    end
    session:hangup('NORMAL_TEMPORARY_FAILURE')
end
route=function(destination,owner)
    if not session:ready() then return end
    session:setVariable('openweb_mobile_wake_targets','')
    destination=destination or {type='None'}
    local kind=destination.type
    local number=destination.number~='' and destination.number or owner
    if kind=='VoiceMail' then voicemail(number,false)
    elseif kind=='External' or kind=='Boomerang' then run_outbound(destination.external~='' and destination.external or (config.users[tostring(owner)] or {}).mobile or '',owner)
    elseif kind=='None' or kind=='EndCall' then session:hangup('NORMAL_CLEARING')
    elseif number and tostring(number):match('^[%d*SPQCB]+$') then session:transfer(tostring(number),'XML',realm)
    else session:hangup('UNALLOCATED_NUMBER') end
end
run_user=function(number)
    local u=config.users[tostring(number)]
    if not u or not u.enabled then session:hangup('UNALLOCATED_NUMBER');return end
    session:setVariable('openweb_scope_target',tostring(number))
    local room=hotel_room(number)
    if room and (room.do_not_disturb=='t' or room.do_not_disturb=='true') then voicemail(number,false);return end
    local special=P.object_destination(config,u,clock)
    if special then route(special,number);return end
    local profile=P.profile(config,number,clock)
    local open=P.office(config,number,clock)
    if next(profile.away or {}) then route(P.forward(profile,'NoAnswer',internal,open),number);return end
    if (profile.busy_detection or 'UsePBXStatus')=='UsePBXStatus' then
        local ok,channels=pcall(json.decode,api:execute('show','channels as json'))
        if ok and P.user_busy(channels,u,realm,session:getVariable('uuid'),owned_realms) then route(P.forward(profile,'Busy',internal,open),number);return end
    end
    mobile_wake(db,api,P,session,domain,{u})
    local contact=registered(db,api,P,domain,u,realm)
    local mobile=mobile_contact.available(db,api,P,domain,config,u,profile) and mobile_contact.dial(domain,realm,u,profile.timeout,session:getVariable('uuid'),internal)
    if not P.contact(contact) and not mobile then route(P.forward(profile,'NotRegistered',internal,open),number);return end
    session:setVariable('call_timeout',tostring(profile.timeout));session:setVariable('origination_callee_id_name',u.name)
    session:setVariable('origination_callee_id_number',tostring(number));record(u)
    local bridge=P.contact(contact) and '[domain_uuid='..domain..',extension_uuid='..u.extension_uuid..',openweb_scope_origin='..tostring(authenticated_user and caller or '')..',openweb_scope_target='..u.number..',sip_h_X-OpenWeb-Push-ID='..session:getVariable('uuid')..',rtp_secure_media=optional:AES_CM_128_HMAC_SHA1_80,leg_timeout='..profile.timeout..']user/'..u.auth_id..'@'..realm or nil
    if mobile then
        session:setVariable('ignore_early_media','true')
        bridge=bridge and bridge..','..mobile or mobile
    end
    session:setVariable('originate_disposition','')
    session:execute('bridge',bridge)
    if not session:ready() then return end
    local cause=session:getVariable('originate_disposition') or ''
    if cause=='SUCCESS' then session:hangup('NORMAL_CLEARING');return end
    local reason=(cause=='USER_BUSY' or cause=='CALL_REJECTED') and 'Busy' or 'NoAnswer'
    route(P.forward(profile,reason,internal,open),number)
end
run_group=function(number)
    local group=P.find(config.ring_groups,number)
    if not group then session:hangup('UNALLOCATED_NUMBER');return end
    local special=P.object_destination(config,group,clock);if special then route(special,number);return end
    local strategy=P.ring_strategy(group.native_strategy or group.strategy)
    if not strategy then session:hangup('INCOMPATIBLE_DESTINATION');return end
    local wake_users={}
    for _,m in ipairs(group.members or {}) do local u=config.users[tostring(m.number)];if u and u.enabled and not P.profile(config,tostring(m.number),clock).disable_ring_groups then wake_users[#wake_users+1]=u end end
    mobile_wake(db,api,P,session,domain,wake_users)
    local contacts={}
    for _,m in ipairs(group.members or {}) do
        local u=config.users[tostring(m.number)]
        if u and u.enabled then local profile=P.profile(config,m.number,clock)
            if not profile.disable_ring_groups then table.insert(contacts,user_contact(u,group.timeout)) end
        end
    end
    session:setVariable('ring_group_uuid',group.uuid)
    session:setVariable('call_timeout',tostring(group.timeout))
    session:setVariable('originate_timeout',tostring(group.timeout))
    session:setVariable('progress_timeout',tostring(group.timeout))
    session:setVariable('originate_disposition','')
    local answered=false
    if strategy=='sequence' then
        for _,contact in ipairs(contacts) do
            if not session:ready() then return end
            session:execute('bridge',contact)
            if session:getVariable('originate_disposition')=='SUCCESS' then answered=true;break end
        end
    elseif #contacts>0 then
        session:execute('bridge',table.concat(contacts,','))
        answered=session:getVariable('originate_disposition')=='SUCCESS'
    end
    if session:ready() then
        if answered then session:hangup('NORMAL_CLEARING') else route(group.destination,number) end
    end
end
run_queue=function(number)
    local q=P.find(config.queues,number)
    if not q then session:hangup('UNALLOCATED_NUMBER');return end
    local special=P.object_destination(config,q,clock);if special then route(special,number);return end
    local queue_callid=session:getVariable('uuid')
    local ok_join,joined=pcall(Q.join,db,domain,number,queue_callid,q.capacity or 0)
    if not ok_join then session:hangup('NORMAL_TEMPORARY_FAILURE');return end
    if not joined then route(q.destination,number);return end
    local cleaned=false
    queue_cleanup=function()
        if cleaned then return end;cleaned=true
        session:setVariable('cc_exit_keys','')
        session:setVariable('openweb_queue_waiting','false')
        session:setVariable('openweb_queue_limit_token','')
        session:setVariable('cc_last_agent_tier_level','')
        session:setVariable('cc_last_agent_tier_position','')
        Q.finish(db,domain,number,queue_callid,session,joined)
    end
    -- A transferred caller can carry flags from an earlier queue bridge.
    -- Initialize this visit before its invitation starts the first wait guard.
    session:setVariable('cc_agent_bridged','false');session:setVariable('cc_agent_found','false')
    session:setVariable('cc_exit_key','');session:setVariable('cc_exit_keys','')
    queue_runtime.ensure(api,config,q,domain,function(u)return user_contact(u,q.ring_timeout,number)end)
    session:setVariable('openweb_call_internal',tostring(internal))
    for _,m in ipairs(q.members) do
        local u=config.users[tostring(m.number)]
        local profile=u and P.profile(config,m.number,clock)
        local reserved=false
        db:query("select 1 as ok from v_pbx_jobs where domain_uuid=:domain and agent_number=:number and state in ('starting','calling')",{domain=domain,number=tostring(m.number)},function() reserved=true end)
        local status=P.queue_member_status(u,m,profile,reserved)
        if u and u.enabled then api:execute('callcenter_config','agent set contact '..m.agent_uuid..' '..user_contact(u,q.ring_timeout,number)) end
        api:execute('callcenter_config',"agent set status "..m.agent_uuid.." '"..status.."'")
    end
    local _,source_mode=P.queue_strategy(q.strategy)
    local polling_mode=q.polling_mode or source_mode or 'native'
    if polling_mode=='random_start' and #(q.members or {})>0 then
        session:setVariable('cc_last_agent_tier_level','1')
        session:setVariable('cc_last_agent_tier_position',tostring(P.hunt_start(q.members,queue_callid)))
    else
        session:setVariable('cc_last_agent_tier_level','0')
        session:setVariable('cc_last_agent_tier_position','0')
    end
    session:answer();session:setVariable('call_center_queue_uuid',q.uuid)
    session:setVariable('queue_extension',tostring(number))
    if q.intro~='' then session:streamFile(q.intro) end
    local callback_mode=q.callback_mode or 'disabled'
    local callback_valid=caller:match('^%+?%d+$') and #caller<=32
    local started=os.time()
    if q.announce_position or q.announce_wait or (q.announce_sound and q.announce_sound~='') then api:execute('luarun','app/pbx_setup/core_queue_announce.lua '..domain..' '..number..' '..queue_callid) end
    local offered=false
    local function timed_wait(seconds,action)
        if seconds<=0 then return end
        local token=api:execute('create_uuid',''):gsub('%s+$','')
        if #token~=36 or not token:match('^[a-f0-9%-]+$') then error('Queue wait guard unavailable') end
        session:setVariable('openweb_queue_limit_token',token)
        session:setVariable('openweb_queue_waiting','true')
        local task=api:execute('sched_api','+'..seconds..' openweb-queue-'..queue_callid..' lua app.lua pbx_setup queue_limit '..domain..' '..number..' '..queue_callid..' '..token)
        local task_id=task and task:match('Added:%s*(%d+)')
        if not task_id then
            session:setVariable('openweb_queue_waiting','false');session:setVariable('openweb_queue_limit_token','')
            error('Queue wait guard unavailable')
        end
        local ok,result=pcall(action)
        session:setVariable('openweb_queue_waiting','false')
        session:setVariable('openweb_queue_limit_token','')
        api:execute('sched_del',task_id)
        if not ok then error(result) end
        return result
    end
    local function request_callback()
        if not callback_valid then return false end
        local stored=false
        db:query([[insert into v_pbx_jobs(job_uuid,domain_uuid,kind,queue_number,target_number,internal_target,request_key,max_attempts)
          select :id,:domain,'callback',:queue,:target,cast(:internal as boolean),:request,:attempts
          where (select count(*) from v_pbx_jobs where domain_uuid=:domain and kind='callback' and state in ('waiting','starting','calling'))<1000
          on conflict do nothing returning job_uuid]],
          {id=api:execute('create_uuid',''):gsub('%s+$',''),domain=domain,queue=tostring(number),target=caller,internal=tostring(internal),request='call/'..session:getVariable('uuid'),attempts=q.callback_attempts or 3},function() stored=true end)
        if not stored then db:query("select 1 as ok from v_pbx_jobs where domain_uuid=:domain and kind='callback' and queue_number=:queue and target_number=:target and state in ('waiting','starting','calling')",{domain=domain,queue=tostring(number),target=caller},function() stored=true end) end
        if stored then pcall(Q.callback,db,domain,number,queue_callid,caller);session:execute('phrase','openweb_callback_saved');session:hangup('NORMAL_CLEARING');return true end
        return false
    end
    if callback_mode~='disabled' and callback_valid then
        -- Capture the advertised key while the invitation is playing. A plain
        -- phrase consumes that digit before callcenter installs its exit keys.
        -- Zero is not an immediate native timeout; one millisecond adds no
        -- separate listening window after the prompt. Guard its full duration
        -- with the same original queue deadline as the later native wait.
        local remaining=q.timeout-(os.time()-started)
        local digit=remaining>0 and timed_wait(remaining,function()
            return session:playAndGetDigits(1,1,1,1,'D','phrase:openweb_callback_intro','','^2$','',1)
        end) or ''
        if digit=='2' and request_callback() then return end
    end
    local function due_offer()
        if offered or not callback_valid or (callback_mode~='automatic' and callback_mode~='offer')
          or os.time()-started<(q.callback_after or 600) then return false end
        offered=true
        if callback_mode=='automatic' then return request_callback() end
        local _,remaining=P.queue_slice(q,started,os.time(),true)
        -- The input timeout starts after the spoken prompt. Guard the entire
        -- offer, so a long recording cannot extend the original deadline.
        local digit=remaining>0 and timed_wait(remaining,function()
            return session:playAndGetDigits(1,1,1,math.min(7000,remaining*1000),'D','phrase:openweb_callback_offer','silence_stream://100','[12]',2000)
        end) or ''
        return digit=='2' and request_callback() or false
    end
    repeat
        if q.callback_order=='original_position' then
            while session:ready() and os.time()-started<q.timeout and Q.callback_first(db,domain,number,joined) do session:execute('playback','silence_stream://500') end
            if not session:ready() or os.time()-started>=q.timeout then break end
        end
        -- The introduction may itself cross the callback deadline. Do not
        -- start another full native wait before offering an already-due job.
        if due_offer() then return end
        if not session:ready() then break end
        session:setVariable('cc_exit_keys',callback_mode~='disabled' and callback_valid and '2D' or 'D')
        session:setVariable('cc_exit_key','');session:setVariable('cc_agent_bridged','false')
        session:setVariable('cc_base_score',tostring(os.time()-started))
        local slice=P.queue_slice(q,started,os.time(),offered)
        if slice<=0 then break end
        timed_wait(slice,function()session:execute('callcenter',number..'@'..realm)end)
        if not session:ready() or session:getVariable('cc_agent_bridged')=='true' then break end
        if callback_mode~='disabled' and callback_valid and session:getVariable('cc_exit_key')=='2' then if request_callback() then return end end
        if due_offer() then return end
        if callback_mode=='disabled' or callback_mode=='request' then break end
    until os.time()-started>=q.timeout
    pcall(queue_cleanup)
    if session:ready() then
        if session:getVariable('cc_agent_bridged')=='true' then session:hangup('NORMAL_CLEARING') else route(q.destination,number) end
    end
end
run_ivr=function(number)
    local ivr=P.find(config.receptionists,number)
    if not ivr then session:hangup('UNALLOCATED_NUMBER');return end
    local special=P.object_destination(config,ivr,clock);if special then route(special,number);return end
    session:answer();session:setVariable('ivr_menu_uuid',ivr.uuid)
    local digit=session:playAndGetDigits(1,1,1,ivr.timeout*1000,'',ivr.prompt~='' and ivr.prompt or 'silence_stream://100','silence_stream://100','[0-9*#]',2000)
    for _,o in ipairs(ivr.options) do if o.digit==digit then route(o.destination,number);return end end
    route(ivr.timeout_destination,number)
end
local function run()
    if authenticated_user and mode~='record_user' and mode~='incoming' and mode~='mobile' then record(config.users[tostring(caller)]) end
    if mode=='user' then run_user(key)
    elseif mode=='group' then run_group(key)
    elseif mode=='queue' then run_queue(key)
    elseif mode=='ivr' then run_ivr(key)
    elseif mode=='outbound' then
        if authenticated_user then run_outbound(session:getVariable('destination_number') or '') else session:hangup('CALL_REJECTED') end
    elseif mode=='mobile' then
        local u=config.users[tostring(key)];local source=session:getVariable('openweb_mobile_source');local other=session:getVariable('other_loopback_leg_uuid')
        local timeout=tonumber(session:getVariable('openweb_mobile_timeout'))
        local function uuid(v)return type(v)=='string' and #v==36 and v:match('^[a-f0-9%-]+$')end
        if not u or not uuid(source) or not uuid(other) or session:getVariable('loopback_leg')~='B'
          or not timeout or timeout<1 or timeout>600 or timeout%1~=0
          or api:execute('uuid_getvar',other..' domain_uuid'):gsub('%s+$','')~=domain
          or api:execute('uuid_exists',source):gsub('%s+$','')~='true'
          or api:execute('uuid_getvar',source..' domain_uuid'):gsub('%s+$','')~=domain
          or not mobile_contact.available(db,api,P,domain,config,u,P.profile(config,key,clock)) then session:hangup('CALL_REJECTED');return end
        session:setVariable('openweb_mobile_deadline',tostring(os.time()+timeout))
        session:setVariable('presence_id',u.auth_id..'@'..realm)
        session:setVariable('ignore_early_media','true')
        run_outbound(u.mobile,tostring(u.number))
    elseif mode=='record_user' then local u=config.users[tostring(key)];if u then record(u) end
    elseif mode=='parking' then
        if not config.parking_enabled or not tostring(key):match('^%d+$') or tonumber(key)<1 or tonumber(key)>20 or not (authenticated_user or session:getVariable('openweb_park_authorized')=='true') then session:hangup('CALL_REJECTED');return end
        session:setVariable('openweb_park_authorized','false');session:answer();session:execute('valet_park',realm..' '..key)
    elseif mode=='group_timeout' then route(P.find(config.ring_groups,key).destination,key)
    elseif mode=='queue_timeout' then route(P.find(config.queues,key).destination,key)
    elseif mode=='incoming' then
        local rule
        for _,r in ipairs(config.inbound_rules) do if r.rule_id==key then rule=r;break end end
        if not rule or not rule.enabled then session:hangup('CALL_REJECTED');return end
        local trunk=config.trunks[tostring(rule.trunk_id)]
        local ip=session:getVariable('sip_network_ip') or session:getVariable('network_addr') or ''
        if not P.incoming(config,rule,trunk,function(variable) return session:getVariable(variable) end,ip) then session:hangup('CALL_REJECTED');return end
        local enabled=false
        db:query('select enabled from v_gateways where domain_uuid=:domain and gateway_uuid=:id',{domain=domain,id=trunk.gateway_uuid},function(row) enabled=row.enabled=='true' or row.enabled=='t' end)
        if not enabled then session:hangup('CALL_REJECTED');return end
        if P.blocked(config,caller) then session:hangup('CALL_REJECTED');return end
        session:setVariable('openweb_provider_origin','true')
        session:setVariable('openweb_call_internal','false')
        session:setVariable('call_direction','inbound');internal=false
        session:setVariable('provider_uuid',trunk.gateway_uuid)
        local destination=rule.office
        local open,_,holiday=P.office(config,rule.office_department or destination.number,clock)
        if rule.hours.type~='OfficeHours' then local d,t=clock(config.timezone);open=P.in_hours(rule.hours,d,t) end
        if holiday and rule.use_holiday then destination=rule.holiday elseif not open and rule.use_outside then destination=rule.outside end
        route(destination)
    elseif mode=='script' then
        local s=P.find(config.scripts,key)
        if not s or s.kind~='pin_menu' then session:hangup('SERVICE_UNAVAILABLE');return end
        session:answer()
        for _=1,s.attempts do
            local pin=session:playAndGetDigits(0,12,1,s.timeout*1000,'#','phrase:voicemail_enter_pass','silence_stream://100','[0-9]+',s.interdigit_timeout*1000)
            if s.pin_map[pin] then route({type='Extension',number=s.pin_map[pin]},key);return end
            if not session:ready() then return end
        end
        session:hangup('CALL_REJECTED')
    elseif mode=='voicemail_login' then
        if internal then voicemail(caller,true) else session:hangup('CALL_REJECTED') end
    elseif mode=='park' then session:execute('valet_park',realm..' '..key:sub(3))
    else session:hangup('UNALLOCATED_NUMBER') end
end
local ok=pcall(run)
if queue_cleanup then pcall(queue_cleanup) end
db:release()
if not ok then freeswitch.consoleLog('ERR','[OpenWeb PBX] Call handling failed for domain '..domain..'\n');if session:ready() then session:hangup('NORMAL_TEMPORARY_FAILURE') end end
