#!/usr/bin/env python3
"""Actual loopback TCP/child-PHP protocol negatives; no native PBX mutation."""
from pathlib import Path
import json,os,socket,subprocess,threading,time
ROOT=Path(__file__).resolve().parents[1]
PHP=os.environ.get('OPENWEB_LISTENER_TEST_PHP','php')
def one(kind):
    server=socket.socket();server.bind(('127.0.0.1',0));server.listen(1);port=server.getsockname()[1];errors=[]
    def serve():
        try:
            client,_=server.accept()
            with client:
                client.settimeout(3)
                if kind=='wrong_hello':client.sendall(b'Content-Type: api/response\n\n');return
                client.sendall(b'Content-Type: auth/request\n\n')
                def read():
                    raw=b''
                    while not raw.endswith(b'\n\n'):
                        raw+=client.recv(1)
                        if len(raw)>2048:raise AssertionError('oversized client command')
                    return raw
                assert read()==b'auth fixture-secret\n\n'
                if kind=='auth_refused':client.sendall(b'Content-Type: command/reply\nReply-Text: -ERR invalid\n\n');return
                client.sendall(b'Content-Type: command/reply\nReply-Text: +OK accepted\n\n')
                assert read()==b'api sofia status profile internal\n\n'
                body=b'fixture bounded result\n'
                if kind=='passed':
                    wire=b'Content-Type: api/response\nContent-Length: '+str(len(body)).encode()+b'\n\n'+body
                    for offset in range(0,len(wire),3):client.sendall(wire[offset:offset+3])
                elif kind=='duplicate_length':client.sendall(b'Content-Type: api/response\nContent-Length: 0\nContent-Length: 0\n\n')
                elif kind=='oversized':client.sendall(b'Content-Type: api/response\nContent-Length: 262145\n\n')
                elif kind=='truncated':client.sendall(b'Content-Type: api/response\nContent-Length: 30\n\nshort')
                elif kind=='wrong_type':client.sendall(b'Content-Type: command/reply\n\n')
                elif kind=='fractional':client.sendall(b'Content-Type: api/response\nContent-Length: 2.5\n\n')
                elif kind=='oversized_header':client.sendall(b'X: '+b'x'*8193+b'\n\n')
                elif kind=='stalled':time.sleep(2.3)
        except (BrokenPipeError,ConnectionResetError):pass
        except BaseException as error:errors.append(error)
        finally:server.close()
    thread=threading.Thread(target=serve);thread.start();start=time.monotonic()
    result=subprocess.run([PHP,ROOT/'tests/windows_public_listener_esl.php',str(port)],capture_output=True,text=True,timeout=7)
    thread.join(4);assert not thread.is_alive() and not errors,errors
    assert (result.returncode==0)==(kind=='passed') and result.stdout.strip()==('passed' if kind=='passed' else 'refused'),kind
    assert time.monotonic()-start<6
for kind in ['passed','wrong_hello','auth_refused','duplicate_length','oversized','truncated','wrong_type','fractional','oversized_header','stalled']:one(kind)
print(json.dumps({'schema':1,'state':'passed','checks':10,'actual_loopback_tcp':True,'actual_php_child':True,'native_pbx_or_firewall_mutation':False}))
