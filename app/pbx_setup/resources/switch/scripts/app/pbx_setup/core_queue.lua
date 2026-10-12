-- Durable queue visits and callback ordering; all engine commands use owned UUIDs.
local Q={}
function Q.join(db,domain,number,id,capacity)
    local joined
    assert(db:query('begin')~=false,'Queue tracking unavailable')
    local ok,err=pcall(function()
        assert(db:query('select domain_uuid from v_pbx_restore where domain_uuid=:d for update',{d=domain})~=false,'Queue tracking unavailable')
        assert(db:query([[insert into v_pbx_queue_tickets(domain_uuid,queue_number,call_uuid) select :d,:q,:id
          where :capacity=0 or (select count(*) from v_pbx_queue_tickets where domain_uuid=:d and queue_number=:q and state='waiting')<:capacity
          on conflict(domain_uuid,queue_number,call_uuid) do update set state='waiting'
          returning extract(epoch from joined_at) as joined]],{d=domain,q=tostring(number),id=id,capacity=capacity or 0},function(r)joined=tonumber(r.joined)end)~=false,'Queue tracking unavailable')
    end)
    db:query(ok and 'commit' or 'rollback');if not ok then error(err) end
    return joined
end
function Q.finish(db,domain,number,id,session,joined)
    local answered=session:getVariable('cc_agent_bridged')=='true'
    local answer_epoch=tonumber(session:getVariable('cc_queue_answered_epoch'))
    local wait=math.max(0,(answer_epoch or os.time())-joined)
    db:query([[update v_pbx_queue_tickets set state=case when state='answered' or cast(:answered as boolean) then 'finished' else 'abandoned' end,
      ended_at=now(),wait_seconds=case when state='answered' then wait_seconds else :wait end
      where domain_uuid=:d and queue_number=:q and call_uuid=:id and state in ('waiting','answered')]],{answered=tostring(answered),wait=wait,d=domain,q=tostring(number),id=id})
end
function Q.callback(db,domain,number,id,target)
    db:query([[update v_pbx_queue_tickets t set state='callback',job_uuid=j.job_uuid,ended_at=now(),wait_seconds=greatest(0,extract(epoch from now()-t.joined_at)::int)
      from v_pbx_jobs j where t.domain_uuid=:d and t.queue_number=:q and t.call_uuid=:id and j.domain_uuid=t.domain_uuid
      and j.queue_number=t.queue_number and j.kind='callback' and j.target_number=:target and j.state in ('waiting','starting','calling')]],{d=domain,q=tostring(number),id=id,target=target})
    db:query([[update v_pbx_jobs j set created_at=least(j.created_at,t.joined_at) from v_pbx_queue_tickets t
      where t.domain_uuid=:d and t.queue_number=:q and t.call_uuid=:id and t.job_uuid=j.job_uuid]],{d=domain,q=tostring(number),id=id})
end
function Q.callback_first(db,domain,number,joined)
    local before=false
    db:query([[select 1 as ok from v_pbx_jobs where domain_uuid=:d and queue_number=:q and kind='callback'
      and state in ('waiting','starting') and due_at<=now() and expires_at>now() and created_at<to_timestamp(:joined) limit 1]],{d=domain,q=tostring(number),joined=joined},function()before=true end)
    return before
end
function Q.live_first(db,api,domain,number,job)
    local before=false;local ids={}
    db:query([[select call_uuid from v_pbx_queue_tickets where domain_uuid=:d and queue_number=:q and state='waiting'
      and joined_at<(select created_at from v_pbx_jobs where job_uuid=:job) order by joined_at limit 200]],{d=domain,q=tostring(number),job=job},function(r)ids[#ids+1]=r.call_uuid end)
    for _,id in ipairs(ids) do
        if api:execute('uuid_exists',id):gsub('%s+$','')=='true' then before=true
        else db:query([[update v_pbx_queue_tickets set state='abandoned',ended_at=now(),wait_seconds=greatest(0,extract(epoch from now()-joined_at)::int)
          where domain_uuid=:d and queue_number=:q and call_uuid=:id and state='waiting']],{d=domain,q=tostring(number),id=id}) end
    end
    return before
end
return Q
