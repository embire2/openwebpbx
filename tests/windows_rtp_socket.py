#!/usr/bin/env python3
"""Exact fixture adapter checks, including real Windows UDP reset/recovery."""
import ast
import json
import os
from pathlib import Path
import socket
import time
import types

path=Path(__file__).with_name('windows-native-acceptance.py')
tree=ast.parse(path.read_text())
nodes=[node for node in tree.body if isinstance(node,ast.ClassDef) and node.name=='WindowsRtpSocket']
assert len(nodes)==1
namespace={'os':os}
exec(compile(ast.Module(body=nodes,type_ignores=[]),str(path),'exec'),namespace)
adapter=namespace['WindowsRtpSocket'];checks=0
def check(value):
    global checks
    assert value;checks+=1

class FakeSocket:
    def __init__(self,error):self.error=error
    def recv(self,*args,**kwargs):raise self.error

def expect_exact(error,platform):
    namespace['os']=types.SimpleNamespace(name=platform)
    try:adapter(FakeSocket(error)).recv(4096)
    except BaseException as actual:check(actual is error)
    else:raise AssertionError('An unrelated socket failure was hidden')

error=ConnectionResetError('owned synthetic Windows port unreachable');error.winerror=10054
namespace['os']=types.SimpleNamespace(name='nt')
try:adapter(FakeSocket(error)).recv(4096)
except BlockingIOError as actual:check(actual.__cause__ is error)
else:raise AssertionError('Exact Windows UDP report stopped the receiver')
expect_exact(error,'posix')
for code in (10050,10051,10053,10055,10061):
    other=ConnectionResetError('owned other Windows condition');other.winerror=code
    expect_exact(other,'nt')
expect_exact(ConnectionResetError('no Windows error code'),'nt')
expect_exact(OSError('non-reset failure'),'nt')
namespace['os']=os

def actual_udp(recover):
    raw=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);raw.bind(('127.0.0.1',0));raw.setblocking(False)
    endpoint=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);endpoint.bind(('127.0.0.1',0))
    address=endpoint.getsockname();endpoint.close()
    reader=adapter(raw) if recover else raw
    try:
        raw.sendto(b'owned-before-port-open',address)
        saw_reset=False;deadline=time.monotonic()+2
        while time.monotonic()<deadline:
            try:reader.recv(4096)
            except ConnectionResetError as error:
                check(os.name=='nt' and error.winerror==10054);saw_reset=True;break
            except BlockingIOError as error:
                if isinstance(error.__cause__,ConnectionResetError):
                    check(recover and error.__cause__.winerror==10054);saw_reset=True;break
                if os.name!='nt':break
            time.sleep(.005)
        if os.name=='nt':check(saw_reset)
        if not recover:return saw_reset
        endpoint=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);endpoint.bind(address);endpoint.settimeout(1)
        payloads=[bytes([n])*172 for n in range(1,17)]
        for payload in payloads:
            reader.sendto(payload,address);received,peer=endpoint.recvfrom(4096)
            check(received==payload and peer==raw.getsockname())
            endpoint.sendto(received,peer)
            deadline=time.monotonic()+1
            while True:
                try:received=reader.recv(4096);break
                except BlockingIOError:
                    if time.monotonic()>=deadline:raise
                    time.sleep(.005)
            check(received==payload)
        check(reader.getsockname()==raw.getsockname())
        return saw_reset
    finally:endpoint.close();raw.close()

old=actual_udp(False);new=actual_udp(True)
check(os.name!='nt' or old and new)
print(json.dumps({'state':'passed','checks':checks,'platform':os.name,'actual_windows_old_reset':old if os.name=='nt' else False,'actual_windows_receiver_recovered':new if os.name=='nt' else False,'two_way_datagrams':16,'pbx_touched':False}))
