#!/usr/bin/env python3
"""Actual file-cache + Sofia Lua renderer + PHP cleanup key regression; no PBX/SQL."""
import json,re,socket,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
fixture=(ROOT/'tests/windows-native-fixture.php').read_text()
fixed=re.search(r" \$sofiaCache=new cache\(\);[^\n]+",fixture).group(0)
checks=0
def check(value):
    global checks
    assert value
    checks+=1
check(fixed.count('->delete(')==2 and "gethostname().':configuration:sofia.conf'" in fixed)
settings=(ROOT/'resources/classes/settings.php').read_text()
method=re.search(r'public static function clear_cache\(\) \{.*?^\t\}',settings,re.S|re.M).group(0)
lua=r'''
local source,owned,mode,hostname=arg[1],arg[2],arg[3],arg[4]
package.path=source..'/app/switch/resources/scripts/?.lua;'..package.path
package.loaded['resources.functions.config']=true
cache={method='file',location=owned};debug={cache=false,sql=false,xml_string=false};expire={sofia='3600'}
api={execute=function(_,name)
 if name=='hostname' then return hostname end
 if name=='global_getvar' then return 'fictional=baseline' end
 if name=='create_uuid' then return '00000000-0000-4000-8000-000000000001' end
 error('Unexpected native boundary')
end}
freeswitch={consoleLog=function()end,Event=function()return{addHeader=function()end,fire=function()end}end}
local reads=0
package.preload['resources.functions.database']=function()return{new=function()
 reads=reads+1;assert(mode=='baseline','Unexpected authoritative read')
 return{connected=function()return true end,release=function()end,query=function(_,sql,params,callback)
  if sql:find('from v_sip_profiles as p',1,true) then
   for _,pair in ipairs({{'tls','false'},{'tls-cert-dir',''}})do callback({sip_profile_uuid='00000000-0000-4000-8000-000000000001',sip_profile_name='internal',sip_profile_setting_name=pair[1],sip_profile_setting_value=pair[2]})end
  end
 end}
end}end
require'resources.functions.trim'
local c=require'resources.functions.cache'
local seed='<document type="freeswitch/xml"><section name="configuration"><configuration name="sofia.conf"><profiles><profile name="internal"><settings><param name="tls" value="true"/><param name="tls-cert-dir" value="fictional-fixture-tls"/></settings></profile></profiles></configuration></section></document>'
if mode=='seed'then assert(c.set(hostname..':configuration:sofia.conf',seed,1));assert(c.set('configuration:sofia.conf',seed,1))end
XML_STRING=nil;dofile(source..'/app/switch/resources/scripts/app/xml_handler/resources/scripts/configuration/sofia.conf.lua')
if mode=='seed'or mode=='stale'then assert(XML_STRING==seed and reads==0)
else assert(XML_STRING:find('name="tls" value="false"',1,true) and not XML_STRING:find('fictional-fixture-tls',1,true));assert(reads==(mode=='baseline'and 1 or 0))end
print('actual_renderer_'..mode..'_passed')
'''
with tempfile.TemporaryDirectory(prefix='ow-native-sofia-') as folder:
    base=Path(folder);owned=base/'cache';owned.mkdir();script=base/'renderer.lua';script.write_text(lua)
    hostname=socket.gethostname();hostkey=owned/(hostname+'.configuration.sofia.conf');globalkey=owned/'configuration.sofia.conf'
    def render(mode):
        result=subprocess.run(['lua',str(script),str(ROOT),str(owned),mode,hostname],capture_output=True,text=True,check=True)
        check(result.stdout.strip()=='actual_renderer_'+mode+'_passed' and not result.stderr)
    render('seed');before=hostkey.read_bytes();globalbefore=globalkey.read_bytes();unrelated=owned/'unrelated';unrelated.write_text('preserved')
    # Actual clear_cache() method and actual cache class; only settings/config/native-event boundaries are fictional.
    shim='<?php class settings {public function get($a,$b,$d=null){return $d;}'+method+'} class config{public static $location;public static function load(){return new self;}public function get($k,$d=null){return $k==="cache.method"?"file":($k==="cache.location"?self::$location:$d);}} class event_socket{public static $calls=[];public static function create(){return true;}public static function command($v){self::$calls[]=$v;}} config::$location=$argv[1]; require '+json.dumps(str(ROOT/'resources/classes/cache.php'))+';settings::clear_cache();'
    old=base/'old.php';old.write_text(shim+'echo "old_clear_only";')
    child=subprocess.run(['php','-n','-d','error_reporting=24575',str(old),str(owned)],capture_output=True,text=True,check=True);check(child.stdout=='old_clear_only' and not child.stderr)
    check(hostkey.read_bytes()==before);check(globalkey.read_bytes()==globalbefore);render('stale')
    fixedphp=base/'fixed.php';fixedphp.write_text(shim+fixed+' if(count(event_socket::$calls)!==2)throw new RuntimeException("Invalidation count");echo "exact_keys_deleted";')
    child=subprocess.run(['php','-n','-d','error_reporting=24575',str(fixedphp),str(owned)],capture_output=True,text=True,check=True);check(child.stdout=='exact_keys_deleted' and not child.stderr)
    check(not hostkey.exists());check(not globalkey.exists());check(unrelated.read_text()=='preserved')
    render('baseline');check(hostkey.exists() and b'fictional-fixture-tls' not in hostkey.read_bytes());render('cached-baseline')
check(fixture.index('$restoreGlobals();',fixture.index("if($action==='cleanup')"))<fixture.index(fixed)<fixture.index("$cleanupReloadXml=trim((string)event_socket::api('reloadxml'))"))
print(f'PASS {checks} actual PHP cache/cleanup-key/Lua fresh-process Sofia stale-vs-restored-renderer controls; no PBX or SQL')
