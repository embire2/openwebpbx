#!/usr/bin/env python3
"""Exercise generated codec legs through the installed native parsers.

No engine initialization, SIP traffic, database access or customer data. The
bracket masking follows switch_ivr_originate.c; splitting and bracket/codec
decoding call the actual installed libfreeswitch functions. Run with Python 3
on a FreeSWITCH host. The legacy quoted list is a regression positive control.
"""
import ctypes
import ctypes.util
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
library = ctypes.util.find_library("freeswitch")
if not library:
    raise SystemExit("Native codec checks require installed libfreeswitch")
native = ctypes.CDLL(library)
pointer = ctypes.c_void_p
native.switch_separate_string.argtypes = [
    ctypes.c_char_p, ctypes.c_char, ctypes.POINTER(ctypes.c_char_p), ctypes.c_uint
]
native.switch_separate_string.restype = ctypes.c_uint
native.switch_event_create_brackets.argtypes = [
    ctypes.c_char_p, ctypes.c_char, ctypes.c_char, ctypes.c_char,
    ctypes.POINTER(pointer), ctypes.POINTER(pointer), ctypes.c_int
]
native.switch_event_create_brackets.restype = ctypes.c_int
native.switch_event_get_header_idx.argtypes = [pointer, ctypes.c_char_p, ctypes.c_int]
native.switch_event_get_header_idx.restype = ctypes.c_char_p
native.switch_event_destroy.argtypes = [ctypes.POINTER(pointer)]


def split(value, delimiter):
    buffer = ctypes.create_string_buffer(value)
    values = (ctypes.c_char_p * 64)()
    count = native.switch_separate_string(buffer, delimiter, values, len(values))
    return [values[i] for i in range(count)]


def brackets(value, left, right, delimiter):
    buffer = ctypes.create_string_buffer(value)
    event, remainder = pointer(), pointer()
    status = native.switch_event_create_brackets(
        buffer, left, right, delimiter, ctypes.byref(event),
        ctypes.byref(remainder), 0
    )
    assert status == 0 and remainder.value, "Native bracket parse failed"
    try:
        headers = {}
        for name in (b"absolute_codec_string", b"api_on_answer", b"leg_timeout",
                     b"originate_timeout", b"progress_timeout"):
            headers[name] = native.switch_event_get_header_idx(event, name, -1)
        return headers, ctypes.string_at(remainder)
    finally:
        native.switch_event_destroy(ctypes.byref(event))


def originate_variables(value):
    if value.startswith(b"{"):
        _, value = brackets(value, b"{", b"}", b",")
    # Native originate first splits pipe alternatives, stripping single quotes.
    alternatives = split(value, b"|")
    assert len(alternatives) == 1, "Unexpected extra alternative"
    value = alternatives[0]
    assert value.startswith(b"[")
    end = value.index(b"]")
    quote = False
    alternate = value.startswith(b"[^^")
    marked = bytearray(value)
    for index in range(1, end):
        char = marked[index]
        if char == ord("'"):
            quote = not quote
        if char == ord(",") and marked[index - 1] != ord("\\"):
            marked[index] = 3 if quote or alternate else 2
    peers = split(bytes(marked), b",")
    assert len(peers) == 1, "Codec list created extra call legs"
    peer = peers[0].replace(b"\x03", b",")
    headers, target = brackets(peer, b"[", b"]", b"\x02")
    assert target.startswith(b"sofia/"), "Provider target was corrupted"
    return headers


lua = r"""
local P=loadfile('app/pbx_setup/resources/switch/scripts/app/pbx_setup/policy.lua')()
local domain='00000000-0000-4000-a000-000000000009'
local trunk={gateway_uuid='00000000-0000-4000-a000-000000000001',main_number='+27210000001',
    host='provider.example.invalid',port=5060,codecs={'PCMU','PCMA','G729'},headers={}}
local route={strip=0,prepend='',caller_id=''}
local gateway={from_domain='provider.example.invalid',proxy='provider.example.invalid:5060',
    profile='external',register_transport='udp'}
local function emit(name,leg)assert(leg);io.write(name,'\t',leg,'\n')end
local function leg()return P.outbound_leg(trunk,route,'0123456789',{},'100',domain,'fixture.example.invalid',gateway)end
emit('gateway',leg())
trunk.headers.ContactUser='$OutboundCallerId'
emit('dynamic-contact',leg())
local tracked=P.track_answer(leg(),domain)
emit('tracked',tracked)
emit('ordinary','{originate_timeout=60,progress_timeout=60}'..tracked:gsub('^%[','[leg_timeout=60,',1))
emit('callback',tracked:gsub('^%[','[leg_timeout=45,',1))
"""
generated = subprocess.run(
    ["lua", "-"], input=lua, text=True, cwd=ROOT, check=True, capture_output=True
).stdout
checks = 0
for line in generated.splitlines():
    name, leg = line.split("\t", 1)
    variables = originate_variables(leg.encode())
    codec_string = variables[b"absolute_codec_string"]
    assert codec_string and split(codec_string, b",") == [b"PCMU", b"PCMA", b"G729"], name
    if name in {"tracked", "ordinary", "callback"}:
        assert variables[b"api_on_answer"] == (
            b"uuid_setvar 00000000-0000-4000-a000-000000000009 openweb_provider_answered true"
        ), name
    if name in {"ordinary", "callback"}:
        assert variables[b"leg_timeout"] == (b"60" if name == "ordinary" else b"45"), name
    checks += 1

old = b"[absolute_codec_string='PCMU,PCMA,G729']sofia/gateway/fixture/123"
assert originate_variables(old)[b"absolute_codec_string"] == b"PCMU", "Legacy control must expose lost codecs"
checks += 1
print(f"PASS: {checks} installed-native multi-stage codec/answer/timeout parser checks")
