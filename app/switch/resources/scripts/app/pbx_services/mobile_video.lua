-- Only the selected, active native-app pair may forward video renegotiation.
-- post_originate runs after the engine sets the originator's signal_bond;
-- execute_on_answer is too early because an answered fork may still lose.
local M={}
local peer_key='openweb_mobile_video_peer'
local cleanup_key='execute_on_post_bridge_openweb_video'
local flags={'rtp_pass_codecs_on_stream_change','rtp_pass_codecs_on_reinvite'}
local function uuid(value)return type(value)=='string' and #value==36 and value:match('^[a-f0-9]+%-[a-f0-9]+%-[a-f0-9]+%-[a-f0-9]+%-[a-f0-9]+$')~=nil end
local function mobile(value)return type(value)=='string' and #value==36 and value:match('^owm%-[a-f0-9]+$')~=nil end
function M.video_capable_agent(agent)
 -- A capability hint, never an identity credential. Only released three-part
 -- OpenWeb Android versions are known to support this renegotiation policy.
 if type(agent)~='string' or #agent>64 then return false end
 local major,minor,patch=agent:match('^OpenWebPBX%-Android/(%d+)%.(%d+)%.(%d+)$')
 if not major then return false end
 for _,part in ipairs({major,minor,patch})do
  if #part>6 or (#part>1 and part:sub(1,1)=='0')then return false end
 end
 major,minor,patch=tonumber(major),tonumber(minor),tonumber(patch)
 return major>1 or major==1 and (minor>0 or minor==0 and patch>=16)
end
local live_states={CS_NEW=true,CS_INIT=true,CS_ROUTING=true,CS_SOFT_EXECUTE=true,CS_EXECUTE=true,
 CS_EXCHANGE_MEDIA=true,CS_PARK=true,CS_CONSUME_MEDIA=true,CS_HIBERNATE=true}
local function live(session,api,id)
 -- The native post_originate hook precedes its state-change-pending wait.
 -- ready() explicitly rejects that transient state, even for the winner.
 -- An extant nonterminal channel is sufficient here; the signal_bond and
 -- active-identity checks below independently prove which pair was selected.
 return live_states[session:getState()]==true and tostring(api:execute('uuid_exists',id)):match('^true%s*$')~=nil
end
local function value(v)if v==nil or v=='' or v=='_undef_' or v:sub(1,4)=='-ERR' then return nil end return v end
local function remote(api,id)
 return {get=function(key)return value(api:execute('uuid_getvar',id..' '..key))end,
 set=function(vars)
  local parts={};for key,v in pairs(vars)do parts[#parts+1]=key..'='..v end
  assert(tostring(api:execute('uuid_setvar_multi',id..' '..table.concat(parts,';'))):match('^%+OK'),'channel unavailable')
 end}
end
local function local_channel(session)
 return {get=function(key)return value(session:getVariable(key))end,
 set=function(vars)for key,v in pairs(vars)do session:setVariable(key,v~='' and v or nil)end end}
end
local function hook(peer)return 'lua app/pbx_services/mobile_video.lua cleanup '..peer end
local function saved(v)
 if not v then return 'n' end
 if #v>64 or not v:match('^[%w_%-]+$')then return nil end
 return 'v'..v
end
local function restore(channel,peer)
 if channel.get(peer_key)~=peer then return false end
 local vars={[peer_key]=''}
 for _,key in ipairs(flags)do
  local old=channel.get('openweb_video_saved_'..key)
  if channel.get(key)=='true' and old and (old=='n' or old:match('^v[%w_%-]+$'))then vars[key]=old=='n' and '' or old:sub(2)end
  vars['openweb_video_saved_'..key]=''
 end
 if channel.get(cleanup_key)==hook(peer)then vars[cleanup_key]='' end
 channel.set(vars)
 return true
end
function M.cleanup(session,api,peer)
 local id=session:get_uuid()
 if not uuid(id)or not uuid(peer)or id==peer then return false end
 local own=local_channel(session)
 if own.get(peer_key)~=peer then return false end
 -- Both bridge threads normally run the hook. Also restore the surviving
 -- partner here, so a hangup/transfer cannot leave forwarding on its next call.
 local other=remote(api,peer)
 pcall(restore,other,id)
 return restore(own,peer)
end
function M.run(session,api,db,media)
 local b=session:get_uuid();local a=session:getVariable('originating_leg_uuid')
 if not uuid(a)or not uuid(b)or a==b or not live(session,api,b)then return false end
 local callee=local_channel(session);local caller=remote(api,a)
 local domain=callee.get('openweb_video_domain');local extension=callee.get('openweb_video_extension')
 local user=callee.get('openweb_video_device');local realm=callee.get('sip_invite_domain')
 if not uuid(domain)or not uuid(extension)or not mobile(user)or not realm or realm=='' then return false end
 if caller.get('signal_bond')~=b or caller.get('sip_authorized')~='true' or caller.get('openweb_mobile_device')~='true'
  or caller.get('openweb_provider_origin')=='true'
  or caller.get('domain_uuid')~=domain or caller.get('sip_auth_realm')~=realm or caller.get('domain_name')~=realm then return false end
 local from=caller.get('sip_auth_username')
 if not mobile(from)or not media.active(db,domain,extension,user,realm)then return false end
 -- user/bridge expansion can overwrite A.extension_uuid with the callee's.
 -- Resolve the authenticated app account itself, never that mutable field.
 local identity=media.identity(db,domain,from,realm)
 if not identity or not uuid(identity.extension_uuid)or identity.domain_uuid~=domain
  or identity.domain_name~=realm or identity.sip_username~=from then return false end
 -- Inspect capability only after the authenticated DB ownership proofs.
 -- Older SDKs keep their ordinary hold/re-INVITE behavior on either leg.
 if not M.video_capable_agent(caller.get('sip_user_agent'))or not M.video_capable_agent(callee.get('sip_user_agent'))then return false end
 if caller.get(peer_key)==b and callee.get(peer_key)==a then return true end
 local function prepare(channel,peer)
  if channel.get(peer_key)or channel.get(cleanup_key)then return nil end
  local vars={[peer_key]=peer,[cleanup_key]=hook(peer)}
  for _,key in ipairs(flags)do
   local old=saved(channel.get(key));if not old then return nil end
   vars['openweb_video_saved_'..key]=old
  end
  return vars
 end
 local avars=prepare(caller,b);local bvars=prepare(callee,a)
 if not avars or not bvars or caller.get('signal_bond')~=b or not live(session,api,b)then return false end
 local ok=pcall(function()
  caller.set(avars);callee.set(bvars)
  assert(caller.get('signal_bond')==b and live(session,api,b),'selected pair changed')
  local enabled={};for _,key in ipairs(flags)do enabled[key]='true'end
  caller.set(enabled);callee.set(enabled)
 end)
 if not ok then pcall(restore,caller,b);pcall(restore,callee,a)end
 return ok
end
-- No new routing, answering or permissions: failure simply retains ordinary
-- media behavior. Cleanup needs no database and still works during DB outages.
if session and freeswitch then
 local db
 pcall(function()
  local api=freeswitch.API()
  if argv and argv[1]=='cleanup' then M.cleanup(session,api,argv[2]);return end
  local Database=require 'resources.functions.database'
  local media=require 'app.xml_handler.resources.scripts.directory.mobile_media'
  db=Database.new('system');M.run(session,api,db,media)
 end)
 if db then pcall(function()db:release()end)end
end
return M
