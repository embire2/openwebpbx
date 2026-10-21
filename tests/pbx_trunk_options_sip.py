"""Opt-in native provider offer checks; SIP/RTP stay on fictional loopback peers.

No customer domain, credentials, carrier, native gateway or profile is changed.
The safe report deliberately excludes SDP, which can contain ephemeral SRTP keys.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import uuid
from sip_trunk_live import Peer


def main():
    if os.environ.get('OPENWEB_LIVE_TRUNK_OPTIONS_TEST') != '1':
        raise SystemExit('Set OPENWEB_LIVE_TRUNK_OPTIONS_TEST=1 for isolated native SIP checks.')
    repo = Path(__file__).resolve().parents[1]
    directory = Path(tempfile.mkdtemp(prefix='openweb-trunk-options-sip-', dir='/run'))
    directory.chmod(0o755)
    peer = Peer(provider=True)
    facts = []
    owned = []

    def api(command):
        result = subprocess.run(['fs_cli', '-x', command], capture_output=True, text=True, timeout=15)
        if result.returncode:
            raise AssertionError('Owned native command failed')
        return result.stdout.strip()

    try:
        shutil.copyfile(repo/'app/pbx_setup/resources/switch/scripts/app/pbx_setup/trunk_options.lua', directory/'trunk_options.lua')
        (directory/'trunk_options.lua').chmod(0o644)
        assert api('module_exists mod_hash') == 'true'
        domain, gateway = str(uuid.uuid4()), str(uuid.uuid4())
        for mode in ['inherit', 'disabled', 'optional', 'required']:
            identifier = str(uuid.uuid4())
            owned.append(identifier)
            before = len(peer.invites)
            source = '''
local T=dofile(STAGE..'/trunk_options.lua')
local t={gateway_uuid=GATEWAY,limit=1,options={schema=1,allow_incoming=true,allow_outgoing=true,support_reinvite=true,srtp_mode=MODE,scope_department=''}}
local dial=T.leg(DOMAIN,t,'[origination_uuid='..OWNED..',process_cdr=false,no_cdr=true,absolute_codec_string=PCMA,leg_timeout=2]sofia/external/990099@127.0.0.1:PORT')
local s=freeswitch.Session('{originate_timeout=3,ignore_early_media=true}'..dial)
local ready=s:ready()
local cause=s:hangupCause()
if ready then s:hangup('NORMAL_CLEARING')end
stream:write('{"connected":'..tostring(ready)..'}')
'''
            prefix = '\n'.join('local '+key+'='+json.dumps(value) for key, value in {
                'STAGE': str(directory), 'GATEWAY': gateway, 'MODE': mode,
                'DOMAIN': domain, 'OWNED': identifier}.items())
            script = directory/'run.lua'
            script.write_text(prefix+'\n'+source.replace('PORT', str(peer.port)))
            script.chmod(0o644)
            result = json.loads(api('lua '+str(script)))
            deadline = time.monotonic()+2
            while len(peer.invites) == before and time.monotonic() < deadline:
                time.sleep(.02)
            assert len(peer.invites) == before+1, 'Owned provider did not receive exactly one INVITE'
            offer = peer.invites[-1]['sdp']
            crypto = 'a=crypto:' in offer
            secure_profile = 'RTP/SAVP' in offer
            assert result['connected'] == (mode != 'required'), 'Provider audio policy was not enforced'
            if mode == 'disabled':
                assert not crypto and not secure_profile, 'Disabled SRTP offered encryption'
            if mode in ('optional', 'required'):
                assert crypto, 'Secure provider policy offered no SRTP key'
            if mode == 'required':
                assert secure_profile, 'Mandatory SRTP did not require secure media'
            assert api('limit_usage hash openweb-trunk-'+domain+' '+gateway) == '0', 'Provider attempt leaked capacity'
            facts.append({'mode': mode, 'connected_to_plain_peer': result['connected'],
                          'offered_srtp': crypto, 'required_secure_profile': secure_profile,
                          'slot_released': True})
        print(json.dumps({'actual_native_sip': True, 'cases': facts,
                          'customer_calls': False, 'sdp_or_keys_published': False}, indent=2))
    finally:
        for identifier in owned:
            if api('uuid_exists '+identifier) == 'true':
                api('uuid_kill '+identifier+' NORMAL_CLEARING')
        peer.close()
        shutil.rmtree(directory)


if __name__ == '__main__':
    main()
