-- Actual recording-function/answer-dispatch source with controlled sessions.
-- Native SIP, RTP and WAV acceptance is separate from these Lua controls.
local filename=os.getenv('OPENWEB_RECORDING_INDEX') or 'app/pbx_setup/resources/switch/scripts/app/pbx_setup/index.lua'
local file=assert(io.open(filename,'r'));local source=file:read('*a');file:close()
local first=assert(source:find('local function record(u,external)',1,true))
local last=source:find('local caller=',first,true) or source:find('local function outbound_contact',first,true)
local block=source:sub(first,assert(last)-1)
local build=assert(load([[return function(session,db,config,mode,key,domain,storage_dir,freeswitch,initial_internal)
local internal=initial_internal
]]..block..'\nreturn record\nend','recording source','t',setmetatable({},{__index=_G})))()
local domain='00000000-0000-4000-a000-000000000019'
local id='00000000-0000-4000-a000-000000000020'
local total=0
local function check(v,label)total=total+1;assert(v,label)end
local function fixture(answered)
    local f={vars={uuid=id,domain_uuid=domain},answered=answered==true,records={},rows={},logs={},released=0,manual=0}
    f.config={users={['100']={number='100',enabled=true,record_calls=true},['200']={number='200',enabled=true,record_calls=true}}}
    f.session={}
    function f.session:getVariable(name)return f.vars[name]end
    function f.session:setVariable(name,value)f.vars[name]=value end
    function f.session:answered()return f.answered end
    function f.session:execute(app,data)
        assert(app=='record_session','Unexpected native application '..tostring(app))
        if not f.answered then f.early=true end -- real record_session requires media/pre-answers
        f.records[#f.records+1]=data
    end
    f.db={}
    function f.db:query(sql,params)
        assert(sql:find('insert into v_pbx_media',1,true) and sql:find('on conflict do nothing',1,true))
        if f.db_error then error('Injected recording metadata failure')end
        f.rows[#f.rows+1]=params
    end
    function f.db:release()f.released=f.released+1 end
    f.fs={consoleLog=function(_,message)f.logs[#f.logs+1]=message end}
    function f:call(number,external,internal)
        local record=build(self.session,self.db,self.config,'user',number,domain,'/owned fixture/storage',self.fs,internal==true)
        record(self.config.users[number],external)
    end
    function f:callback(number)
        build(self.session,self.db,self.config,'record_user',number,domain,'/owned fixture/storage',self.fs,false)
    end
    function f:answer()
        self.answered=true
        -- Native switch_channel_execute_on runs every execute_on_answer* key;
        -- CF_ANSWERED is already set. Capture names before hooks alter variables.
        local hooks={}
        for name,value in pairs(self.vars)do
            if name:sub(1,#'execute_on_answer')=='execute_on_answer' then hooks[#hooks+1]=value end
        end
        for _,hook in ipairs(hooks)do
            if hook=='lua app.lua pbx_setup record_user' then self:callback()
            else assert(hook=='lua existing_manual.lua');self.manual=self.manual+1 end
        end
    end
    return f
end
local f=fixture()
f.vars.execute_on_answer='lua existing_manual.lua';f.vars.execute_on_answer_custom='lua existing_manual.lua'
f.vars.api_on_answer='uuid_setvar untouched marker true'
f.vars.openweb_scope_origin='100';f.vars.openweb_scope_target='200';f.vars.openweb_route_depth='19';f.vars.call_direction='local'
f.vars.ignore_early_media='false';f.vars.hangup_after_bridge='false';f.vars.continue_on_fail='true'
f:call('100',false,true)
check(#f.records==0 and not f.early,'An unanswered call must not invoke the media-requiring recording application')
check(#f.rows==0,'Unanswered calls must not create phantom recording rows')
check(f.vars.openweb_recording_pending=='100' and f.vars.openweb_recording~='true','Only a pending owner is claimed before answer')
check(f.vars.execute_on_answer_openweb_record=='lua app.lua pbx_setup record_user','The recording hook is local and namespaced')
check(f.vars.export_vars==nil and f.vars.export==nil,'The recording hook is not exported to callee legs')
f:call('200',false,true)
check(f.vars.openweb_recording_pending=='100','A recording recipient cannot replace the original recording owner')
f:answer()
check(#f.records==1 and #f.rows==1 and not f.early,'Answer starts exactly one recording and its metadata row')
check(f.records[1]=='/owned fixture/storage/openwebpbx/'..domain..'/'..id..'.wav','Existing recording path supports spaces unchanged')
check(f.vars.record_path=='/owned fixture/storage/openwebpbx/'..domain and f.vars.record_name==id..'.wav' and f.vars.record_stereo=='true','Path, name and stereo metadata remain unchanged')
check(f.rows[1].domain==domain and f.rows[1].id==id and f.rows[1].owner=='100' and f.rows[1].source=='calls/'..id..'.wav' and f.rows[1].title=='Call 100','Recording row retains domain, UUID, source and initial owner')
check(f.manual==2 and f.vars.api_on_answer=='uuid_setvar untouched marker true','Manual answer and API hooks remain intact')
check(f.vars.openweb_scope_origin=='100' and f.vars.openweb_scope_target=='200' and f.vars.openweb_route_depth=='19','Recording-only callback leaves routing identity/depth untouched')
check(f.vars.call_direction=='local' and f.vars.ignore_early_media=='false' and f.vars.hangup_after_bridge=='false' and f.vars.continue_on_fail=='true','Recording callback leaves call direction and native early-media/bridge policy untouched')
check(f.vars.openweb_recording=='true' and f.vars.openweb_recording_pending=='' and f.released==1,'Successful callback claims once, clears pending ownership and releases its connection')
f:call('100',true,true);f:callback('100');f:answer()
check(#f.records==1 and #f.rows==1,'Repeated answer, transfer/hold reinvocation and explicit callbacks cannot duplicate a recording')

f=fixture();f:call('100',false,true)
check(#f.rows==0 and #f.records==0,'A call ending without answer leaves neither recording nor media row')
f=fixture(true);f:call('200',false,false)
check(#f.records==1 and #f.rows==1 and f.rows[1].owner=='200','An already answered IVR/inbound call starts recording immediately')
check(f.vars.execute_on_answer_openweb_record==nil,'Already answered calls do not install a redundant hook')
f=fixture(true);f.vars.openweb_call_internal='false';f:callback('200')
check(#f.records==1 and f.rows[1].owner=='200' and f.released==1,'Existing answered recipient/queue recording callback is preserved')
f=fixture();f.vars.openweb_call_internal='false';f:callback('200');f:answer()
check(#f.records==1 and f.rows[1].owner=='200','An unexpectedly early recipient callback also waits for actual answer')
f=fixture(true);f.vars.openweb_call_internal='true';f.config.users['200'].record_external_only=true;f:callback('200')
check(#f.records==0 and #f.rows==0,'Internal recipient external-only policy remains respected')
f=fixture();f.config.users['100'].record_external_only=true;f:call('100',false,true)
check(f.vars.openweb_recording_pending==nil and #f.records==0,'External-only owner does not arm on a purely internal route')
f:call('100',true,true);f:answer()
check(#f.records==1 and f.rows[1].owner=='100','An authenticated outbound call preserves its explicit external-recording policy through the answer callback')
f=fixture();f:call('100',false,true);f:call('100',true,true);f:answer()
check(#f.records==1 and f.vars.openweb_recording_external=='true','An internal no-answer route later forwarded outside retains its original owner')
for _,case in ipairs({'disabled','not_recorded','malformed_uuid','foreign_pending'})do
    f=fixture(true)
    if case=='disabled' then f.config.users['100'].enabled=false
    elseif case=='not_recorded' then f.config.users['100'].record_calls=false
    elseif case=='malformed_uuid' then f.vars.uuid='not/a/uuid'
    else f.vars.openweb_recording_pending='200' end
    f:call('100',true,true)
    check(#f.records==0 and #f.rows==0,'Recording rejects '..case)
end
f=fixture();f:call('100',false,true);f.config.users['100'].enabled=false;f:answer()
check(#f.records==0 and #f.rows==0 and f.released==1,'A disabled user at answer does not start a stale pending recording')
f=fixture(true);f:callback('missing')
check(#f.records==0 and #f.rows==0 and f.released==1,'An unknown recording owner safely releases without routing or recording')
f=fixture();f:call('100',false,true);f.db_error=true;f:answer()
check(#f.records==1 and #f.rows==0 and f.released==1 and #f.logs==1,'Metadata failure is contained without routing, replaying recording or leaking the connection')
f:callback()
check(#f.records==1,'A failed metadata insert does not start a duplicate media tap')
print('PASS: '..total..' recording answer/metadata controls (synthetic native-session adapter)')
