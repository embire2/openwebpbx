local M=assert(loadfile('app/pbx_setup/resources/switch/scripts/app/pbx_setup/call_audio.lua'))()
local vars={uuid='00000000-0000-4000-a000-000000000001',export_vars='existing',rtp_secure_media='mandatory'}
local exported,events={},{}
local session={getVariable=function(_,n)return vars[n]end,setVariable=function(_,n,v)vars[n]=v end,
    execute=function(_,app,data)assert(app=='export');exported[#exported+1]=data;local key,value=data:match('^([^=]+)=(.+)$');vars[key]=value end}
freeswitch={Event=function(kind,name)
    assert(kind=='CUSTOM' and name=='openweb::call_trace')
    local e={};function e:addHeader(n,v)self[n]=v end;function e:fire()events[#events+1]=self end;return e
end}
M.apply(session,'owned-domain')
assert(table.concat(exported,',')=='bypass_media=false,bypass_media_after_bridge=false,proxy_media=false,rtp_rewrite_timestamps=true')
assert(vars.disable_rtp_auto_adjust=='false' and vars.openweb_pbx_delivers_audio=='true')
assert(vars.rtp_rewrite_timestamps=='true')
local newBridgeLeg={};for _,entry in ipairs(exported)do local name,value=entry:match('^([^=]+)=(.+)$');newBridgeLeg[name]=value end
assert(newBridgeLeg.rtp_rewrite_timestamps=='true' and newBridgeLeg.bypass_media=='false')
vars.rtp_rewrite_timestamps='false';M.apply(session,'owned-domain');assert(vars.rtp_rewrite_timestamps=='true')
assert(vars.instant_ringback=='false' and vars.ringback:find('400,450',1,true))
assert(vars.export_vars=='existing' and vars.rtp_secure_media=='mandatory')
assert(events[1]['OpenWeb-Stage']=='media_policy' and events[1].UniqueID==nil)
vars.ringback='existing-custom-ringback';M.apply(session,'owned-domain');assert(vars.ringback=='existing-custom-ringback')
vars.transfer_ringback='local_stream://openweb';vars.ignore_early_media='false';vars.hold_music='customer-hold-music'
local previous=M.begin_group(session)
assert(vars.ringback:find('400,450',1,true) and vars.transfer_ringback==vars.ringback)
assert(vars.ignore_early_media=='true' and vars.bridge_early_media=='false' and vars.instant_ringback=='false')
assert(vars.hold_music=='customer-hold-music' and vars.rtp_secure_media=='mandatory')
M.end_group(session,previous)
assert(vars.ringback=='existing-custom-ringback' and vars.transfer_ringback=='local_stream://openweb')
assert(vars.ignore_early_media=='false' and vars.bridge_early_media==nil)
freeswitch.Event=function()error('Observer unavailable')end
M.trace(session,'owned-domain','provider_result',{Cause='NO_ANSWER'}) -- tracing cannot fail a call
print('PASS: anchored media, inherited leg policy, existing encryption/export/ringback and observer failure controls')

-- The Windows buffer is exported before originate; Debian and deliberate
-- per-extension choices keep their original media settings.
local actual_config=package.config
local function platform_call(config,initial)
    package.config=config
    local values=initial or {};local exports={}
    local client={getVariable=function(_,name)return values[name]end,
        setVariable=function(_,name,value)values[name]=value end,
        execute=function(_,app,data)assert(app=='export');local name,value=data:match('^([^=]+)=(.+)$');values[name]=value;exports[name]=value end}
    local ok,err=pcall(M.apply,client,'owned-domain')
    package.config=actual_config
    assert(ok,err);return values,exports
end
local windows,legs=platform_call('\\\n;\n?\n!\n-\n',{rtp_secure_media='mandatory',absolute_codec_string='PCMU'})
assert(windows.jitterbuffer_msec=='60:200' and legs.jitterbuffer_msec=='60:200')
assert(windows.rtp_jitter_buffer_during_bridge=='true' and legs.rtp_jitter_buffer_during_bridge=='true')
assert(windows.rtp_secure_media=='mandatory' and windows.absolute_codec_string=='PCMU')
assert(windows.disable_rtp_auto_adjust=='false' and windows.bypass_media=='false')
local custom,custom_exports=platform_call('\\',{jitterbuffer_msec='120:240',rtp_jitter_buffer_during_bridge='false'})
assert(custom.jitterbuffer_msec=='120:240' and custom.rtp_jitter_buffer_during_bridge=='false')
assert(custom_exports.jitterbuffer_msec==nil and custom_exports.rtp_jitter_buffer_during_bridge==nil)
local off,off_exports=platform_call('\\',{jitterbuffer_msec='0'})
assert(off.jitterbuffer_msec=='0' and off_exports.jitterbuffer_msec==nil and off_exports.rtp_jitter_buffer_during_bridge==nil)
local explicit,explicit_exports=platform_call('\\',{rtp_jitter_buffer_during_bridge='false'})
assert(explicit.jitterbuffer_msec=='60:200' and explicit.rtp_jitter_buffer_during_bridge=='false' and explicit_exports.rtp_jitter_buffer_during_bridge==nil)
local linux,linux_exports=platform_call('/\n;\n?\n!\n-\n',{})
assert(linux.jitterbuffer_msec==nil and linux.rtp_jitter_buffer_during_bridge==nil and linux_exports.jitterbuffer_msec==nil)
print('PASS: Windows buffered media inheritance, explicit buffer/off/bridge choices, codecs/encryption/NAT preservation and unchanged Debian policy')
