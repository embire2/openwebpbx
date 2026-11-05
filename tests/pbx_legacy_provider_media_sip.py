"""Opt-in real-engine media checks on an isolated loopback provider.

Exercises the production provider policy with a mandatory-SRTP caller choice.
No tenant, real gateway, phone credential or external call is modified.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid
from sip_trunk_live import Peer


def main():
    if os.environ.get('OPENWEB_LIVE_LEGACY_PROVIDER_MEDIA_TEST') != '1':
        raise SystemExit('Set OPENWEB_LIVE_LEGACY_PROVIDER_MEDIA_TEST=1 for loopback native checks.')
    repo = Path(__file__).resolve().parents[1]
    stage = Path(tempfile.mkdtemp(prefix='openweb-legacy-provider-', dir='/run'))
    stage.chmod(0o755)
    peer = Peer(provider=True)
    owned = str(uuid.uuid4())

    def api(command):
        result = subprocess.run(['fs_cli', '-x', command], capture_output=True, text=True, timeout=15)
        assert result.returncode == 0, 'Owned native command failed'
        return result.stdout.strip()

    try:
        shutil.copy2(repo/'app/pbx_setup/resources/switch/scripts/app/pbx_setup/policy.lua', stage/'policy.lua')
        (stage/'policy.lua').chmod(0o644)
        source = '''
local P=dofile(STAGE..'/policy.lua')
local t={gateway_uuid=GATEWAY,number='fixture',srtp_mode='SRTPDisabled',codecs={'PCMA'},headers={ContactUser='$OutboundCallerId',FromUserPart='$OutboundCallerId'},host='127.0.0.1',port=PORT}
local native={proxy='127.0.0.1:'..PORT,profile='external',register_transport='udp'}
local dial=P.outbound_leg(t,{strip=0,prepend=''},'990099',{},'1000',DOMAIN,'fixture.invalid',native,{})
assert(dial and dial:find('rtp_secure_media_outbound=forbidden',1,true))
local s=freeswitch.Session('{origination_uuid='..OWNED..',process_cdr=false,no_cdr=true,originate_timeout=3,ignore_early_media=true,rtp_secure_media=mandatory:AES_CM_128_HMAC_SHA1_80}'..dial)
local ready=s:ready()
if ready then s:hangup('NORMAL_CLEARING')end
stream:write('{'..'"connected":'..tostring(ready)..'}')
'''
        prefix = '\n'.join('local '+k+'='+json.dumps(v) for k,v in {
            'STAGE':str(stage), 'GATEWAY':str(uuid.uuid4()), 'DOMAIN':str(uuid.uuid4()), 'OWNED':owned}.items())
        script = stage/'run.lua'
        script.write_text(prefix+'\n'+source.replace('PORT',str(peer.port)))
        script.chmod(0o644)
        result = json.loads(api('lua '+str(script)))
        assert len(peer.invites) == 1, 'Exactly one loopback provider INVITE required'
        offer = peer.invites[0]['sdp']
        assert result['connected'], 'Plain provider did not connect'
        assert 'RTP/SAVP' not in offer and 'a=crypto:' not in offer, 'Imported plain provider inherited caller SRTP'
        assert 'RTP/AVP' in offer, 'Plain provider offer missing'
        print(json.dumps({'actual_native_sip':True, 'legacy_disabled_overrides_caller_mandatory_srtp':True,
                          'plain_provider_connected':True, 'invites':1, 'customer_calls':False,
                          'sdp_or_keys_published':False}, indent=2))
    finally:
        if api('uuid_exists '+owned) == 'true':
            api('uuid_kill '+owned+' NORMAL_CLEARING')
        peer.close()
        shutil.rmtree(stage)


if __name__ == '__main__':
    main()
