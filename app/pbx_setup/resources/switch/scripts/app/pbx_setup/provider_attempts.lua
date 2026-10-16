-- Provider diagnostics are observations only. A database failure cannot create a second call.
local M={}
local function uuid(v)return type(v)=='string' and #v==36 and v:match('^[a-f0-9%-]+$')end
local function write(db,sql,p)
    local ok=pcall(function()db:query(sql,p)end)
    if not ok then freeswitch.consoleLog('WARNING','[OpenWeb PBX] Provider diagnostic could not be saved.\n') end
    return ok
end
function M.begin(db,api,call,domain,trunk,owner,number,available)
    local id=api:execute('create_uuid',''):gsub('%s+$','');local leg=api:execute('create_uuid',''):gsub('%s+$','')
    local callid=call:getVariable('uuid');local seq=(tonumber(call:getVariable('openweb_provider_attempt')) or 0)+1
    call:setVariable('openweb_provider_attempt',tostring(seq))
    if not uuid(id) or not uuid(leg) or not uuid(callid) or not uuid(domain) or not trunk or not uuid(trunk.gateway_uuid) or seq>100 then return nil end
    local p={id=id,leg=leg,call=callid,d=domain,n=seq,trunk=tostring(trunk.number),provider=trunk.gateway_uuid,
        owner=tostring(owner),number=number,state=available and 'calling' or 'skipped',cause=available and '' or 'PROVIDER_UNAVAILABLE',retry=available and 'false' or 'true'}
    local ok=write(db,[[insert into v_pbx_provider_attempts(attempt_uuid,domain_uuid,call_uuid,attempt_no,leg_uuid,trunk_id,provider_uuid,owner_number,dialled_number,state,cause,will_retry,config_hash)
      select :id,:d,:call,:n,:leg,:trunk,:provider,:owner,:number,:state,:cause,:retry,
      md5(r.config::text||coalesce((select string_agg(md5(row(g.gateway_uuid,g.enabled,g.username,g.auth_username,g.password,g.realm,g.proxy,g.register_proxy,g.outbound_proxy,g.register,g.register_transport,g.from_user,g.from_domain,g.codec_prefs)::text),'' order by g.gateway_uuid) from v_gateways g where g.domain_uuid=:d),''))
      from v_pbx_restore r where r.domain_uuid=:d]],p)
    return ok and p or nil
end
function M.contact(p,contact)
    if p and contact and contact:sub(1,1)=='[' then return contact:gsub('^%[','[origination_uuid='..p.leg..',',1) end
    return contact
end
function M.finish(db,p,cause,protocol,status,answered,ready,retry)
    if not p then return end
    cause=type(cause)=='string' and cause:match('^[A-Z_0-9]+$') and cause:sub(1,80) or 'UNKNOWN'
    local code=tonumber((type(protocol)=='string' and protocol:match('^sip:(%d%d%d)$')) or status)
    if not code or code<100 or code>699 then code=0 end
    local state=answered and 'answered' or (not ready and 'cancelled' or 'failed')
    write(db,[[update v_pbx_provider_attempts set state=:state,cause=:cause,sip_status=:code,will_retry=:retry,finished_at=now()
      where domain_uuid=:d and attempt_uuid=:id and state='calling']],{state=state,cause=cause,code=code,retry=retry and 'true' or 'false',d=p.d,id=p.id})
end
return M
