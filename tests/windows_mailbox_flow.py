#!/usr/bin/env python3
"""Actual mailbox Lua dispatch, framed ESL observer and RFC2833 loopback controls.

No PBX, database, owner machine or external network is used.
"""
import importlib.util
import json
import re
import socket
import struct
import subprocess
import tempfile
import threading
import time
import xml.etree.ElementTree as ET
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'tests' / file)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


native = module('mailbox_native', 'windows-native-acceptance.py')
source = module('mailbox_phone', 'pbx_v20_restore_native.py')
checks = 0


def check(value):
    global checks
    assert value
    checks += 1


voice = ROOT / 'app/switch/resources/scripts/app/voicemail'
index = (voice / 'index.lua').read_text()
dispatch = re.search(r'if \(voicemail_tutorial == "true"\) then\s+tutorial\("intro"\);\s+else\s+main_menu\(\);\s+end', index).group()
check("'voicemail_tutorial'=>true" in (ROOT / 'resources/classes/pbx_setup_provisioner.php').read_text())
xml = ROOT / 'app/switch/resources/conf/languages/en/vm'


def phrase(file, macro):
    node = ET.parse(xml / file).find(".//macro[@name='" + macro + "']")
    return node.find(".//action[@function='play-file']").get('data')


password_path = phrase('sounds.xml', 'voicemail_enter_pass')
tutorial_path = phrase('voicemail.xml', 'tutorial_intro')
menu_path = phrase('voicemail.xml', 'voicemail_main_menu')
check(password_path.endswith('vm-enter_pass.wav') and tutorial_path.endswith('vm-tutorial_yes_no.wav') and menu_path.endswith('vm-listen_new.wav'))
check(phrase('sounds.xml', 'voicemail_forward_message_enter_extension').endswith('vm-forward_enter_ext.wav'))
check(phrase('sounds.xml', 'voicemail_forward_prepend').endswith('vm-forward_add_intro.wav'))


def lua_flow(pin='12', digit='2', tutorial=True):
    # Execute the actual password check, dispatch branch and tutorial function.
    # The DB/session adapters expose only fictional scoped rows and native APIs.
    script = r'''
debug={};domain_uuid='00000000-0000-4000-a000-000000000009';voicemail_id='8103';voicemail_tutorial=arg[3]
password_tries=0;max_timeouts=3;timeouts=0;local auth=0;local intros=0;local updates=0;local menus=0
session={ready=function()return true end,flushDigits=function()end,
 playAndGetDigits=function(_,minimum,maximum,tries,timeout,terminators,prompt)
  if prompt=='phrase:voicemail_enter_pass:#' then auth=auth+1;assert(minimum==2 and maximum==20 and terminators=='#');return arg[1] end
  assert(prompt=='phrase:tutorial_intro' and maximum==1 and timeout==3000);intros=intros+1;return arg[2]
 end,
 execute=function()error('Authentication must succeed before any tutorial')end,
 hangup=function()error('The owned mailbox unexpectedly hung up')end}
dbh={query=function(_,sql,params,callback)
 assert(params.domain_uuid==domain_uuid and params.voicemail_id=='8103' and sql:find('voicemail_enabled = true',1,true))
 if callback then callback({voicemail_uuid='11111111-1111-4111-8111-111111111111',voicemail_password='12'})
 else assert(sql:find('set voicemail_tutorial = false',1,true));updates=updates+1 end
end}
main_menu=function()menus=menus+1 end
assert(loadfile('app/switch/resources/scripts/app/voicemail/resources/functions/check_password.lua'))()
assert(loadfile('app/switch/resources/scripts/app/voicemail/resources/functions/tutorial.lua'))()
check_password(voicemail_id,password_tries)
''' + dispatch + r'''
assert(auth==1 and menus==1)
print(string.format('{"password_checked":true,"tutorial_reads":%d,"updates":%d,"menus":%d}',intros,updates,menus))
'''
    with tempfile.TemporaryDirectory(prefix='openweb-mailbox-lua-') as folder:
        file = Path(folder) / 'flow.lua'
        file.write_text(script)
        result = subprocess.run(['lua5.4', str(file), pin, digit, 'true' if tutorial else 'false'],
                                cwd=ROOT, capture_output=True, text=True, check=True)
        return json.loads(result.stdout)


check(lua_flow() == {'password_checked': True, 'tutorial_reads': 1, 'updates': 1, 'menus': 1})
check(lua_flow(digit='')['tutorial_reads'] == 3)  # Old unhandled tutorial retries the real intro.
check(lua_flow(tutorial=False)['tutorial_reads'] == 0)
try:
    lua_flow(pin='99')
except subprocess.CalledProcessError:
    check(True)
else:
    raise AssertionError('A wrong PIN reached the tutorial/main menu')

CALL = 'a' * 24 + '@localfixture'
REALM = 'mailbox-flow.invalid'
RECORDING = 'msg_11111111-1111-4111-8111-111111111111.wav'


def frame(event, content_type='text/event-plain'):
    body = ''.join(key + ': ' + value.replace(' ', '%20') + '\n' for key, value in event.items()).encode() + b'\n'
    return ('Content-Type: ' + content_type + '\nContent-Length: ' + str(len(body)) + '\n\n').encode() + body


def event(path, **changes):
    return {'Event-Name': 'PLAYBACK_START', 'variable_domain_name': REALM,
            'variable_sip_call_id': CALL, 'Playback-File-Path': 'C:\\Program Files\\FreeSWITCH\\sounds\\' + path.replace('/', '\\')} | changes


def event_peer(action):
    server = socket.socket()
    server.bind(('127.0.0.1', 0))
    server.listen()
    server.settimeout(5)
    errors = []

    def serve():
        client = None
        try:
            client, _ = server.accept()
            client.settimeout(8)
            client.sendall(b'Content-Type: auth/request\n\n')
            for expected in (b'auth fictional-secret', b'event plain PLAYBACK_START'):
                request = b''
                while b'\n\n' not in request:
                    part = client.recv(4096)
                    assert part
                    request += part
                assert request.strip() == expected
                client.sendall(b'Content-Type: command/reply\nReply-Text: +OK accepted\n\n')
            action(client)
            client.recv(1)  # The owned observer's close completes the fixture.
        except BaseException as error:
            errors.append(error)
        finally:
            if client:
                client.close()

    thread = threading.Thread(target=serve)
    thread.start()
    observer = native.NativePlayback({'host': '127.0.0.1', 'port': server.getsockname()[1], 'password': 'fictional-secret'}, REALM)
    return observer, thread, server, errors


def close_peer(observer, thread, server, errors):
    observer.close()
    thread.join(10)
    server.close()
    check(not thread.is_alive())
    if errors:
        raise errors[0]


def wire_flow(fresh):
    receiver = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    receiver.bind(('127.0.0.1', 0))
    receiver.settimeout(5)
    phone = source.SourcePhone({'number': '8103', 'auth': 'fictional-mailbox', 'password': 'fictional-secret'}, REALM, '127.0.0.1')
    media = phone.media()
    media['target'] = receiver.getsockname()
    phone.dialogs[CALL] = media
    call = {'callid': CALL, 'media': media, 'text': 'SIP/2.0 200 OK\r\n\r\nm=audio 1 RTP/AVP 0 101\r\na=rtpmap:101 telephone-event/8000\r\n'}
    while True:
        packet, _ = receiver.recvfrom(4096)
        if packet[1] & 127 == 0:
            break
    wire = [];wire_seen = set()

    def digits(count):
        until = time.monotonic() + 7
        out = ''
        while len(out) < count and time.monotonic() < until:
            packet, _ = receiver.recvfrom(4096)
            if len(packet) != 16 or packet[1] & 127 != 101:
                continue
            number, end, duration = struct.unpack('!BBH', packet[12:])
            ident = (struct.unpack('!I', packet[4:8])[0], number)
            if end & 128 and ident not in wire_seen:
                assert ident[0] > 0 and duration == 1600
                wire_seen.add(ident)
                out += '0123456789*#'[number]
        assert len(out) == count
        wire.extend(out)
        return out

    def serve(client):
        # An event can precede the waiter. Fragment the actual framed response,
        # retaining percent decoding, Windows paths and both ownership filters.
        client.sendall(frame(event('foreign.wav', variable_domain_name='foreign.invalid')))
        client.sendall(frame(event('wrong-call.wav', variable_sip_call_id='b' * 24 + '@localfixture')))
        first = frame(event(password_path))
        client.sendall(first[:7]);client.sendall(first[7:19]);client.sendall(first[19:])
        pin = digits(3)
        assert pin == '12#'
        if fresh:
            client.sendall(frame(event(tutorial_path)))
            skip = digits(1)
            assert skip == '2'
        else:
            skip = ''
        result = lua_flow(pin=pin[:-1], digit=skip, tutorial=fresh)
        assert result['password_checked'] and result['menus'] == 1
        client.sendall(frame(event(menu_path)))

    observer, thread, server, errors = event_peer(serve)
    flags = {}
    fixture = SimpleNamespace()
    try:
        index = native.mailbox_menu(fixture, observer, phone, call, '12', flags)
        check(index >= 0 and flags['mailbox_pin_sent'])
        check(bool(flags.get('mailbox_tutorial_skip_sent')) == fresh)
        check(wire == list('12#2' if fresh else '12#'))
        facts = observer.snapshot(CALL, RECORDING)
        check(facts['mailbox_owned_call_seen'] and facts['mailbox_owned_domain_matches'] and facts['mailbox_owned_path_header_present'])
        check(facts['mailbox_prompt_password_seen'] and facts['mailbox_prompt_main_menu_seen'] and facts['mailbox_prompt_tutorial_seen'] == fresh)
        check(facts['mailbox_observed_event_count'] == facts['mailbox_owned_event_count'] + 1)
        check(facts['mailbox_owned_event_count'] == facts['mailbox_matched_event_count'] + 1)
        check(all(type(value) in (int, bool) for value in facts.values()))
        check(not any(value in json.dumps(facts) for value in (CALL, REALM, 'Program Files', 'fictional-secret', RECORDING)))
    finally:
        close_peer(observer, thread, server, errors)
        media['ended'] = True
        phone.close()
        receiver.close()


wire_flow(True)
wire_flow(False)

# The old waiter ignores the actual fresh-mailbox tutorial prompt entirely.
observer, thread, server, errors = event_peer(lambda client: client.sendall(frame(event(tutorial_path))))
try:
    try:
        observer.prompt(CALL, ['vm-listen_new.wav'], seconds=.12)
    except AssertionError:
        facts = observer.snapshot(CALL, RECORDING)
        check(facts['mailbox_prompt_tutorial_seen'] and not facts['mailbox_prompt_main_menu_seen'])
    else:
        raise AssertionError('The unhandled tutorial was mistaken for a main menu')
finally:
    close_peer(observer, thread, server, errors)

# Actual frame parsing must not let wrong/missing ownership or path headers
# satisfy a prompt. Diagnostic facts reveal only bounded counts and booleans.
for changed, removed in [({'variable_domain_name': 'foreign.invalid'}, None), ({}, 'variable_domain_name'),
                         ({'variable_sip_call_id': 'b' * 24 + '@localfixture'}, None), ({}, 'variable_sip_call_id'),
                         ({'Event-Name': 'PLAYBACK_STOP'}, None), ({}, 'Playback-File-Path')]:
    record = event(password_path, **changed)
    if removed:
        record.pop(removed)
    observer, thread, server, errors = event_peer(lambda client: client.sendall(frame(record)))
    try:
        try:
            native.mailbox_prompt(SimpleNamespace(), observer, {'callid': CALL}, 'mailbox_login_prompt', ['vm-enter_pass.wav'], seconds=.12)
        except AssertionError as error:
            check(error.native_failure['primary_substage'] == 'mailbox_login_prompt')
        else:
            raise AssertionError('A foreign/malformed event satisfied the mailbox prompt')
        facts = observer.snapshot(CALL, RECORDING)
        check(not facts['mailbox_prompt_password_seen'])
        check(facts['mailbox_observed_event_count'] == 1)
        if removed == 'variable_domain_name':
            check(not facts['mailbox_owned_domain_header_present'])
        if removed == 'Playback-File-Path':
            check(not facts['mailbox_owned_path_header_present'])
        if removed == 'variable_sip_call_id':
            check(facts['mailbox_realm_event_count'] == 1 and not facts['mailbox_realm_call_id_header_present'])
    finally:
        close_peer(observer, thread, server, errors)

for payload in (b'Content-Type: text/event-plain\nContent-Length: 1048577\n\n',
                frame(event(password_path)).replace(b'PLAYBACK_START', b'\xffLAYBACK_START')):
    observer, thread, server, errors = event_peer(lambda client: client.sendall(payload))
    try:
        try:
            native.mailbox_prompt(SimpleNamespace(), observer, {'callid': CALL}, 'mailbox_login_prompt', ['vm-enter_pass.wav'], seconds=.2)
        except (AssertionError, UnicodeDecodeError) as error:
            check(error.native_failure['primary_substage'] == 'mailbox_login_prompt')
        else:
            raise AssertionError('A malformed/oversized native frame qualified')
        check(observer.snapshot(CALL, RECORDING)['mailbox_observer_failed'])
    finally:
        close_peer(observer, thread, server, errors)

observer, thread, server, errors = event_peer(lambda client: client.sendall(frame(event(password_path)) * 1001))
try:
    end = time.monotonic() + 2
    while observer.error is None and time.monotonic() < end:
        time.sleep(.005)
    facts = observer.snapshot(CALL, RECORDING)
    check(facts['mailbox_observer_failed'] and facts['mailbox_observed_event_count'] == 1000)
    check(facts['mailbox_owned_event_count'] == 1000 and facts['mailbox_matched_event_count'] == 1000)
finally:
    close_peer(observer, thread, server, errors)

for stage in native.MAILBOX_STAGES - {'mailbox_observer_close'}:
    primary = AssertionError('PRIVATE_PROMPT_PATH_AND_PIN')
    try:
        native.mailbox_step(SimpleNamespace(), stage, lambda: (_ for _ in ()).throw(primary))
    except AssertionError as error:
        check(error is primary and error.native_failure['primary_substage'] == stage)
        native.native_cleanup(error, stage, [('mailbox_observer_close', lambda: (_ for _ in ()).throw(RuntimeError('PRIVATE_CLOSE')))])
        check(error.native_failure['primary_substage'] == stage and error.native_failure['cleanup_substage'] == 'mailbox_observer_close')
        check('PRIVATE_' not in json.dumps(error.native_failure))

# Prove the tutorial handling consumes the existing menu budget, not a new wait.
clock = [1000.0]
seen = []


class MenuObserver:
    def prompt(self, callid, suffixes, after, seconds):
        seen.append(seconds)
        clock[0] += 5
        return len(seen), ['vm-enter_pass.wav', 'vm-tutorial_yes_no.wav', 'vm-listen_new.wav'][len(seen)-1]


class MenuPhone:
    def dtmf(self, call, digit):
        clock[0] += 1


with patch.object(native.time, 'monotonic', side_effect=lambda: clock[0]):
    native.mailbox_menu(SimpleNamespace(), MenuObserver(), MenuPhone(), {'callid': CALL}, '12', {})
check(seen == [30, 30, 24])
check(native.mailbox_prompt.__defaults__ == (-1, 30))
print(f'PASS {checks} actual mailbox Lua/auth/tutorial, loopback framed-event/RFC2833, ownership/header/frame bounds, deadline and primary/cleanup controls; no PBX contacted')
