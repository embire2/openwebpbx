local source,overlay,folder = arg[1],arg[2],arg[3]
package.path=source..'/app/switch/resources/scripts/?.lua;'..package.path
local json=require'resources.functions.lunajson'
local input=assert(io.open(folder..'/case.json','r'));local cfg=json.decode(input:read('*a'));input:close()
local debuglib=debug
local stats={queries=0,max_sql_bytes=0,stage=0,cleanup=0,final=0,recovery=0,lua_version=_VERSION,bit_backend=bit32 and 'bit32' or bit and 'bit' or 'native-bitops'}
local function quote(value)return "'"..value:gsub("'","'\\''").."'"end
local function execute(sql)
    local query=assert(io.open(folder..'/query.sql','w'));query:write(sql);query:close()
    local cmd=quote(cfg.psql)..' -X -qAt -F "\t" -h '..quote(cfg.socket)..' -p '..string.format('%d',cfg.port)..' -U postgres -d postgres -v ON_ERROR_STOP=1 -f '..quote(folder..'/query.sql')..' 2>'..quote(folder..'/query.stderr')
    local pipe=assert(io.popen(cmd,'r'));local text=pipe:read('*a');local ok=pipe:close()
    return ok~=nil,text
end
package.preload['resources.functions.config']=function()database={backend='fixture'};return true end
package.preload['resources.functions.cache']=function()return {settings=true}end
local prefinal=false
package.preload['resources.functions.database.fixture']=function()
 local B={};B.__index=B
 function B.new()return setmetatable({},B)end
 function B:query(sql,callback)
    stats.queries=stats.queries+1;stats.max_sql_bytes=math.max(stats.max_sql_bytes,#sql)
    local phase=sql:match('^WITH locked') and 'final' or sql:find('AS staged_uuid',1,true) and 'stage' or sql:match('^DELETE') and 'cleanup' or 'recovery'
    stats[phase]=stats[phase]+1
    if phase=='final' and not prefinal then
        prefinal=true
        if cfg.hook and cfg.hook~='' then assert(execute(cfg.hook)) end
        if cfg.reached then local f=assert(io.open(folder..'/final.reached','w'));f:write('ready');f:close() end
        local f=assert(io.open(folder..'/final.sql','w'));f:write(sql);f:close()
    end
    if cfg.mode=='readback_fail' and phase=='recovery' then return false end
    if cfg.mode=='stage_schema_fail' and phase=='stage' and stats.stage==2 then return false end
    local ok,output=execute(sql)
    if (cfg.mode=='lost_stage_ack' and phase=='stage' and stats.stage==2) or
       ((cfg.mode=='lost_final_ack' or cfg.mode=='readback_fail' or cfg.mode=='recovery_callback_false') and phase=='final') then return false end
    if not ok then return false end
    if callback and output~='' then
        for line in output:gmatch('[^\n]+') do
            if phase=='stage' then
                local id,piece=line:match('^([^\t]+)\t(.*)$');callback({staged_uuid=id,staged_bytes=piece})
            elseif phase=='final' then
                local id,complete=line:match('^([^\t]+)\t(.*)$');callback({email_queue_uuid=id,complete=complete})
            else callback({email_queue_uuid=line}) end
        end
    end
    if cfg.mode=='recovery_callback_false' and phase=='recovery' then stats.callback_received_before_false=true;return false end
    return true
 end
 return B
end
local n=0
freeswitch={consoleLog=function()end,API=function()return {
 execute=function(_,command,value)assert(command=='sql_escape');return value:gsub("'","''")end,
 executeString=function(_,command)assert(command=='create_uuid');n=n+1;assert(cfg.ids[n]);return cfg.ids[n]end
}end};debug={sql=false}
local Database=require'resources.functions.database';local db=Database.new('system')
local helper=assert(loadfile(overlay))()
local checksum
for index=1,50 do local name,value=debuglib.getupvalue(helper.enqueue,index);if not name then break end;if name=='sha256' then checksum=value end end
assert(checksum and checksum('')=='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855')
assert(checksum('abc')=='ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
local start=os.clock()
local id,err=helper.enqueue(db,cfg.values,cfg.audio,cfg.encoded)
stats.queued=id;stats.refused=err~=nil;stats.cpu_seconds=os.clock()-start;stats.checksum_vectors=2
local report=assert(io.open(folder..'/lua.safe.json','w'));report:write(json.encode(stats));report:close()
