-- Pure call decisions, shared by the call runtime and deterministic restore checks.
local P = {}
function P.contact(value)
    if type(value)~='string' then return nil end
    value=value:gsub('%s+$','')
    -- sofia_contact returns error/user_not_registered, not an ESL -ERR frame,
    -- when the phone has no registration. Only a native SIP contact is dialable.
    if value:match('^sofia/[^/]+/.+') then return value end
end
function P.agent_available(list, id, now)
    if type(list)~='string' or #list>65536 then return false end
    local header,values=list:match('([^\r\n]+)\r?\n([^\r\n]+)')
    if not header or not values then return false end
    local keys,row={},{}
    for value in (header..'|'):gmatch('(.-)|') do keys[#keys+1]=value end
    local index=1
    for value in (values..'|'):gmatch('(.-)|') do if keys[index] then row[keys[index]]=value end;index=index+1 end
    return row.name==id and row.state=='Waiting'
      and (row.status=='Available' or row.status=='Available (On Demand)')
      and (tonumber(row.ready_time) or 0)<=now
      and (tonumber(row.last_bridge_end) or 0)+(tonumber(row.wrap_up_time) or 0)<=now
      and (tonumber(row.external_calls_count) or 0)==0
end
function P.callback_open(config,queue,clock)
    if P.object_destination(config,queue,clock) then return false end
    local h=queue.hours and queue.hours.hours
    if h and h.type~='OfficeHours' and h.type~='OutOfOfficeHours' then
        local d,t=clock((P.department(config,queue.number) or {}).timezone or config.timezone)
        return P.in_hours(h,d,t)
    end
    return P.office(config,queue.number,clock)
end
function P.find(rows, number)
    for _, row in ipairs(rows or {}) do if tostring(row.number)==tostring(number) then return row end end
end
function P.department(config, number)
    local fallback
    for _, department in ipairs(config.departments or {}) do
        for _, member in ipairs(department.members or {}) do
            if tostring(member.number)==tostring(number) then
                if member.primary then return department end
                fallback=fallback or department
            end
        end
    end
    return fallback
end
function P.in_hours(hours, day, time)
    if not hours or hours.type=='AllHours' then return true end
    for _, period in ipairs(hours.periods or {}) do
        if tonumber(period.day)==tonumber(day) and time>=period.start and time<period['end'] then return true end
    end
    return false
end
function P.office(config, number, clock)
    local department=P.department(config,number)
    if not department then return true,false,false end
    local day,time,date=clock(department.timezone or config.timezone)
    local holiday=false
    for _, h in ipairs(department.holidays or {}) do if h.date==date then holiday=true end end
    local break_now=#(department.breaks.periods or {})>0 and P.in_hours(department.breaks,day,time)
    return P.in_hours(department.hours,day,time) and not break_now and not holiday,break_now,holiday
end
function P.profile(config, number, clock)
    local user=config.users[tostring(number)]
    local status=user.profile
    if tonumber(user.auto_status or '0')%2==1 then
        local open,break_now=P.office(config,number,clock)
        if not open then status=break_now and 'Away' or 'Out of office' end
    end
    return user.profiles[status] or user.profiles[user.profile]
end
function P.forward(profile,reason,internal,open)
    if next(profile.away or {}) then
        local rule=profile.away[internal and 'Internal' or 'External']
        if not rule then return {type='None'} end
        return not open and not rule.outside_inactive and rule.outside or rule.all
    end
    local rule=profile.available[reason]
    if not rule then return {type='None'} end
    return internal and not rule.internal_inactive and rule.internal or rule.all
end
function P.route_string(value)
    local kind,number,external=(value or ''):match('^([A-Za-z]+)%.([^.]*)%.(.*)$')
    if not kind or kind=='ProceedWithNoExceptions' then return nil end
    return {type=kind,number=number,external=external}
end
function P.object_destination(config,object,clock)
    local schedule=object.hours
    if not schedule then return nil end
    local open,break_now,holiday=P.office(config,object.number,clock)
    if schedule.hours.type~='OfficeHours' and schedule.hours.type~='OutOfOfficeHours' then
        local d,t=clock((P.department(config,object.number) or {}).timezone or config.timezone)
        open=P.in_hours(schedule.hours,d,t)
    elseif schedule.hours.type=='OutOfOfficeHours' then open=not open end
    if holiday then return P.route_string(schedule.holiday) end
    if break_now then return P.route_string(schedule['break']) end
    if not open then return P.route_string(schedule.outside) end
end
local function member_allowed(config,rule,caller)
    if #(rule.ranges or {})==0 and #(rule.departments or {})==0 then return true end
    for _, range in ipairs(rule.ranges or {}) do
        local c,f,t=tonumber(caller),tonumber(range.from),tonumber(range.to)
        if c and f and t and c>=f and c<=t then return true end
    end
    for _, name in ipairs(rule.departments or {}) do
        for _, department in ipairs(config.departments or {}) do
            if department.name==name then
                for _, member in ipairs(department.members or {}) do if tostring(member.number)==tostring(caller) then return true end end
            end
        end
    end
    return false
end
function P.outbound(config,number,caller)
    for _, rule in ipairs(config.outbound_rules or {}) do
        local prefix_ok=rule.prefix==''
        for prefix in (rule.prefix..','):gmatch('(.-),') do
            prefix=prefix:match('^%s*(.-)%s*$')
            if prefix~='' and number:sub(1,#prefix)==prefix then prefix_ok=true end
        end
        local length_ok=rule.lengths==''
        for part in (rule.lengths..','):gmatch('(.-),') do
            local f,t=part:match('^%s*(%d+)%s*%-%s*(%d+)%s*$')
            if f and #number>=tonumber(f) and #number<=tonumber(t) then length_ok=true end
            if tonumber(part)==#number then length_ok=true end
        end
        if prefix_ok and length_ok and member_allowed(config,rule,caller) then return rule end
    end
end
local function phone(value)
    return type(value)=='string' and #value>0 and #value<=64 and value:match('^%+?[%d*#]+$')~=nil
end
local function caller_number(value)
    return type(value)=='string' and #value>0 and #value<=33 and value:match('^%+?%d+$')~=nil
end
function P.rewrite(number,route)
    local strip=tonumber(route.strip or 0)
    local prepend=route.prepend or ''
    if not phone(number) or not strip or strip<0 or strip%1~=0 or strip>#number
      or type(prepend)~='string' or (prepend~='' and not prepend:match('^%+?%d*$')) then return nil end
    local result=prepend..number:sub(strip+1)
    if phone(result) then return result end
end
function P.caller_id(trunk,route,user,original)
    -- A separate identity is selected for every attempt, so a failed provider's
    -- number cannot leak into its backup provider or a later internal call.
    for _,value in ipairs({route.caller_id or '',(user or {}).outbound_caller_id or '',trunk.caller_id or '',trunk.main_number or '',original or ''}) do
        if caller_number(value) then return value end
    end
    return 'anonymous'
end
function P.gateway_available(native,status)
    if not native or not (native.enabled==true or native.enabled=='true' or native.enabled=='t') or type(status)~='string' then return false end
    local state=status:match('[\r\n]State%s+([A-Z_]+)') or status:match('^State%s+([A-Z_]+)')
    local up=status:match('[\r\n]Status%s+([A-Z]+)') or status:match('^Status%s+([A-Z]+)')
    if up~='UP' then return false end
    local registration=native.register==true or native.register=='true' or native.register=='t'
    return registration and state=='REGED' or not registration and (state=='NOREG' or state=='REGED')
end
local retry_sip={}
-- Published 3CX failover responses. Busy, no response, cancellation and an
-- answered call stop; only another provider error may start the next route.
for _,code in ipairs({400,401,402,403,404,405,406,407,408,409,410,411,413,414,415,416,420,421,423,433,480,481,482,483,484,485,487,500,501,502,503,504,505,513,603,604,606}) do retry_sip[code]=true end
local retry_cause={INVALID_GATEWAY=true,GATEWAY_DOWN=true,DESTINATION_OUT_OF_ORDER=true,NETWORK_OUT_OF_ORDER=true,
    NORMAL_TEMPORARY_FAILURE=true,SWITCH_CONGESTION=true,RESOURCE_UNAVAILABLE=true,SERVICE_UNAVAILABLE=true,
    UNALLOCATED_NUMBER=true,NO_ROUTE_DESTINATION=true,INCOMPATIBLE_DESTINATION=true,RECOVERY_ON_TIMER_EXPIRE=true}
function P.failover(cause,protocol,answered,received_status)
    if cause=='SUCCESS' or cause=='NO_ANSWER'
      or cause=='ALLOTTED_TIMEOUT' or answered==true or answered=='true' or (tonumber(answered) or 0)>0 then return false end
    local code=type(protocol)=='string' and tonumber(protocol:match('^sip:(%d+)$')) or nil
    if code then
        -- Sofia also uses 408/487 for local timeout/cancel. The received failure
        -- status is populated only when a real SIP response exists. Explicit
        -- provider 480/487 must not be confused with the native cause names
        -- NO_USER_RESPONSE/ORIGINATOR_CANCEL that Sofia assigns to them.
        if (code==408 or code==487) and tonumber(received_status)~=code then return false end
        return retry_sip[code]==true
    end
    if cause=='ORIGINATOR_CANCEL' or cause=='NO_USER_RESPONSE' then return false end
    return retry_cause[cause]==true
end
local function uuid(value) return type(value)=='string' and #value==36 and value:match('^[a-fA-F0-9%-]+$')~=nil end
function P.track_answer(contact,call_id)
    if type(contact)~='string' or contact:sub(1,1)~='[' or not uuid(call_id) then return nil end
    -- The callback runs on the provider B-leg's actual answer, not its 180/183
    -- progress. It updates only the UUID of this caller's local channel.
    local tracked=contact:gsub('^%[',"[api_on_answer='uuid_setvar "..call_id.." openweb_provider_answered true',",1)
    return tracked
end
local function endpoint(value)
    if type(value)~='string' or #value==0 or #value>253 then return nil end
    value=value:gsub('^sips?:','')
    if value:sub(-1)==':' then return nil end
    local host,port=value:match('^(%[[A-Fa-f0-9:]+%]):?(%d*)$')
    if not host then host,port=value:match('^([A-Za-z0-9_.%-]+):?(%d*)$') end
    if not host or (port~='' and (tonumber(port)<1 or tonumber(port)>65535)) then return nil end
    return host..(port~='' and ':'..port or '')
end
local function sip_user(value)
    if type(value)~='string' or #value==0 or #value>128 or not value:match('^[A-Za-z0-9_.+@*!%-]+$') then return nil end
    return value:gsub('@','%%40')
end
function P.outbound_leg(trunk,route,number,user,original,domain,realm,native)
    local target=P.rewrite(number,route)
    if not target or not uuid(trunk.gateway_uuid) or not uuid(domain) or type(realm)~='string'
      or not realm:match('^[A-Za-z0-9_.%-]+$') then return nil end
    local cid=P.caller_id(trunk,route,user,original)
    local headers=trunk.headers or {}
    local cid_type=trunk.sip_cid_type or (headers.RemotePartyIDCallingPartyUserPart and 'rpid' or 'none')
    if cid_type~='rpid' and cid_type~='pid' and cid_type~='none' then return nil end
    local vars={'domain_uuid='..domain,'domain_name='..realm,'origination_caller_id_number='..cid,
        'origination_caller_id_name='..cid,'sip_cid_type='..cid_type,'sip_copy_custom_headers=false','outbound_redirect_fatal=true'}
    if #(trunk.codecs or {})>0 then
        local codecs={}
        for _,codec in ipairs(trunk.codecs) do
            if type(codec)~='string' or #codec>32 or not codec:match('^[A-Za-z0-9_-]+$') then return nil end
            codecs[#codecs+1]=codec
        end
        -- Originate's earlier pipe split strips quotes before parsing the
        -- comma-delimited leg variables. Use the native list separator so all
        -- codecs survive both stages and reach switch_core_media in order.
        vars[#vars+1]='absolute_codec_string=^^:'..table.concat(codecs,':')
    end
    -- Native gateway defaults handle authentication and fixed Contact settings.
    -- From's display and RPID use the selected outgoing identity. Never copy a
    -- provider-originated custom identity header onto a different provider.
    local host=(native or {}).from_domain or trunk.from_domain or ''
    if host=='' and (headers.FromHostPart=='$GWHostPort' or headers.FromUserPart=='$OutboundCallerId' or headers.FromUserPart=='$CallerNum') then
        host=trunk.host or '';if tonumber(trunk.port or 5060)~=5060 then host=host..':'..tostring(trunk.port) end
    end
    if host~='' then
        host=endpoint(host);if not host then return nil end
        vars[#vars+1]='sip_invite_domain='..host
        if headers.FromUserPart=='$OutboundCallerId' or headers.FromUserPart=='$CallerNum' then vars[#vars+1]='sip_invite_from_uri=sip:'..cid..'@'..host end
    end
    -- Sofia's gateway path always fixes Contact to register_contact before it
    -- reads sip_contact_user. A direct leg is therefore required for a dynamic
    -- provider Contact, while sip_use_gateway keeps authentication private in
    -- that already checked, tenant-owned native gateway.
    if headers.ContactUser=='$OutboundCallerId' and (trunk.contact_user or '')=='' then
        native=native or {}
        local proxy=endpoint(native.proxy)
        local profile=native.profile
        local transport=native.register_transport or 'udp'
        if not proxy or type(profile)~='string' or #profile>64 or not profile:match('^[A-Za-z0-9_.%-]+$')
          or (transport~='udp' and transport~='tcp' and transport~='tls') then return nil end
        vars[#vars+1]='sip_use_gateway='..trunk.gateway_uuid
        vars[#vars+1]='sip_gateway_name='..trunk.gateway_uuid
        vars[#vars+1]='sip_contact_user='..cid
        vars[#vars+1]='sip_transport='..transport
        vars[#vars+1]='sip_invite_contact_params=transport='..transport..';gw='..trunk.gateway_uuid
        local outgoing_proxy=native.outbound_proxy or ''
        if outgoing_proxy~='' then outgoing_proxy=endpoint(outgoing_proxy);if not outgoing_proxy then return nil end end
        vars[#vars+1]='sip_route_uri='..(outgoing_proxy~='' and 'sip:'..outgoing_proxy..';transport='..transport or '')
        -- Direct profile legs have no gateway From defaults: recreate those
        -- defaults from validated native fields, never from an incoming header.
        local from_user=cid
        if headers.FromUserPart=='$AuthID' then from_user=native.from_user or '';if from_user=='' then from_user=native.username end
        elseif (native.from_user or '')~='' and headers.FromUserPart~='$OutboundCallerId' and headers.FromUserPart~='$CallerNum' then from_user=native.from_user end
        from_user=sip_user(from_user);if not from_user then return nil end
        vars[#vars+1]='sip_invite_from_uri=sip:'..from_user..'@'..(host~='' and host or proxy)
        vars[#vars+1]='sip_invite_to_uri=sip:'..target..'@'..proxy
        return '['..table.concat(vars,',')..']sofia/'..profile..'/'..target..'@'..proxy..';transport='..transport,cid
    end
    return '['..table.concat(vars,',')..']sofia/gateway/'..trunk.gateway_uuid..'/'..target,cid
end
function P.incoming_number(trunk,get)
    local field=trunk.source_field or ''
    if field=='' then field='ToUserPart' end
    local variable=field=='ToUserPart' and 'sip_to_user' or field=='RequestLineURIUser' and 'sip_req_user' or nil
    if not variable then return nil end
    local number=get(variable)
    if caller_number(number) then return number:gsub('^%+','') end
end
function P.did_matches(pattern,number)
    if type(pattern)~='string' or type(number)~='string' or not caller_number(number) then return false end
    number=number:gsub('^%+','')
    if pattern:sub(1,1)=='*' then
        local suffix=pattern:sub(2):gsub('^%+','')
        return suffix:match('^%d+$')~=nil and #number>=#suffix and number:sub(-#suffix)==suffix
    end
    pattern=pattern:gsub('^%+','')
    return pattern:match('^%d+$')~=nil and pattern==number
end
function P.trunk_number(trunk,number)
    if P.did_matches(trunk.main_number,number) then return true end
    local dids=trunk.dids or {}
    if type(dids)=='string' then
        if #dids>65536 then return false end
        local parsed={};for entry in dids:gmatch('[^,;\r\n]+') do parsed[#parsed+1]=entry:match('^%s*(.-)%s*$') end;dids=parsed
    end
    if type(dids)~='table' or #dids>1000 then return false end
    for _,did in ipairs(dids) do
        if P.did_matches(did,number) then return true end
    end
    return false
end
function P.incoming(config,rule,trunk,get,ip)
    if not rule or not rule.enabled or not trunk then return false end
    local accepted=false
    for _,allowed in ipairs(trunk.allowed_ips or {}) do if allowed==ip then accepted=true end end
    if not accepted then return false end
    local binding=get('sip_gateway')
    if binding and binding~='' and binding~=trunk.gateway_uuid then return false end
    local number=P.incoming_number(trunk,get)
    if not number then return false end
    if rule.condition=='BasedOnDID' then return P.did_matches(rule.number,number) end
    if rule.condition~='ForwardAll' then return false end
    -- A public forward-all is limited to numbers declared on this provider.
    -- Gateway-bound ingress must still match its native UUID above; arbitrary
    -- To headers cannot assign an otherwise unbound call to this tenant.
    if not P.trunk_number(trunk,number) then return false end
    -- It cannot steal a configured DID, including another source trunk that
    -- shares the same provider IP but belongs to a different SIP account.
    for _,other in ipairs(config.inbound_rules or {}) do
        local other_trunk=(config.trunks or {})[tostring(other.trunk_id)]
        local shared=false
        for _,allowed in ipairs((other_trunk or {}).allowed_ips or {}) do if allowed==ip then shared=true end end
        if other.enabled and other.rule_id~=rule.rule_id and (tostring(other.trunk_id)==tostring(rule.trunk_id) or (shared and (not binding or binding==''))) then
            if other.condition=='BasedOnDID' and P.did_matches(other.number,number) then return false end
            if other.condition=='ForwardAll' and shared and P.trunk_number(other_trunk,number) then return false end
        end
    end
    return true
end
return P
