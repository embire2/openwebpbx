#!/usr/bin/env python3
"""Finite, private, size-bounded call/media events. Never records SIP or audio."""
import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import socket
import stat
import subprocess
import time

CONFIG = Path('/etc/fusionpbx/call-diagnostics.json')
LOG = Path('/var/log/openwebpbx-call-diagnostics/events.jsonl')
EVENTS = ('CHANNEL_CREATE CHANNEL_PROGRESS CHANNEL_PROGRESS_MEDIA CHANNEL_CALLSTATE '
          'CHANNEL_EXECUTE CHANNEL_EXECUTE_COMPLETE CHANNEL_ANSWER CHANNEL_BRIDGE '
          'CHANNEL_UNBRIDGE CHANNEL_HANGUP_COMPLETE CODEC RECORD_START RECORD_STOP CUSTOM openweb::call_trace')
UUID = re.compile(r'[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}\Z')
TOKEN = re.compile(r'[A-Za-z0-9_.:@/-]{1,160}\Z')
FIELDS = {
    'Channel-State': 'state', 'Channel-Call-State': 'call_state',
    'Call-Direction': 'direction', 'Caller-Context': 'context',
    'Application': 'application', 'Hangup-Cause': 'cause',
    'variable_sofia_profile_name': 'profile', 'variable_call_direction': 'call_direction',
    'variable_read_codec': 'read_codec', 'variable_write_codec': 'write_codec',
    'variable_originate_disposition': 'originate_result',
    'variable_last_bridge_proto_specific_hangup_cause': 'bridge_sip_result',
    'variable_sip_invite_failure_status': 'sip_failure',
    'variable_openweb_pbx_delivers_audio': 'pbx_delivers_audio',
    'variable_bypass_media': 'bypass_media', 'variable_proxy_media': 'proxy_media',
    'variable_bypass_media_after_bridge': 'bypass_after_bridge',
    'variable_rtp_secure_media': 'rtp_secure_media', 'variable_sip_transport': 'transport',
    'variable_sip_nat_detected': 'nat_detected',
    'OpenWeb-Stage': 'stage', 'OpenWeb-Mode': 'mode',
    'OpenWeb-Registered': 'registered', 'OpenWeb-Mobile': 'mobile',
    'OpenWeb-Cause': 'route_cause', 'OpenWeb-PBX-Audio': 'pbx_delivers_audio',
    'OpenWeb-Strategy': 'ring_strategy', 'OpenWeb-Open': 'office_open', 'OpenWeb-Holiday': 'holiday',
}
NUMBERS = {'Caller-Destination-Number': 'destination', 'Caller-Caller-ID-Number': 'caller',
           'variable_sip_to_user': 'to_number', 'variable_sip_req_user': 'request_number',
           'OpenWeb-Caller': 'logical_caller', 'OpenWeb-Target': 'target'}
IDS = {'Unique-ID': 'uuid', 'Other-Leg-Unique-ID': 'other_leg_uuid',
       'variable_originating_leg_uuid': 'originating_uuid', 'variable_domain_uuid': 'domain_uuid',
       'variable_provider_uuid': 'provider_uuid', 'OpenWeb-Rule': 'rule_uuid'}


def masked(value):
    if not isinstance(value, str) or not re.fullmatch(r'\+?[0-9*#]{1,32}', value):
        return None
    return value if len(value) <= 6 else '***' + value[-4:]


def project(event, domains=None):
    """Positive allowlist: unknown fields, SIP auth, SDP and DTMF never persist."""
    kind = event.get('Event-Name')
    if kind not in EVENTS.split() or (kind == 'CUSTOM' and event.get('Event-Subclass') != 'openweb::call_trace'):
        return None
    if domains is not None and event.get('variable_domain_uuid') not in domains:
        return None
    result = {'observed_at': time.time(), 'event': kind}
    for source, target in IDS.items():
        value = event.get(source)
        if isinstance(value, str) and UUID.fullmatch(value):
            result[target] = value
    for source, target in FIELDS.items():
        value = event.get(source)
        if isinstance(value, str) and TOKEN.fullmatch(value):
            result[target] = value
    for source, target in NUMBERS.items():
        value = masked(event.get(source))
        if value is not None:
            result[target] = value
    cid = event.get('variable_sip_call_id')
    if isinstance(cid, str) and len(cid) <= 512:
        result['sip_call_hash'] = hashlib.sha256(cid.encode()).hexdigest()[:24]
    for name in ('sip_network_ip', 'local_media_ip', 'remote_media_ip', 'advertised_media_ip'):
        try:
            result[name] = str(ipaddress.ip_address(event['variable_' + name]))
        except (KeyError, ValueError, TypeError):
            pass
    for name in ('sip_network_port', 'local_media_port', 'remote_media_port', 'read_rate',
                 'write_rate', 'rtp_audio_in_packet_count', 'rtp_audio_out_packet_count',
                 'rtp_audio_in_skip_packet_count', 'rtp_audio_in_jitter_packet_count',
                 'rtp_audio_in_flaw_total', 'rtp_audio_in_mos', 'duration', 'billsec'):
        value = event.get('variable_' + name)
        if isinstance(value, str) and re.fullmatch(r'[0-9]{1,18}(?:\.[0-9]{1,8})?', value):
            result[name] = value
    if str(event.get('Event-Date-Timestamp', '')).isdigit():
        result['engine_timestamp_us'] = str(event['Event-Date-Timestamp'])[:20]
    trunk = event.get('OpenWeb-Trunk')
    if isinstance(trunk, str) and re.fullmatch(r'(?:[0-9]{1,10}|ow-[a-f0-9]{12})', trunk):
        result['trunk'] = trunk
    for source, target in (('OpenWeb-Eligible', 'eligible_members'), ('OpenWeb-Timeout', 'ring_timeout')):
        value = event.get(source)
        if isinstance(value, str) and re.fullmatch(r'[0-9]{1,6}', value):
            result[target] = value
    return result


def secure_path(path, directory=False):
    for parent in (path, *path.parents):
        if parent.is_symlink():
            raise ValueError('Linked diagnostic paths are refused.')
    s = path.stat()
    if s.st_uid != 0 or stat.S_IMODE(s.st_mode) & 0o077 or not (stat.S_ISDIR(s.st_mode) if directory else stat.S_ISREG(s.st_mode)):
        raise ValueError('Diagnostics require a private root-owned path.')


class Journal:
    def __init__(self, path=LOG, limit=5 * 1024 * 1024, copies=4):
        self.path, self.limit, self.copies = path, limit, copies
        path.parent.mkdir(mode=0o700, exist_ok=True)
        secure_path(path.parent, True)

    def write(self, record):
        data = (json.dumps(record, separators=(',', ':'), ensure_ascii=True) + '\n').encode()
        if self.path.exists():
            secure_path(self.path)
            if self.path.stat().st_size + len(data) > self.limit:
                for index in range(self.copies, 0, -1):
                    src = self.path if index == 1 else self.path.with_name(self.path.name + '.' + str(index - 1))
                    dst = self.path.with_name(self.path.name + '.' + str(index))
                    if src.exists():
                        secure_path(src)
                        if dst.exists():
                            secure_path(dst)
                        os.replace(src, dst)
        fd = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
        try:
            os.write(fd, data)
        finally:
            os.close(fd)


class Frames:
    def __init__(self, sock):
        self.sock, self.buffer = sock, b''

    def receive(self):
        while b'\n\n' not in self.buffer:
            self.more()
            if len(self.buffer) > 65536:
                raise ValueError('Oversized event header.')
        header, rest = self.buffer.split(b'\n\n', 1)
        values = dict(line.split(': ', 1) for line in header.decode().splitlines() if ': ' in line)
        size = int(values.get('Content-Length', '0'))
        if not 0 <= size <= 2 * 1024 * 1024:
            raise ValueError('Oversized event.')
        offset = len(header) + 2
        while len(self.buffer) < offset + size:
            self.more()
        body, self.buffer = self.buffer[offset:offset + size], self.buffer[offset + size:]
        return values, body

    def more(self):
        chunk = self.sock.recv(65536)
        if not chunk:
            raise ConnectionError('Event socket closed.')
        self.buffer += chunk


def collect(config):
    expires = config['expires_at']
    if not isinstance(expires, (int, float)) or expires > time.time() + 86400:
        raise ValueError('Diagnostic expiry must be within 24 hours.')
    host = config['host']
    if not ipaddress.ip_address(host).is_loopback:
        raise ValueError('Diagnostics only connect to a local engine.')
    domains = config.get('domains')
    if domains is not None and (not domains or any(not UUID.fullmatch(x) for x in domains)):
        raise ValueError('Invalid tenant diagnostic scope.')
    password = config['password']
    if not isinstance(password, str) or not password or any(x in password for x in '\r\n\x00'):
        raise ValueError('Invalid event authentication configuration.')
    journal = Journal()
    journal.write({'event': 'diagnostics_started', 'expires_at': expires, 'all_domains': domains is None})
    while time.time() < expires:
        try:
            with socket.create_connection((host, int(config['port'])), timeout=3) as sock:
                frames = Frames(sock)
                if frames.receive()[0].get('Content-Type') != 'auth/request':
                    raise ValueError('Invalid event greeting.')
                sock.sendall(('auth ' + password + '\n\n').encode())
                if not frames.receive()[0].get('Reply-Text', '').startswith('+OK'):
                    raise ValueError('Event authentication failed.')
                sock.sendall(('event json ' + EVENTS + '\n\n').encode())
                if not frames.receive()[0].get('Reply-Text', '').startswith('+OK'):
                    raise ValueError('Event subscription failed.')
                while time.time() < expires:
                    try:
                        header, body = frames.receive()
                    except socket.timeout:
                        continue
                    if header.get('Content-Type') == 'text/event-json':
                        record = project(json.loads(body), domains)
                        if record:
                            journal.write(record)
        except (OSError, ConnectionError, ValueError, TypeError):
            journal.write({'event': 'diagnostics_reconnecting'})
            time.sleep(min(3, max(0, expires - time.time())))
    journal.write({'event': 'diagnostics_expired'})


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--enable', action='store_true')
    parser.add_argument('--minutes', type=int, default=60)
    scope = parser.add_mutually_exclusive_group()
    scope.add_argument('--all-domains', action='store_true')
    scope.add_argument('--domain')
    parser.add_argument('--web-root', default='/var/www/fusionpbx')
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise ValueError('Call diagnostics require root.')
    if args.enable:
        if not 1 <= args.minutes <= 1440 or not (args.all_domains or args.domain and UUID.fullmatch(args.domain)):
            raise ValueError('Choose a tenant or --all-domains and 1–1440 minutes.')
        root = Path(args.web_root).resolve(strict=True)
        if not (root / 'resources/require.php').is_file():
            raise ValueError('PBX web root is missing.')
        # No shell or credentials in process arguments/output. Bootstrap is
        # outside the sandboxed observer and only the captured JSON is stored.
        php = "require getcwd().'/resources/require.php';$c=config::load();echo json_encode(['host'=>$c->get('switch.event_socket.host',null)??$c->get('event_socket.ip_address',null)??'127.0.0.1','port'=>$c->get('switch.event_socket.port',null)??$c->get('event_socket.port',null)??8021,'password'=>$c->get('switch.event_socket.password',null)??$c->get('event_socket.password',null)??'ClueCon']);"
        config = json.loads(subprocess.check_output(['php', '-r', php], cwd=root, timeout=20))
        config.update(expires_at=time.time() + args.minutes * 60, domains=None if args.all_domains else [args.domain])
        if CONFIG.exists():
            secure_path(CONFIG)
        temporary = CONFIG.with_name('.call-diagnostics-' + str(os.getpid()))
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            os.write(fd, json.dumps(config).encode()); os.fsync(fd)
        finally:
            os.close(fd)
        os.replace(temporary, CONFIG)
        print('Private diagnostics configured for ' + str(args.minutes) + ' minutes. Start openwebpbx-call-diagnostics.service.')
    else:
        secure_path(CONFIG)
        collect(json.loads(CONFIG.read_text()))


if __name__ == '__main__':
    main()
