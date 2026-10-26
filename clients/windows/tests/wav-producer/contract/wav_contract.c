/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Real SDK filter/writer contract with invented PCM input, never a calling proof.
 */
#include <winsock2.h>
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <bctoolbox/logging.h>
#include <mediastreamer2/msfilter.h>
#include <mediastreamer2/msfactory.h>
#include <mediastreamer2/msqueue.h>
#include "fixture_recorder.h"
static void fixture_log_stderr(const char *domain,BctbxLogLevel level,const char *fmt,va_list args) {
    int failed;
    _lock_file(stderr);
    failed=fprintf(stderr,"%s[%u]: ",domain?domain:"bctoolbox",(unsigned)level)<0;
    if(vfprintf(stderr,fmt,args)<0)failed=1;
    if(fputc('\n',stderr)==EOF)failed=1;
    _unlock_file(stderr);
    if(failed)exit(EXIT_FAILURE);
}
static unsigned checks;
static void need(int ok) { if (!ok) { fprintf(stderr,"contract assertion %u failed\n",checks+1); exit(1); } checks++; }
static uint16_t u16(const unsigned char *p) { return (uint16_t)(p[0]|((uint16_t)p[1]<<8)); }
static uint32_t u32(const unsigned char *p) { return (uint32_t)p[0]|((uint32_t)p[1]<<8)|((uint32_t)p[2]<<16)|((uint32_t)p[3]<<24); }
static unsigned char *bytes(const char *path,size_t *size) {
    FILE *f=fopen(path,"rb"); long n; unsigned char *b; need(f!=NULL); need(fseek(f,0,SEEK_END)==0); n=ftell(f); need(n>=0&&n<1048576); rewind(f);
    b=(unsigned char*)malloc((size_t)n+1); need(b!=NULL); need(fread(b,1,(size_t)n,f)==(size_t)n); need(fclose(f)==0); *size=(size_t)n; return b;
}
static void header(const char *path,int rate,int channels,size_t payload,int closed) {
    size_t n; unsigned char *b=bytes(path,&n); need(n>=44&&memcmp(b,"RIFF",4)==0&&memcmp(b+8,"WAVEfmt ",8)==0&&memcmp(b+36,"data",4)==0);
    need(u32(b+16)==16&&u16(b+20)==1&&u16(b+22)==channels&&u32(b+24)==(uint32_t)rate&&u16(b+34)==16);
    need(u16(b+32)==channels*2&&u32(b+28)==(uint32_t)rate*(uint32_t)channels*2u);
    if(closed)need(n==44+payload&&u32(b+4)==payload+36&&u32(b+40)==payload);
    else need(n>=44+payload);
    free(b);
}
static void pattern(unsigned char *p,size_t n,unsigned seed) { size_t i; for(i=0;i<n;i++)p[i]=(unsigned char)((i*37u+seed)%251u); }
static void source_process(MSFilter *f) {(void)f;}
static MSFilterDesc source_desc={.id=MS_FILTER_PLUGIN_ID,.name="OpenWebWavContractInput",.text="Invented PCM input",.category=MS_FILTER_OTHER,.ninputs=0,.noutputs=1,.process=source_process};
static void feed(MSFilter *source,MSFilter *sink,const unsigned char *p,size_t n) {
    mblk_t *m; need(n<=16384); m=allocb((int)n,0); need(m!=NULL); memcpy(m->b_wptr,p,n); m->b_wptr+=n;
    ms_queue_put(source->outputs[0],m); sink->desc->process(sink);
}
static void one(MSFactory *factory,const char *path,int rate,int channels,int after_open,int append) {
    unsigned char first[8192],last[320]; MSFilter *sink,*source; size_t n; unsigned char *data;
    pattern(first,sizeof(first),11);pattern(last,sizeof(last),29);
    sink=ms_factory_create_filter(factory,MS_FILE_REC_ID);source=ms_factory_create_filter_from_desc(factory,&source_desc);need(sink&&source);
    need(ms_filter_link(source,0,sink,0)==0);
    if(!after_open){need(ms_filter_call_method(sink,MS_FILTER_SET_SAMPLE_RATE,&rate)==0);need(ms_filter_call_method(sink,MS_FILTER_SET_NCHANNELS,&channels)==0);}
    need(ms_filter_call_method(sink,MS_RECORDER_OPEN,(void*)path)==0);
    if(after_open){need(ms_filter_call_method(sink,MS_FILTER_SET_SAMPLE_RATE,&rate)==0);need(ms_filter_call_method(sink,MS_FILTER_SET_NCHANNELS,&channels)==0);}
    header(path,rate,channels,0,1);need(ms_filter_call_method_noarg(sink,MS_RECORDER_START)==0);feed(source,sink,first,sizeof(first));
    /* Physical async writes are observed, never synthesized or header-normalized. */
    { ULONGLONG until=GetTickCount64()+2000; do { WIN32_FILE_ATTRIBUTE_DATA a; if(GetFileAttributesExA(path,GetFileExInfoStandard,&a)&&a.nFileSizeLow>=44+4096)break;Sleep(10); }while(GetTickCount64()<until); }
    header(path,rate,channels,4096,0);
    {int wrong=rate==8000?16000:8000;need(ms_filter_call_method(sink,MS_FILTER_SET_SAMPLE_RATE,&wrong)==-1);}
    need(ms_filter_call_method_noarg(sink,MS_RECORDER_CLOSE)==0);header(path,rate,channels,sizeof(first),1);
    data=bytes(path,&n);need(n==44+sizeof(first)&&memcmp(data+44,first,sizeof(first))==0);free(data);
    if(append){
        need(ms_filter_unlink(source,0,sink,0)==0);ms_filter_destroy(sink);sink=ms_factory_create_filter(factory,MS_FILE_REC_ID);need(sink!=NULL);need(ms_filter_link(source,0,sink,0)==0);
        need(ms_filter_call_method(sink,MS_RECORDER_OPEN,(void*)path)==0);need(ms_filter_call_method(sink,MS_FILTER_SET_SAMPLE_RATE,&rate)==0);need(ms_filter_call_method(sink,MS_FILTER_SET_NCHANNELS,&channels)==0);
        need(ms_filter_call_method_noarg(sink,MS_RECORDER_START)==0);feed(source,sink,last,sizeof(last));need(ms_filter_call_method_noarg(sink,MS_RECORDER_CLOSE)==0);
        header(path,rate,channels,sizeof(first)+sizeof(last),1);data=bytes(path,&n);need(n==44+sizeof(first)+sizeof(last)&&memcmp(data+44,first,sizeof(first))==0&&memcmp(data+44+sizeof(first),last,sizeof(last))==0);free(data);
    }
    need(ms_filter_unlink(source,0,sink,0)==0);ms_filter_destroy(source);ms_filter_destroy(sink);
}
static void owned_path(char *out,size_t cap,const char *root,const char *leaf) {int n=snprintf(out,cap,"%s\\%s",root,leaf);need(n>0&&(size_t)n<cap);need(GetFileAttributesA(out)==INVALID_FILE_ATTRIBUTES&&GetLastError()==ERROR_FILE_NOT_FOUND);}
int main(int argc,char **argv) {
    char root[MAX_PATH],temp[MAX_PATH],path[MAX_PATH];size_t t;DWORD rn,tn;MSFactory *factory;MSFilterDesc *before;MSFilter *sink;
    need(argc==2&&getenv("GITHUB_ACTIONS")&&strcmp(getenv("GITHUB_ACTIONS"),"true")==0&&getenv("RUNNER_ENVIRONMENT")&&strcmp(getenv("RUNNER_ENVIRONMENT"),"github-hosted")==0);
    need(getenv("GITHUB_REPOSITORY")&&strcmp(getenv("GITHUB_REPOSITORY"),"embire2/openwebpbx")==0);
    rn=GetFullPathNameA(argv[1],MAX_PATH,root,NULL);tn=GetEnvironmentVariableA("RUNNER_TEMP",temp,MAX_PATH);need(rn>0&&rn<MAX_PATH&&tn>0&&tn<MAX_PATH);t=strlen(temp);while(t&&temp[t-1]=='\\')temp[--t]=0;
    need(_strnicmp(root,temp,t)==0&&root[t]=='\\'&&strncmp(root+t+1,"phone-wav-contract-",19)==0&&strlen(root+t+20)==32);
    {size_t i;for(i=t+20;root[i];i++)need((root[i]>='0'&&root[i]<='9')||(root[i]>='a'&&root[i]<='f'));}
    need((GetFileAttributesA(root)&FILE_ATTRIBUTE_DIRECTORY)!=0&&(GetFileAttributesA(root)&FILE_ATTRIBUTE_REPARSE_POINT)==0&&GetFileAttributesA("C:\\OpenWebPBX")==INVALID_FILE_ATTRIBUTES&&GetFileAttributesA("C:\\ProgramData\\OpenWebPBX")==INVALID_FILE_ATTRIBUTES);
    bctbx_set_log_handler(fixture_log_stderr);
    factory=ms_factory_new();need(factory!=NULL);if(!ms_factory_lookup_filter_by_id(factory,MS_FILE_REC_ID))ms_factory_init_voip(factory);
    before=ms_factory_lookup_filter_by_id(factory,MS_FILE_REC_ID);need(before&&strcmp(before->name,"MSFileRec")==0);
    need(openweb_fixture_wav_register(factory)==1&&openweb_fixture_wav_selected(factory)==1&&ms_factory_lookup_filter_by_id(factory,MS_FILE_REC_ID)!=before);
    owned_path(path,sizeof(path),root,"empty.wav");sink=ms_factory_create_filter(factory,MS_FILE_REC_ID);need(sink!=NULL);need(ms_filter_call_method(sink,MS_RECORDER_OPEN,path)==0);header(path,8000,1,0,1);need(ms_filter_call_method_noarg(sink,MS_RECORDER_CLOSE)==0);header(path,8000,1,0,1);ms_filter_destroy(sink);
    owned_path(path,sizeof(path),root,"mono.wav");one(factory,path,8000,1,0,1);
    owned_path(path,sizeof(path),root,"stereo.wav");one(factory,path,48000,2,1,1);
    owned_path(path,sizeof(path),root,"sixteen.wav");one(factory,path,16000,1,1,0);
    owned_path(path,sizeof(path),root,"malformed.wav");{FILE *f=fopen(path,"wb");need(f!=NULL&&fwrite("bad",1,3,f)==3&&fclose(f)==0);}
    sink=ms_factory_create_filter(factory,MS_FILE_REC_ID);need(sink!=NULL);need(ms_filter_call_method(sink,MS_RECORDER_OPEN,path)==-1);ms_filter_destroy(sink);
    {size_t n;unsigned char *b=bytes(path,&n);need(n==3&&memcmp(b,"bad",3)==0);free(b);}
    ms_factory_destroy(factory);
    printf("{\"schema\":1,\"state\":\"passed_native_fixture_producer_contract\",\"checks\":%u,\"actual_sdk\":\"5.5.23\",\"public_factory_selection_proved\":true,\"invented_PCM_input\":true,\"decoded_calling_qualified\":false,\"original_SDK_filewriter_qualified\":false,\"hardware_qualified\":false}\n",checks);
    return 0;
}
