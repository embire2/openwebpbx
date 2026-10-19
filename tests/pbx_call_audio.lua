local M=assert(loadfile('app/pbx_setup/resources/switch/scripts/app/pbx_setup/call_audio.lua'))()
local vars={uuid='00000000-0000-4000-a000-000000000001',export_vars='existing',rtp_secure_media='mandatory'}
local exported,events={},{}
local session={getVariable=function(_,n)return vars[n]end,setVariable=function(_,n,v)vars[n]=v end,
    execute=function(_,app,data)assert(app=='export');exported[#exported+1]=data end}
freeswitch={Event=function(kind,name)
    assert(kind=='CUSTOM' and name=='openweb::call_trace')
    local e={};function e:addHeader(n,v)self[n]=v end;function e:fire()events[#events+1]=self end;return e
end}
M.apply(session,'owned-domain')
assert(table.concat(exported,',')=='bypass_media=false,bypass_media_after_bridge=false,proxy_media=false')
assert(vars.disable_rtp_auto_adjust=='false' and vars.openweb_pbx_delivers_audio=='true')
assert(vars.instant_ringback=='false' and vars.ringback:find('400,450',1,true))
assert(vars.export_vars=='existing' and vars.rtp_secure_media=='mandatory')
assert(events[1]['OpenWeb-Stage']=='media_policy' and events[1].UniqueID==nil)
vars.ringback='existing-custom-ringback';M.apply(session,'owned-domain');assert(vars.ringback=='existing-custom-ringback')
freeswitch.Event=function()error('Observer unavailable')end
M.trace(session,'owned-domain','provider_result',{Cause='NO_ANSWER'}) -- tracing cannot fail a call
print('PASS: anchored media, inherited leg policy, existing encryption/export/ringback and observer failure controls')
