-- Runs when an owned queue agent answers; preserve the caller's measured wait.
require 'resources.functions.config'
local domain,queue,id=argv[1],argv[2],argv[3]
if not domain or #domain~=36 or not domain:match('^[a-f0-9%-]+$') or not id or #id~=36 or not id:match('^[a-f0-9%-]+$') or not queue or not queue:match('^%d%d%d*$') or #queue>10 then return end
local api=freeswitch.API()
if api:execute('uuid_getvar',id..' domain_uuid'):gsub('%s+$','')~=domain then return end
local Database=require 'resources.functions.database';local db=Database.new('system')
db:query([[update v_pbx_queue_tickets set state='answered',wait_seconds=greatest(0,extract(epoch from now()-joined_at)::int)
  where domain_uuid=:d and queue_number=:q and call_uuid=:id and state='waiting']],{d=domain,q=queue,id=id})
local agent=argv[4]
if agent and agent:match('^%d%d%d*$') and #agent<=10 then
    local valid=false
    db:query([[select 1 as ok from v_pbx_restore r where domain_uuid=:d and r.config->'users'->:n->>'enabled'='true' and exists(select 1 from jsonb_array_elements(r.config->'queues') q where q->>'number'=:q and exists(select 1 from jsonb_array_elements(q->'members') m where m->>'number'=:n))]],{d=domain,n=agent,q=queue},function()valid=true end)
    if valid then api:execute('uuid_setvar',id..' openweb_scope_target '..agent) end
end
db:release();api:execute('uuid_break',id..' all')
