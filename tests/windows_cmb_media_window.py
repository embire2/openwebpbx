#!/usr/bin/env python3
"""Real loopback RTP tests for the exact Windows CMB observer body.

An owned relay supplies early prompt packets, a receive gap and a bridge. No
PBX, provider, identity, installed service or customer destination is used.
"""
import ast
import importlib.util
from pathlib import Path
import socket
import sys
import threading
import time

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


native = module('cmb_native_media_support', ROOT / 'windows-native-acceptance.py')
source = module('cmb_source_phone', ROOT / 'pbx_v20_restore_native.py')
checks = 0


def check(value):
    global checks
    assert value
    checks += 1


def wait(predicate, seconds=3):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.005)
    raise AssertionError('The owned loopback CMB media fixture did not become ready')


class LoopbackPhone(source.SourcePhone):
    def __init__(self, *args):
        self.receiver_failure = None
        super().__init__(*args)

    def run(self):
        try:
            super().run()
        except BaseException as error:
            self.receiver_failure = error

    def check_receiver(self):
        if self.receiver_failure is not None:
            raise self.receiver_failure
        assert self.thread.is_alive(), 'The owned loopback RTP receiver stopped'


relay = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
relay.bind(('127.0.0.1', 0))
relay.settimeout(.02)
phones = [LoopbackPhone({'number': str(9101+i), 'auth': 'fictional-cmb-window-'+str(i),
    'password': 'fictional-local-only', 'tone_hz': frequency}, 'cmb-window.invalid')
    for i, frequency in enumerate((440, 550))]
states = [phone.media() for phone in phones]
mode = {'kind': 'prompt', 'packets': 0}
stopped = threading.Event()
failures = []


def forward():
    try:
        while not stopped.is_set():
            try:
                packet, _ = relay.recvfrom(4096)
            except socket.timeout:
                continue
            mode['packets'] += 1
            kind = mode['kind']
            if kind == 'prompt' and mode['packets'] > 4:
                continue
            if kind == 'missing' or (kind == 'low' and mode['packets'] % 4):
                continue
            if kind == 'late' and time.monotonic() < mode['after']:
                continue
            if kind == 'stale' and time.monotonic() > mode['until']:
                continue
            if kind == 'silence':
                packet = packet[:12] + bytes([255]) * len(packet[12:])
            for _ in range(4 if kind == 'high' else 1):
                relay.sendto(packet, states[0]['socket'].getsockname())
    except BaseException as error:
        if not stopped.is_set():
            failures.append(error)


worker = threading.Thread(target=forward)


def observer(path, nested):
    tree = ast.parse(path.read_text())
    body = next(node for node in (ast.walk(tree) if nested else tree.body)
        if isinstance(node, ast.FunctionDef) and node.name == 'decoded')
    namespace = {'time': time, 'caller': phones[0], 'extension': phones[1],
        'providers': (), 'original': source, 'sip': source,
        'media_window': native.bridged_media_window}
    exec(compile(ast.Module(body=[body], type_ignores=[]), str(path), 'exec'), namespace)
    return namespace['decoded']


def drain_prior_phase():
    # Do not let a datagram already queued by the previous high-rate phase
    # become the next late-start phase's apparent first bridged packet.
    mode['kind'] = 'missing'
    wait(lambda: states[0]['received_last_at'] is not None and
        time.monotonic()-states[0]['received_last_at'] >= .08)


try:
    old = observer(ROOT / 'fixtures/windows-cmb-media-before-window.py', False)
    corrected = observer(ROOT / 'windows_native_services.py', True)
    worker.start()
    states[0]['target'] = states[1]['socket'].getsockname()
    states[1]['target'] = relay.getsockname()
    for phone, state in zip(phones, states):
        phone.dialogs['owned-cmb-media-window'] = state
    wait(lambda: states[0]['received'] >= 4 and states[1]['received'] >= 4)
    time.sleep(4.2)
    check(states[0]['received'] == 4)
    mode['kind'] = 'normal'
    # The old exact observer rejects genuine fresh 1.5s bridge media because
    # its rate includes the already-finished prompt/wait interval.
    try:
        old(states[0], states[1], 550, 440, 1.5)
    except AssertionError as error:
        check('RTP pacing' in str(error))
    else:
        raise AssertionError('The exact previous CMB observer mismatch was not reproduced')
    lifetime_rate = (states[0]['received']-1) / (states[0]['received_last_at']-states[0]['received_first_at'])
    check(lifetime_rate < 30)
    history = {key: states[0][key] for key in ('sent', 'received', 'sent_first_at', 'received_first_at')}
    down, up = corrected(states[0], states[1], 550, 440, 1.5)
    check(down >= .8 and up >= .8)
    check(states[0]['sent'] > history['sent'] and states[0]['received'] > history['received'])
    check(states[0]['sent_first_at'] == history['sent_first_at'] and states[0]['received_first_at'] == history['received_first_at'])
    for kind in ('missing', 'low', 'high', 'late', 'stale'):
        drain_prior_phase()
        mode['kind'] = kind
        if kind == 'late':
            mode['after'] = time.monotonic()+.4
        elif kind == 'stale':
            mode['until'] = time.monotonic()+.4
        try:
            corrected(states[0], states[1], 550, 440, 1.5)
        except AssertionError as error:
            value = error.media_failure
            check(value['media_peer'] == 'caller' and value['media_direction'] == 'received')
            check(value['media_window_seconds'] == 1.5)
            if kind == 'missing':
                check(value['media_packets'] == 0)
            elif kind == 'low':
                check(value['media_rate_pps'] < 30)
            elif kind == 'high':
                check(value['media_rate_pps'] > 70)
            elif kind == 'late':
                check('did not begin' in str(error))
            else:
                check('stopped before' in str(error))
            check('start_counts' in error.media_window_private)
        else:
            raise AssertionError('Invalid actual CMB bridge RTP was accepted: '+kind)
    drain_prior_phase()
    mode['kind'] = 'silence'
    try:
        corrected(states[0], states[1], 550, 440, 1.5)
    except AssertionError as error:
        check('silent' in str(error))
    else:
        raise AssertionError('Paced silent RTP passed the exact CMB tone assertion')
    drain_prior_phase()
    mode['kind'] = 'normal'
    try:
        corrected(states[0], states[1], 440, 440, 1.5)
    except AssertionError as error:
        check('tone did not cross' in str(error))
    else:
        raise AssertionError('Wrong decoded CMB tone was accepted')
finally:
    stopped.set()
    for state in states:
        state['ended'] = True
    for phone in phones:
        phone.close()
    if worker.ident is not None:
        worker.join(3)
    relay.close()
check(not failures and not worker.is_alive() and all(not phone.thread.is_alive() for phone in phones))
print(f'PASS {checks} actual-loopback exact CMB observer controls; unchanged1.5s/.3s/30..70pps/.8tone/freshness; no PBX contacted')
print(f'Observed previous lifetime rate={lifetime_rate:.3f}pps; fresh bridge ratios={down:.4f}/{up:.4f}; historical Windows8a rate remains unknown')
