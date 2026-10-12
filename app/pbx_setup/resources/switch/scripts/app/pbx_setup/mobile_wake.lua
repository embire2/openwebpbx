-- Loaded by the authenticated tenant call runtime. No wake-up occurs before routing/profile checks.
local registered=loadfile(scripts_dir..'/app/pbx_setup/registered.lua')()
return function(db,api,P,session,domain,users)
    local call=session:getVariable('uuid');local any=false;local offline=false
    if not call or #call~=36 or not call:match('^[a-f0-9%-]+$') then return end
    local targets={}
    for _,u in ipairs(users) do
        if u.enabled and type(u.extension_uuid)=='string' and #u.extension_uuid==36 and u.extension_uuid:match('^[a-f0-9%-]+$') then
            targets[#targets+1]=u.extension_uuid
        end
    end
    session:setVariable('openweb_mobile_wake_targets',table.concat(targets,','))
    for _,u in ipairs(users) do if u.enabled and u.extension_uuid then
        local count=0
        db:query([[insert into v_pbx_mobile_push_calls(request_uuid,call_uuid,device_uuid,domain_uuid,extension_uuid,expires_at)
          select gen_random_uuid(),:call,m.device_uuid,m.domain_uuid,m.extension_uuid,now()+interval '60 seconds'
          from v_pbx_mobile_devices m join v_pbx_mobile_push_config c on c.singleton and c.enabled
          where m.domain_uuid=:domain and m.extension_uuid=:extension and m.push_token is not null
          and m.push_project=c.project_id and m.revoked_at is null and m.expires_at>now()
          on conflict(call_uuid,device_uuid) do nothing returning request_uuid]],
          {call=call,domain=domain,extension=u.extension_uuid},function() count=count+1 end)
        if count>0 then
            any=true
            -- Mobile credentials are expanded by the native directory under the user's normal auth ID.
            if not registered(db,api,P,domain,u,session:getVariable('domain_name')) then offline=true end
        end
    end end
    if any and offline then
        session:execute('ring_ready')
        local until_time=os.time()+6
        repeat
            local phoneReady=false
            for _,u in ipairs(users) do if registered(db,api,P,domain,u,session:getVariable('domain_name')) then phoneReady=true;break end end
            if phoneReady or not session:ready() then break end
            session:sleep(200)
        until os.time()>=until_time
    end
end
