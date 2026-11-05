-- Actual callback interpreter and policy; only SIP endpoints/registration are fixtures.
local root=assert(arg[1]);local path=assert(arg[2]);package.path=root..'/app/switch/resources/scripts/?.lua;'..package.path
local json=require'resources.functions.lunajson';local file=assert(io.open(path,'rb'));local fixture=json.decode(file:read('*a'));file:close()
local function quote(s)return "'"..s:gsub("'","'\\''").."'"end
local serial=0;local function query(sql,args,callback)
 if type(args)=='function'then callback=args;args={}end
 serial=serial+1;local p=fixture.work..'/query-'..serial..'.json';local f=assert(io.open(p,'wb'));f:write(json.encode({schema=fixture.schema,sql=sql,args=args or {}}));f:close()
 local child=assert(io.popen('php '..quote(fixture.helper)..' query '..quote(p),'r'));local text=child:read('*a');assert(child:close(),'Controlled PostgreSQL bridge failed')
 for _,row in ipairs(json.decode(text))do if callback then callback(row)end end;return true
end
package.loaded['resources.functions.config']=true
package.loaded['resources.functions.database']={new=function()return{query=function(_,...)return query(...)end,release=function()end}end}
scripts_dir=root..'/app/pbx_setup/resources/switch/scripts';storage_dir=fixture.work..'/storage';sounds_dir=fixture.work..'/sounds';config_file=fixture.work..'/config.conf';argv={fixture.request}
if fixture.scriptCheck or fixture.speedCheck then
 local C=assert(loadfile(scripts_dir..'/app/pbx_setup/cmb_policy.lua'))()
 local db=require('resources.functions.database').new()
 if fixture.speedCheck then print(json.encode({number=C.extension_speed_dial(db,fixture.domain,fixture.config,fixture.origin,fixture.slot)}))
 else print(json.encode(C.script_files(db,fixture.domain,fixture.service,storage_dir)))end;return
end
local original_loadfile,original_dofile=loadfile,dofile
loadfile=function(p,...)
 if p==scripts_dir..'/app/xml_handler/resources/scripts/directory/contact_realms.lua'then return original_loadfile(root..'/app/switch/resources/scripts/app/xml_handler/resources/scripts/directory/contact_realms.lua',...)end
 return original_loadfile(p,...)
end
dofile=function(p)
 if p==scripts_dir..'/app/pbx_onboarding/gate.lua'then return{allowed=function()return true end}end -- Accepted registration fixture only; no new onboarding claim.
 return original_dofile(p)
end
local sessions,bridges,timers,played={},{},{},{};local input=0;local vars={};local alive=true
local api={execute=function(_,command,value)
 if command=='sofia'then return'State NOREG\nStatus UP\n'end
 if command=='create_uuid'then return fixture.bridge end
 if command=='sched_api'then timers[#timers+1]=value;return'+OK 1'end
 if command=='sched_del'then return'+OK'end
 if command=='uuid_exists'then return'false'end
 error('Unexpected engine fixture operation '..command)
end}
local call={ready=function()return alive end,setVariable=function(_,k,v)vars[k]=v end,getVariable=function(_,k)return vars[k]end,hangup=function()alive=false end,hangupCause=function()return'NORMAL_CLEARING'end,streamFile=function(_,p)played[#played+1]=p end,playAndGetDigits=function()input=input+1;return fixture.inputs[input]end}
call.execute=function(_,application,leg)
 assert(application=='bridge','Unexpected live application');bridges[#bridges+1]=leg
 local previous=session;session={ready=function()return true end,hangup=function()error('The controlled destination answer was refused')end,getVariable=function(_,name)return ({uuid=fixture.bridge,openweb_cmb_parent_uuid=fixture.call,openweb_cmb_limit_seconds='600'})[name]end}
 original_dofile(scripts_dir..'/app/pbx_setup/call_me_back_answer.lua');session=previous
end
freeswitch={API=function()return api end,Session=function(leg)sessions[#sessions+1]=leg;return call end,consoleLog=function(_,message)error(message)end,msleep=function()end}
original_dofile(scripts_dir..'/app/pbx_setup/call_me_back.lua')
print(json.encode({sessions=sessions,bridges=bridges,timers=timers,played=played,inputs=input,actualProductionLuaAndRealPostgreSQL=true,registrationAndSipEndpointsAreFixtures=true}))
