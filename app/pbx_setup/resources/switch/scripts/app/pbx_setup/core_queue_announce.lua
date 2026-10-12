-- Announcements stop on answer, transfer or hangup; never broadcast into an agent call.
require 'resources.functions.config'
local Database=require 'resources.functions.database'
local json=require 'resources.functions.lunajson'
local P=loadfile(scripts_dir..'/app/pbx_setup/policy.lua')()
local api=freeswitch.API();local db=Database.new('system')
local domain,number,id=argv[1],argv[2],argv[3]
if not domain or #domain~=36 or not domain:match('^[a-f0-9%-]+$') or not id or #id~=36 or not id:match('^[a-f0-9%-]+$') or not number or not number:match('^%d%d%d*$') or #number>10 then db:release();return end
local config
db:query('select config from v_pbx_restore where domain_uuid=:d',{d=domain},function(r)config=json.decode(r.config)end)
local q=config and P.find(config.queues,number)
if not q or not (q.announce_position or q.announce_wait or (q.announce_sound and q.announce_sound~='')) then db:release();return end
local started=os.time();local next_at=started+math.max(15,tonumber(q.announce_interval) or 30)
local function active()
    return api:execute('uuid_exists',id):gsub('%s+$','')=='true' and api:execute('uuid_getvar',id..' domain_uuid'):gsub('%s+$','')==domain
      and api:execute('uuid_getvar',id..' cc_agent_bridged'):gsub('%s+$','')~='true'
end
local ok=pcall(function()
    while os.time()-started<math.min(86400,tonumber(q.timeout) or 600) and active() do
        if os.time()>=next_at then
            local position=0;local found=false
            local rows={}
            db:query([[select t.call_uuid,t.state from v_pbx_queue_tickets t where t.domain_uuid=:d and t.queue_number=:q
              and (t.state='waiting' or (:ordering='original_position' and t.state='callback' and exists(select 1 from v_pbx_jobs j where j.job_uuid=t.job_uuid
                and j.state in ('waiting','starting') and j.due_at<=now() and j.expires_at>now()))) order by joined_at,ticket_id limit 1000]],{d=domain,q=number,ordering=q.callback_order or 'live_first'},function(r)rows[#rows+1]=r end)
            for _,r in ipairs(rows) do
                if not found and (r.state=='callback' or (api:execute('uuid_exists',r.call_uuid):gsub('%s+$','')=='true' and api:execute('uuid_getvar',r.call_uuid..' cc_agent_bridged'):gsub('%s+$','')~='true')) then position=position+1;if r.call_uuid==id then found=true end end
            end
            if not found then break end
            if q.announce_position and position>0 and active() then api:execute('uuid_broadcast',id..' phrase::openweb_queue_position:'..position..' aleg') end
            if q.announce_wait and active() then
                local minutes
                db:query([[select count(*) as count,avg(wait_seconds) as wait from (select wait_seconds from v_pbx_queue_tickets
                  where domain_uuid=:d and queue_number=:q and state='finished' order by ended_at desc limit 30) recent]],{d=domain,q=number},function(r)if tonumber(r.count)>=3 then minutes=math.max(1,math.ceil((tonumber(r.wait) or 0)/60))end end)
                if minutes then api:execute('uuid_broadcast',id..' phrase::openweb_queue_wait:'..minutes..' aleg') end
            end
            if q.announce_sound and q.announce_sound~='' and q.announce_sound:match('^[%w_/:.%-]+$') and active() then api:execute('uuid_broadcast',id..' playback::'..q.announce_sound..' aleg') end
            next_at=os.time()+math.max(15,tonumber(q.announce_interval) or 30)
        end
        freeswitch.msleep(500)
    end
end)
db:release()
if not ok then freeswitch.consoleLog('NOTICE','[OpenWeb PBX] Queue announcement stopped.\n') end
