-- Callback callers may reach only explicitly permitted external destinations.
local C={}
function C.greeting_file(service)
 local file=service.prompt_audio_file
 if not file or file=='greeting.wav' then return 'greeting.wav' end
 local hash=service.prompt_sha256
 if service.prompt_version=='1.0.2' and type(hash)=='string' and #hash==64 and hash:match('^[a-f0-9]+$') and file=='greeting-keoma-'..hash..'.wav' then return file end
 return nil
end
function C.prompts_ready(root)
 for _,name in ipairs({'incoming-new','incoming-known','authenticated','enter-number','invalid-id','unavailable','invalid-number','quota-exhausted'}) do
  local file=io.open(root..'/openwebpbx/voices/1.0.2/call-me-back/'..name..'.wav','rb');if not file then return false end
  local header=file:read(12);file:close();if not header or header:sub(1,4)~='RIFF' or header:sub(9,12)~='WAVE' then return false end
 end
 return true
end
function C.uuid(v)return type(v)=='string' and #v==36 and v:match('^[a-f0-9%-]+$')~=nil end
function C.cli(v)
 if type(v)~='string' then return nil end
 if v:match('^0[1-8]%d%d%d%d%d%d%d%d$') then v='+27'..v:sub(2)
 elseif v:match('^27[1-8]%d%d%d%d%d%d%d%d$') then v='+'..v end
 if #v~=12 or not v:match('^%+27[1-8]%d+$') or v:sub(1,5)=='+2786' then return nil end
 return v
end
function C.number(config,service,number,P)
 if type(number)~='string' or #number<7 or #number>16 or not number:match('^%+?%d+$') then return nil end
 if config.users[number] or P.emergency(config,number) then return nil end
 for _,kind in ipairs({'queues','ring_groups','receptionists','scripts','specials'}) do if P.find(config[kind],number) then return nil end end
 local allowed=false;for _,prefix in ipairs(service.destination_prefixes or {}) do if type(prefix)=='string' and #prefix>0 and number:sub(1,#prefix)==prefix then allowed=true end end
 if not allowed then return nil end
 local owner=config.users[tostring(service.route_owner)]
 if not owner or not owner.enabled then return nil end
 local rule=P.outbound(config,number,tostring(service.route_owner))
 if not rule or #(rule.routes or {})==0 then return nil end
 return rule,owner
end
-- A chosen callback gateway is never copied into the onward destination rule.
function C.callback_routes(config,service,rule)
 if not service.callback_gateway_uuid or service.callback_gateway_uuid=='' then return rule.routes end
 if not C.uuid(service.callback_gateway_uuid) then return {} end
 for key,trunk in pairs(config.trunks or {}) do
  if trunk.gateway_uuid==service.callback_gateway_uuid and trunk.enabled then
   for _,route in ipairs(rule.routes or {}) do if tostring(route.trunk_id)==tostring(key) then return {route} end end
   return {{trunk_id=key,strip=0,prepend=''}}
  end
 end
 return {}
end
function C.extension_speed_dial(db,domain,config,origin,slot)
 if not C.uuid(domain) or type(origin)~='string' or type(slot)~='string' or not slot:match('^[1-9]$') then return nil end
 local user=(config.users or {})[origin];if not user or not user.enabled or not C.uuid(user.extension_uuid) then return nil end
 local departments={}
 for _,department in ipairs(config.departments or {}) do for _,member in ipairs(department.members or {}) do if tostring(member.number)==origin then departments[tostring(department.number)]=true end end end
 local choices={}
 db:query([[select distinct a.account_uuid,r.department_id,s.phone_number from v_pbx_cmb_accounts a
  join v_pbx_staff_roles r on r.domain_uuid=a.domain_uuid and r.user_uuid=a.web_user_uuid and r.enabled
  join v_users u on u.user_uuid=r.user_uuid and u.user_enabled='true'
  left join v_pbx_cmb_speed_dials s on s.domain_uuid=a.domain_uuid and s.account_uuid=a.account_uuid and s.slot=cast(:slot as smallint)
  where a.domain_uuid=:domain and r.extension_uuid=:extension and a.enabled and a.id_last4 is not null]],
  {domain=domain,extension=user.extension_uuid,slot=slot},function(row)if departments[tostring(row.department_id)] then choices[row.account_uuid]=row end end)
 local selected,count=nil,0;for _,row in pairs(choices) do selected=row.phone_number;count=count+1 end
 if count==1 and type(selected)=='string' and selected:match('^%+?%d+$') then return selected end
end
function C.script_files(db,domain,service,storage)
 local files={}
 if not C.uuid(domain) or not C.uuid(service) or type(storage)~='string' then return files end
 local installed=false
 db:query("select to_regclass('v_pbx_cmb_scripts') is not null and to_regclass('v_pbx_greetings') is not null and to_regclass('v_pbx_media') is not null as ready",{},function(row)installed=row.ready=='t' or row.ready=='true' or row.ready==true end)
 if not installed then return files end
 db:query([[select s.step,g.greeting_uuid,m.file_path from v_pbx_cmb_scripts s
 join v_pbx_greetings g on g.domain_uuid=s.domain_uuid and g.state='ready' and g.source='text'
  and (g.greeting_uuid=s.greeting_uuid or g.greeting_uuid=s.active_greeting_uuid)
 join v_pbx_media m on m.domain_uuid=s.domain_uuid and m.media_uuid=g.media_uuid and m.category='prompts'
 where s.domain_uuid=:d and s.service_uuid=:s
 order by s.step,case when g.greeting_uuid=s.greeting_uuid then 0 else 1 end]],{d=domain,s=service},function(row)
  if files[row.step] or not C.uuid(row.greeting_uuid) or type(row.file_path)~='string' then return end
  local path=row.file_path:gsub('\\','/');local base=storage:gsub('\\','/'):gsub('/$','')
  local suffix='/'..domain..'/greetings/'..row.greeting_uuid..'/audio.wav'
  if path:sub(1,#base+1)~=base..'/' or path:sub(-#suffix)~=suffix or path:find('/%.%./') then return end
  local f=io.open(path,'rb');if not f then return end;local h=f:read(12);f:close()
  if h and h:sub(1,4)=='RIFF' and h:sub(9,12)=='WAVE' then files[row.step]=path end
 end)
 return files
end
return C
