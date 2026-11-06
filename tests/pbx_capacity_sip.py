"""Native simultaneous-call admission against fictional loopback SIP peers only."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid
from sip_trunk_live import Peer


def main():
    if os.environ.get('OPENWEB_LIVE_CAPACITY_TEST') != '1':
        raise SystemExit('Set OPENWEB_LIVE_CAPACITY_TEST=1 for the isolated native check.')
    root = Path(__file__).resolve().parents[1]
    stage = Path(tempfile.mkdtemp(prefix='openweb-capacity-', dir='/run'))
    stage.chmod(0o755)
    peer = Peer(provider=True)
    owned = [str(uuid.uuid4()) for _ in range(8)]
    domain, other = str(uuid.uuid4()), str(uuid.uuid4())

    def api(command):
        result = subprocess.run(['fs_cli', '-x', command], capture_output=True, text=True, timeout=45)
        assert result.returncode == 0, 'Owned native command failed'
        return result.stdout.strip()

    try:
        target = stage/'capacity.lua'
        shutil.copyfile(root/'app/pbx_setup/resources/switch/scripts/app/pbx_setup/capacity.lua', target)
        target.chmod(0o644)
        assert api('module_exists mod_hash') == 'true'
        source = '''
local checks=0;local function check(value,message)checks=checks+1;assert(value,message)end
local C=dofile(STAGE..'/capacity.lua')
local hold=false
local db={query=function(self,sql,args,callback)callback({maximum='1',restore_hold=hold and 't' or 'f'})end}
local function call(i,vars)
 return freeswitch.Session('{'..(vars or '')..'origination_uuid='..IDS[i]..',process_cdr=false,no_cdr=true,absolute_codec_string=PCMA,originate_timeout=3,ignore_early_media=true}sofia/external/990099@127.0.0.1:PORT')
end
local function used(d)return tonumber(freeswitch.API():execute('limit_usage','hash openweb-pbx-'..d..' calls'))end
local first=call(1);check(first:ready(),'First native session failed')
check(C.admit(first,db,DOMAIN),'First call was refused');check(used(DOMAIN)==1,'First call did not reserve exactly one slot')
check(C.admit(first,db,DOMAIN),'A transfer reused its own slot incorrectly');check(used(DOMAIN)==1,'Transfer counted a second call')
local second=call(2);check(second:ready(),'Second fictional peer unavailable');check(not C.admit(second,db,DOMAIN),'Second call bypassed simultaneous-call limit');check(first:ready(),'Refusal disturbed the existing call');check(used(DOMAIN)==1,'Refusal leaked a slot')
local foreign=call(3);check(C.admit(foreign,db,OTHER),'Independent PBX was affected by another PBX limit');check(used(OTHER)==1,'Independent PBX slot missing');foreign:hangup('NORMAL_CLEARING')
first:hangup('NORMAL_CLEARING');freeswitch.msleep(100);check(used(DOMAIN)==0,'Hangup leaked capacity')
local third=call(4);check(C.admit(third,db,DOMAIN),'Freed slot could not be used');hold=true;check(not C.admit(third,db,DOMAIN),'Restore hold was bypassed');hold=false
freeswitch.msleep(100);check(used(DOMAIN)==0,'Restore refusal leaked capacity')
local origin=C.origin(db,DOMAIN);check(type(origin)=='string' and origin~='','Background call hook missing')
local callback=call(5,origin);check(callback:ready() and used(DOMAIN)==1,'Background callback did not reserve capacity')
local rejected=call(6,origin);check(not rejected:ready(),'Background callback bypassed capacity');check(callback:ready(),'Existing callback was interrupted')
callback:hangup('NORMAL_CLEARING');freeswitch.msleep(100);check(used(DOMAIN)==0,'Callback hangup leaked capacity')
hold=true;check(C.origin(db,DOMAIN)==nil,'Background call bypassed restore hold')
stream:write('{"native_checks":'..checks..',"slot_released":true,"existing_call_preserved":true,"independent_tenant_preserved":true,"callback_limit_enforced":true}')
'''
        prefix = '\n'.join('local '+k+'='+json.dumps(v) for k,v in {'STAGE':str(stage),'DOMAIN':domain,'OTHER':other,'IDS':owned}.items())
        # Lua arrays use braces, whereas JSON's array literal uses brackets.
        prefix = prefix.replace('local IDS='+json.dumps(owned), 'local IDS={'+','.join(json.dumps(x) for x in owned)+'}')
        script = stage/'run.lua';script.write_text(prefix+'\n'+source.replace('PORT',str(peer.port)));script.chmod(0o644)
        result=json.loads(api('lua '+str(script)))
        assert result['slot_released'] and result['callback_limit_enforced']
        assert api('limit_usage hash openweb-pbx-'+domain+' calls')=='0'
        assert api('limit_usage hash openweb-pbx-'+other+' calls')=='0'
        print(json.dumps({'actual_native_sip':True,'customer_calls':False,**result},sort_keys=True))
    finally:
        for identifier in owned:
            if api('uuid_exists '+identifier)=='true':api('uuid_kill '+identifier+' NORMAL_CLEARING')
        peer.close();shutil.rmtree(stage)


if __name__=='__main__':main()
