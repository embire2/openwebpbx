#!/usr/bin/env python3
"""Exercise actual pinned WebSocket parser and historical negative on controlled reads.
No network, PBX state, installed files or credentials are accessed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ORIGINAL={'ws.c':'7c0b8b55cf4010e4dd3d4dd65dd91be06697e925026d8efc2d1a9425c7a946e7','ws.h':'34cf6c56abb87886bd909a2cb86f7b812d1f4613066cde490cf913cedfeefb12'}
PATCHED={'ws.c':'7e7d6a14f5426b6a18054107a4f3353cfb1569838ec88625beaa2b1d42296d55','ws.h':'98898e83103f7f7f499c58a2d702c5cd8f5dd35291827c6aa4881bb6289791bb'}


def digest(data):return hashlib.sha256(data).hexdigest()


def source_inputs(root):
    values={}
    for name,expected in PATCHED.items():
        path=root/name
        if path.is_symlink() or not path.is_file() or path.stat().st_size>1000000 or digest(path.read_bytes())!=expected:
            raise ValueError('The exact patched public parser sources are required.')
        values[name]=path.read_text(encoding='utf-8')
    baseline=dict(values)
    baseline['ws.c']=baseline['ws.c'].replace('int frag = wsh->fragmented;','int frag = 0;').replace(
        'if (!frag) {\n\t\twsh->body = wsh->bbuffer;\n\t\twsh->packetlen = 0;\n\t} else {\n\t\twsh->body = wsh->bbuffer + wsh->packetlen;\n\t}',
        'wsh->body = wsh->bbuffer;\n\twsh->packetlen = 0;').replace('wsh->buffer, 2, wsh->block','wsh->buffer, 9, wsh->block').replace('2 - wsh->datalen, WS_BLOCK','9 - wsh->datalen, WS_BLOCK').replace('\n\t\t\twsh->fragmented = frag;','')
    baseline['ws.h']=baseline['ws.h'].replace('\n\t/* Preserve a fragmented message across nonblocking readiness callbacks. */\n\tint fragmented;','')
    if {name:digest(value.encode()) for name,value in baseline.items()}!=ORIGINAL:
        raise ValueError('The historical parser reconstruction differs from its immutable source.')
    return baseline,values


def harness(values):
    source=values['ws.c'];header=values['ws.h']
    function=source[source.index('ssize_t ws_read_frame('):source.index('\nssize_t ws_write_frame(',source.index('ssize_t ws_read_frame('))]
    blocking=source[source.index('static ssize_t ws_raw_read_blocking('):source.index('\nssize_t ws_raw_write(',source.index('static ssize_t ws_raw_read_blocking('))]
    structure=header[header.index('typedef struct wsh_s {'):header.index('} wsh_t;')+len('} wsh_t;')]
    return COMMON+structure+'\n'+STUBS+'\n'+blocking+'\n'+function+'\n'+CASES


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--sanitize',action='store_true')
    args=parser.parse_args()
    if args.output.exists() or args.output.is_symlink():raise ValueError('Use a new owned test output.')
    baseline,patched=source_inputs(args.source_root)
    compiler=shutil.which('cl.exe' if os.name=='nt' else 'cc')
    if not compiler:raise ValueError('A native C compiler is required.')
    args.output.mkdir(parents=True)
    records={}
    for label,values in [('original',baseline),('patched',patched)]:
        c=args.output/(label+'.c');c.write_text(harness(values),encoding='utf-8')
        binary=args.output/(label+('.exe' if os.name=='nt' else ''))
        if os.name=='nt':
            if args.sanitize:raise ValueError('The reviewed sanitizer path is the portable compiler.')
            command=[compiler,'/nologo','/O2','/MD','/W4',str(c),'/Fe:'+str(binary),'/Fo:'+str(args.output/(label+'.obj')),'/link','ws2_32.lib']
        else:
            command=[compiler,'-std=c11','-g','-O1','-o',str(binary),str(c)]
            if args.sanitize:command[1:1]=['-fsanitize=address,undefined','-fno-omit-frame-pointer']
        compiled=subprocess.run(command,capture_output=True,timeout=60)
        (args.output/(label+'-compiler.out')).write_bytes(compiled.stdout)
        (args.output/(label+'-compiler.err')).write_bytes(compiled.stderr)
        if compiled.returncode:raise RuntimeError('The actual source parser harness did not compile.')
        result=subprocess.run([str(binary)],capture_output=True,text=True,timeout=20)
        (args.output/(label+'.out')).write_text(result.stdout,encoding='utf-8')
        (args.output/(label+'.err')).write_text(result.stderr,encoding='utf-8')
        summary=json.loads(result.stdout)
        expected={'checks':1600,'failed':569 if label=='original' else 0,'delayed_fragment_failures':565 if label=='original' else 0,'scope':'actual_pinned_parser_with_controlled_nonblocking_reads'}
        if summary!=expected or result.returncode!=(1 if label=='original' else 0) or any(marker in result.stderr for marker in ('ERROR: AddressSanitizer','runtime error:','LeakSanitizer')):
            raise AssertionError('The unchanged historical negative or patched parser controls failed.')
        records[label]={'exit':result.returncode,'checks':summary['checks'],'failed':summary['failed'],'delayed_fragment_failures':summary['delayed_fragment_failures']}
    facts={'schema':1,'state':'passed','original_sources':ORIGINAL,'patched_sources':PATCHED,'cases':records,'compiler_sha256':digest(Path(compiler).read_bytes()),'sanitizers':args.sanitize,'controlled_reads_only':True,'native_network_qualification':'separate','existing_allocation_cap_preserved':True,'product_or_database_access':False}
    (args.output/'qualification.safe.json').write_text(json.dumps(facts,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(facts,sort_keys=True))

COMMON=r'''
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <winsock2.h>
#include <basetsd.h>
#include <intrin.h>
typedef SSIZE_T ssize_t;
#define ntoh64(v) _byteswap_uint64(v)
#else
#include <sys/types.h>
#include <arpa/inet.h>
#include <byteswap.h>
#define ntoh64(v) __bswap_64(v)
#endif
typedef void SSL; typedef void SSL_CTX;
#ifdef _WIN32
typedef SOCKET ws_socket_t;
#else
typedef int ws_socket_t;
#endif
typedef enum {WS_NONE=0,WS_PROTO_ERR=1002} ws_cause_t;
typedef enum {WSOC_CONTINUATION=0,WSOC_TEXT=1,WSOC_BINARY=2,WSOC_CLOSE=8,WSOC_PING=9,WSOC_PONG=10} ws_opcode_t;
#define WS_BLOCK 10000
'''

STUBS=r'''
static size_t read_limit=65536;static ssize_t payload_cap=100000;
static unsigned char input[2000000];static size_t input_size,offset;static size_t breaks[128];static int breaks_count,break_index,paused;
static int establish_logical_layer(wsh_t *wsh){return 1;}
static ssize_t ws_close(wsh_t *wsh,int why){wsh->down=1;return -1000;}
static ssize_t ws_raw_read(wsh_t *wsh,void *data,size_t size,int block){
 if(!block && break_index<breaks_count && offset==breaks[break_index] && !paused){paused=1;return -2;}
 if(paused){paused=0;break_index++;}
 if(offset==input_size)return -2;
 size_t count=input_size-offset;if(count>size)count=size;if(count>read_limit)count=read_limit;
 if(break_index<breaks_count && offset<breaks[break_index] && count>breaks[break_index]-offset)count=breaks[break_index]-offset;
 memcpy(data,input+offset,count);offset+=count;return (ssize_t)count;
}

static ssize_t ws_write_frame(wsh_t *wsh,ws_opcode_t opcode,void *data,size_t size){return (ssize_t)size;}
'''

CASES=r'''
static void add_frame(unsigned char opcode,int fin,const unsigned char *data,size_t size){
 input[input_size++]=(fin?128:0)|opcode;
 if(size<126){input[input_size++]=128|size;}else{input[input_size++]=128|126;input[input_size++]=size>>8;input[input_size++]=size;}
 const unsigned char mask[]={0x19,0x67,0xa2,0x44};memcpy(input+input_size,mask,4);input_size+=4;
 for(size_t i=0;i<size;i++)input[input_size++]=data[i]^mask[i%4];
}
static int run_case(size_t size,int parts,int delay,int ping){
 unsigned char *payload=malloc(size);for(size_t i=0;i<size;i++)payload[i]=(unsigned char)(33+i%89);
 input_size=offset=0;breaks_count=break_index=paused=0;
 size_t used=0;size_t peak=size;
 for(int part=0;part<parts;part++){
  size_t length=(size-used)/(parts-part);add_frame(part?WSOC_CONTINUATION:WSOC_TEXT,part==parts-1,payload+used,length);used+=length;
  if(delay && part<parts-1)breaks[breaks_count++]=input_size;
  if(ping && part<parts-1){if(used+3>peak)peak=used+3;unsigned char control[]={77,78,79};add_frame(WSOC_PING,1,control,3);}
 }
 wsh_t ws={0};ws.handshake=1;ws.payload_size_max=payload_cap;ws.buflen=65536;ws.bbuflen=1024;
 ws.buffer=malloc(ws.buflen+1);ws.bbuffer=malloc(ws.bbuflen+1);
 unsigned char *decoded=NULL;ws_opcode_t opcode=WSOC_CLOSE;ssize_t result=-2;int attempts=0;
 while(result==-2 && attempts++<128)result=ws_read_frame(&ws,&opcode,&decoded);
 int equal=payload_cap<(ssize_t)peak?(result<0 && result!=-2 && ws.down):(result==(ssize_t)size && decoded && !memcmp(decoded,payload,size));
 free(ws.buffer);free(ws.bbuffer);free(payload);return equal;
}
int main(void){
 int checks=0,failed=0,delayed_failed=0;
 size_t sizes[]={2,3,125,126,127,255,1024,4096,8192,16384,65535};size_t read_limits[]={1,2,7,23,4096};
 for(size_t limit=0;limit<5;limit++){read_limit=read_limits[limit];
 for(size_t i=0;i<sizeof(sizes)/sizeof(sizes[0]);i++){
  int maxparts=sizes[i]>=8?4:2;
  for(int parts=1;parts<=maxparts;parts++)for(int delay=0;delay<=1;delay++)for(int ping=0;ping<=1;ping++)for(int cap=0;cap<=1;cap++){payload_cap=(ssize_t)sizes[i]-cap;
   int okay=run_case(sizes[i],parts,delay,ping);checks++;if(!okay){failed++;if(delay&&parts>1)delayed_failed++;fprintf(stderr,"size=%zu parts=%d delay=%d ping=%d read_limit=%zu cap=%zd\n",sizes[i],parts,delay,ping,read_limit,payload_cap);}
  }
 }
 }
 printf("{\"checks\":%d,\"failed\":%d,\"delayed_fragment_failures\":%d,\"scope\":\"actual_pinned_parser_with_controlled_nonblocking_reads\"}\n",checks,failed,delayed_failed);
 return failed?1:0;
}
'''

if __name__=='__main__':main()
