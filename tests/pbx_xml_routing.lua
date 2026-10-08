-- Native XML handlers exercised without an engine, SIP traffic or live writes.
-- Optional JSON input contains rows selected by the isolated PostgreSQL check.
local scripts='app/switch/resources/scripts'
package.path=scripts..'/?.lua;'..package.path
local json=require 'resources.functions.lunajson'
local n=0
local function check(value,message)n=n+1;assert(value,message)end
local incoming='<extension name="fixture-to"><condition field="${sip_gateway}" expression="^(?:00000000-0000-4000-a000-000000000001)?$"/><condition field="${sip_network_ip}" expression="^192[.]0[.]2[.]10$"/><condition field="${sip_to_user}" expression="^12025550100$"><action application="lua" data="app.lua pbx_setup incoming fixture-rule"/></condition></extension>'
local selected={incoming_rows={{dialplan_xml=incoming}},provider_rows={{provider_ip='192.0.2.10'},{provider_ip='2001:db8::10'},{provider_ip='::ffff:192.0.2.10'},{provider_ip='300.1.2.3'},{provider_ip='192.0.2.10/0'},{provider_ip='0.0.0.0/0'},{provider_ip='192.0.2.10"/><node type="allow" cidr="0.0.0.0/0'},{provider_ip='::::'},{provider_ip='abcd:'},{provider_ip='1::2::3'},{provider_ip='1:2:3:4:5:6:7'},{provider_ip='1:2:3:4:5:6:7:8:9'},{provider_ip='12345::1'},{provider_ip='1:2:3:4:5:6:7:8::'},{provider_ip='::ffff:999.0.0.1'},{provider_ip='::ffff:192.0.2.01'},{provider_ip='192.000.2.10'}}}
if arg[1] then local file=assert(io.open(arg[1],'rb'));selected=json.decode(file:read('*a'));file:close();incoming=selected.incoming_rows[1].dialplan_xml end
local legacy='<document type="freeswitch/xml"><section name="dialplan"><context name="public"><extension name="legacy"/></context></section></document>'
local function run(kind,options)
    options=options or {}
    local records={queries={},connections={},cache={},writes={}}
    local context=options.context or 'public'
    local base_key='dialplan:'..context..':contact-alias'
    records.cache['dialplan:destination']='destination_number';records.cache['dialplan:mode']='single'
    if not options.cold then records.cache[base_key]=legacy end
    if options.fragment_cached then records.cache['dialplan:openweb-incoming:fixture-host']=options.fragment_cached end
    if options.acl_cached then records.cache['configuration:acl.conf']=options.acl_cached end
    local cache={get=function(key)local value=records.cache[key];return value,value==nil and 'NOT FOUND' or nil end,
        set=function(key,value,ttl)records.cache[key]=value;records.writes[key]={value=value,ttl=ttl};return true end}
    local Database={new=function()
        local db={released=false};records.connections[#records.connections+1]=db
        function db:connected()return true end
        function db:release()self.released=true end
        function db:first_value()return nil end
        function db:query(sql,params,callback)
            if type(params)=='function' then callback=params;params={} end
            records.queries[#records.queries+1]={sql=sql,params=params}
            local rows={}
            if sql:find('to_regclass',1,true) then rows={{installed=options.uninstalled and 'false' or 'true'}}
            elseif sql:find('select plan.dialplan_xml',1,true) then
                assert(params.hostname=='fixture-host','Fragment reused a missing or stale hostname')
                rows=options.empty and {} or selected.incoming_rows
            elseif sql:find('provider_ip',1,true) then rows=selected.provider_rows
            elseif sql:find('from v_access_controls',1,true) then rows={{access_control_uuid='fixture-providers',access_control_name='providers',access_control_default='deny'},{access_control_uuid='fixture-domains',access_control_name='domains',access_control_default='deny'}}
            elseif sql:find('from v_access_control_nodes',1,true) then rows={{node_type='deny',node_cidr='203.0.113.20/32',node_description='Existing policy'}}
            elseif sql:find('select domain_name',1,true) then rows={{domain_name='fixture.example.invalid',domain_description='Existing directory'}}
            elseif not options.no_legacy then rows={{dialplan_xml='<extension name="legacy"/>',domain_enabled='true'}}
            end
            for _,row in ipairs(rows)do callback(row)end
        end
        return db
    end}
    local env=setmetatable({api={execute=function(_,command)assert(command=='hostname');return 'fixture-host\n' end},
        trim=function(value)return value:match('^%s*(.-)%s*$')end,call_context=context,destination_number='contact-alias',
        hostname=options.stale_hostname,expire={dialplan=60,acl=60},debug={},temp_dir='/nonexistent-fixture',
        freeswitch={consoleLog=function()end}}, {__index=_G})
    env.require=function(name)
        if name=='resources.functions.cache' then return cache end
        if name=='resources.functions.database' then return Database end
        if name=='resources.functions.log' then return {xml_handler={notice=function()end}} end
        return require(name)
    end
    local file=kind=='acl' and 'configuration/acl.conf.lua' or 'dialplan/dialplan.lua'
    local loaded,err=loadfile(scripts..'/app/xml_handler/resources/scripts/'..file,'t',env);assert(loaded,err);loaded()
    records.xml=env.XML_STRING
    return records
end
local function count(value,needle)local total=0;local pos=1;while true do local start=value:find(needle,pos,true);if not start then return total end;total=total+1;pos=start+#needle end end
local r=run('dialplan')
check(r.xml and r.xml:find(incoming,1,true),'A cached legacy base includes the active original To-field route')
check(r.xml:find(incoming,1,true)<r.xml:find('<extension name="legacy"/>',1,true),'Scoped incoming conditions execute before legacy fallbacks')
check(r.cache['dialplan:public:contact-alias']==legacy,'Fragments do not contaminate the request-number base cache')
check(r.writes['dialplan:openweb-incoming:fixture-host'] and r.connections[2].released,'Hostname fragment cache is filled and its connection released')
check(count(r.xml,incoming)==1,'One request includes each fragment once')
r=run('dialplan',{stale_hostname='other-host'})
check(r.xml:find(incoming,1,true),'Cached execution fetches the current native hostname')
r=run('dialplan',{fragment_cached=incoming})
check(#r.connections==1 and count(r.xml,incoming)==1,'An incoming-fragment cache hit creates no second connection or duplicate route')
r=run('dialplan',{fragment_cached=''})
check(r.xml==legacy and #r.connections==1,'Cached empty fragment preserves the legacy base without repeated queries')
r=run('dialplan',{uninstalled=true})
check(r.xml==legacy and r.connections[2].released,'Original installation without restore tables remains usable')
r=run('dialplan',{empty=true})
check(r.xml==legacy,'No active restored routes leave the native base intact')
r=run('dialplan',{cold=true})
check(r.xml and r.xml:find(incoming,1,true),'Cold base generation also includes To-field routes')
r=run('dialplan',{cold=true,no_legacy=true})
check(r.xml and r.xml:find(incoming,1,true) and r.xml:find('<context name="public"',1,true),'An active incoming route works when the legacy lookup returns no base')
r=run('dialplan',{context='fixture.example.invalid',cold=true})
check(not r.xml:find(incoming,1,true) and #r.connections==1,'An internal tenant context does not receive the shared public fragment')
r=run('acl')
local providers,domains=r.xml:match('<list name="providers".-</list>'),r.xml:match('<list name="domains".-</list>')
check(providers and providers:find('cidr="192.0.2.10/32"',1,true) and providers:find('cidr="2001:db8::10/128"',1,true),'Approved literal provider addresses receive exact IPv4/IPv6 masks')
check(not providers:find('300.1.2.3',1,true) and not providers:find('0.0.0.0/0',1,true),'Invalid addresses and supplied CIDRs cannot broaden the provider ACL')
check(providers:find('cidr="::ffff:192.0.2.10/128"',1,true),'Valid IPv4-mapped IPv6 stays an exact /128 literal')
for _,bad in ipairs({'::::','abcd:','1::2::3','1:2:3:4:5:6:7','1:2:3:4:5:6:7:8:9','12345::1','1:2:3:4:5:6:7:8::','::ffff:999.0.0.1','::ffff:192.0.2.01','192.000.2.10'})do check(not providers:find('cidr="'..bad..'/',1,true),'Malformed provider literal is rejected: '..bad)end
check(not domains:find('OpenWeb PBX incoming provider',1,true),'Provider authorization does not modify the domains ACL')
check(providers:find('203.0.113.20/32',1,true) and providers:find('fixture.example.invalid',1,true),'Existing ACL nodes and directory-domain entries are preserved')
check(r.connections[1].released and r.writes['configuration:acl.conf'],'ACL connection releases and complete XML is cached')
r=run('acl',{uninstalled=true})
check(not r.xml:find('OpenWeb PBX incoming provider',1,true),'Uninstalled restore schema does not generate provider ACL nodes')
r=run('acl',{acl_cached='<cached-acl/>'})
check(r.xml=='<cached-acl/>' and #r.connections==0,'Cached ACL generation creates no database connection')
print('PASS: '..n..' isolated native XML cache, ingress and ACL checks')
