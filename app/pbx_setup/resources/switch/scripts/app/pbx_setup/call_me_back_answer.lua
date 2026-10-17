-- Destination answer is never allowed to bypass durable accounting or hard limits.
local db
local ok=pcall(function()
 local function uuid(v)return type(v)=='string' and #v==36 and v:match('^[a-f0-9%-]+$')end
 local id=argv and argv[1]
 if not uuid(id) or not session or not session:ready() then error('Invalid answer ownership') end
 local b=session:getVariable('uuid');local parent=session:getVariable('openweb_cmb_parent_uuid')
 local seconds=tonumber(session:getVariable('openweb_cmb_limit_seconds'))
 if not uuid(b) or not uuid(parent) or not seconds or seconds%1~=0 or seconds<1 or seconds>600 then error('Invalid inherited call limit') end
 local api=freeswitch.API();local group='openweb-cmb-active-'..id
 -- These server-generated inherited limits apply before ANY database operation.
 -- A blocked database cannot extend an answered call beyond its remaining quota.
 -- The shorter pre-bridge safety timer remains until accounting also succeeds.
 for _,owned in ipairs({parent,b}) do
  local task=api:execute('sched_api','+'..seconds..' '..group..' uuid_kill '..owned..' ALLOTTED_TIMEOUT')
  if not task or not task:match('^%+OK') then error('Call limit unavailable') end
 end
 require 'resources.functions.config'
 local Database=require 'resources.functions.database';db=Database.new('system');local row
 db:query([[update v_pbx_cmb_requests set state='connected',connected_at=clock_timestamp(),lease_until=now()+interval '12 minutes',updated_at=now()
  where request_uuid=:id and bridge_uuid=:bridge and call_uuid=:parent and state='dialling' and reserved_seconds=:seconds
  and exists(select 1 from v_pbx_cmb_services s join v_domains d using(domain_uuid) where s.service_uuid=v_pbx_cmb_requests.service_uuid and s.domain_uuid=v_pbx_cmb_requests.domain_uuid and s.enabled and d.domain_enabled='true')
  and exists(select 1 from v_pbx_cmb_accounts a where a.account_uuid=v_pbx_cmb_requests.account_uuid and a.domain_uuid=v_pbx_cmb_requests.domain_uuid and a.enabled)
  and not exists(select 1 from v_pbx_services p join v_pbx_tenants t using(tenant_uuid) where p.domain_uuid=v_pbx_cmb_requests.domain_uuid and not t.enabled)
  returning call_uuid,reserved_seconds]],{id=id,bridge=b,parent=parent,seconds=seconds},function(r)row=r end)
 if not row or row.call_uuid~=parent or tonumber(row.reserved_seconds)~=seconds or not session:ready() then error('Answer accounting refused') end
 api:execute('sched_del','openweb-cmb-'..id)
end)
if not ok then
 if session and session:ready() then session:hangup('NORMAL_TEMPORARY_FAILURE') end
 freeswitch.consoleLog('ERR','[OpenWeb PBX] Callback destination refused: accounting or call limit unavailable.\n')
end
if db then db:release() end
