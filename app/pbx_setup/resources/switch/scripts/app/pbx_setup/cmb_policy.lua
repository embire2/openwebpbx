-- Callback callers may reach only explicitly permitted external destinations.
local C={}
function C.prompts_ready(root)
 for _,name in ipairs({'incoming-new','incoming-known','authenticated','enter-number','invalid-id','unavailable','invalid-number','quota-exhausted'}) do
  local file=io.open(root..'/openwebpbx/voices/1.0.1/call-me-back/'..name..'.wav','rb');if not file then return false end
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
return C
