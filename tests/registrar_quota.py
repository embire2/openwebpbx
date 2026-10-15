#!/usr/bin/env python3
"""Compile the actual registrar quota statements against real isolated SQLite."""
import argparse,hashlib,json,subprocess,tempfile
from pathlib import Path

parser=argparse.ArgumentParser();parser.add_argument('--prepared',type=Path,required=True);args=parser.parse_args()
source=args.prepared/'freeswitch/src/mod/endpoints/mod_sofia/sofia_reg.c'
assert hashlib.sha256(source.read_bytes()).hexdigest()=='8f1a818239d9f264e9e04a6be6e81d0e91259389be2d22f1595cda2deb3dd810'

def quota(text):
    section=text.index('/* The max-registrations-per-extension-option only affects REGISTER-authentications */')
    start=text.index('\t\tuint32_t count = 0;',section);end=text.index('\t\tfree(sql);',start)+len('\t\tfree(sql);')
    return text[start:end]+'\n return count;\n'

def expiry_cleanup(text):
    marker=text.index('delete from sip_registrations where contact=\'%q\' and expires!=')
    start=text.rfind('\t\tif (multi_reg) {',0,marker)
    end=text.index('\n\t\t}\n',marker)+len('\n\t\t}')
    assert start>=0
    return text[start:end]

prefix=r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sqlite3.h>
#define switch_assert assert
#define switch_mprintf sqlite3_mprintf
#define free sqlite3_free
#define zstr(s) (!(s) || !*(s))
typedef struct node {const char *name,*value;struct node *child,*next;} *switch_xml_t;
static switch_xml_t switch_xml_child(switch_xml_t n,const char *kind){(void)kind;return n?n->child:NULL;}
static const char *switch_xml_attr_soft(switch_xml_t n,const char *name){return !strcmp(name,"name")?n->name:n->value;}
static int sofia_reg_regcount_callback(void *p,int argc,char **argv,char **names){(void)argc;(void)names;*(uint32_t *)p=(uint32_t)atoi(argv[0]);return 0;}
static void sofia_glue_execute_sql_callback(sqlite3 *db,void *unused,const char *sql,int (*cb)(void *,int,char **,char **),void *data){(void)unused;assert(sqlite3_exec(db,sql,cb,data,NULL)==SQLITE_OK);}
static uint32_t count_registrations(sqlite3 *profile,const char *raw,const char *force,const char *cid,const char *realm,int trusted){
 struct node variable={trusted?"sip-force-user":"client-supplied-user",force,NULL,NULL},variables_node={"variables","",&variable,NULL},user_node={"user","",force?&variables_node:NULL,NULL};
 switch_xml_t user=&user_node;const char *call_id;char *sql;const char *domain_name=realm;
 struct url {const char *url_user;} url={raw};struct to {struct url *a_url;} to={&url};struct id {const char *i_id;} id={cid};struct sip {struct to *sip_to;struct id *sip_call_id;} sip_node={&to,&id};struct sip *sip=&sip_node;
'''
suffix=r'''
}
static void add(sqlite3 *db,const char *user,const char *cid,const char *realm){char *sql=sqlite3_mprintf("insert into sip_registrations values('%q','%q','%q')",user,cid,realm);assert(sqlite3_exec(db,sql,NULL,NULL,NULL)==SQLITE_OK);sqlite3_free(sql);}
int main(void){sqlite3 *db=NULL;assert(sqlite3_open(":memory:",&db)==SQLITE_OK);assert(sqlite3_exec(db,"create table sip_registrations(sip_user text,call_id text,sip_host text)",NULL,NULL,NULL)==SQLITE_OK);
 add(db,"9002","active-first","fictional.invalid");
 uint32_t other=count_registrations(db,"9002","fixture-9002","new-second","fictional.invalid",1);
 uint32_t own=count_registrations(db,"9001","9002","new-first","fictional.invalid",1);
 assert(count_registrations(db,"9001","9002","active-first","fictional.invalid",1)==0);
 assert(count_registrations(db,"9001","9002","new-first","foreign.invalid",1)==0);
 assert(count_registrations(db,"9002",NULL,"new-second","fictional.invalid",1)==1);
 assert(count_registrations(db,"9002","","new-second","fictional.invalid",1)==1);
 assert(count_registrations(db,"9002","fixture-9002","new-second","fictional.invalid",0)==1);
 add(db,"auth'quoted","quoted","fictional.invalid");
 uint32_t escaped=count_registrations(db,"original-number","auth'quoted","new","fictional.invalid",1);
 add(db,"9002","active-extra","fictional.invalid");
 uint32_t multiple=count_registrations(db,"9001","9002","new-first","fictional.invalid",1);
 printf("{\"foreign_collision_count\":%u,\"own_contact_count\":%u,\"escaped_identity_count\":%u,\"multiple_contact_count\":%u}\n",other,own,escaped,multiple);
 assert(sqlite3_close(db)==SQLITE_OK);return 0;
}
'''
with tempfile.TemporaryDirectory(prefix='openweb-registrar-quota-') as folder:
    work=Path(folder);results={}
    for label,text in [('current',source.read_text()),('upstream',(args.prepared/'sofia_reg.upstream.c').read_text())]:
        c=work/(label+'.c');exe=work/label;c.write_text(prefix+quota(text)+suffix)
        subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Wno-unused-function','-Wno-unused-variable',str(c),'-lsqlite3','-o',str(exe)],check=True)
        results[label]=json.loads(subprocess.check_output([str(exe)],text=True))
    assert results['current']=={'foreign_collision_count':0,'own_contact_count':1,'escaped_identity_count':1,'multiple_contact_count':2}
    assert results['upstream']['foreign_collision_count']==1 and results['upstream']['own_contact_count']==0
    cleanup_prefix=r'''
#include <assert.h>
#include <stdio.h>
#include <sqlite3.h>
#define switch_mprintf sqlite3_mprintf
#define SWITCH_TRUE 1
typedef struct profile {sqlite3 *db;int sip_expires_late_margin;} profile_t;
static char *pending[8];static int pending_count;
static void execute(profile_t *profile,char *sql){assert(sqlite3_exec(profile->db,sql,NULL,NULL,NULL)==SQLITE_OK);sqlite3_free(sql);}
static void sofia_glue_execute_sql(profile_t *profile,char **sql,int dynamic){(void)profile;assert(dynamic&&pending_count<8);pending[pending_count++]=*sql;*sql=NULL;}
static void sofia_glue_execute_sql_now(profile_t *profile,char **sql,int dynamic){assert(dynamic);execute(profile,*sql);*sql=NULL;}
static void cleanup(profile_t *profile,int multi_reg,int multi_reg_contact,const char *contact_str,const char *call_id,long reg_time,long exptime){char *sql=NULL;
'''
    cleanup_suffix=r'''
}
static int scalar(sqlite3 *db,const char *sql){sqlite3_stmt *s=NULL;assert(sqlite3_prepare_v2(db,sql,-1,&s,NULL)==SQLITE_OK);assert(sqlite3_step(s)==SQLITE_ROW);int value=sqlite3_column_int(s,0);assert(sqlite3_finalize(s)==SQLITE_OK);return value;}
int main(void){sqlite3 *db=NULL;assert(sqlite3_open(":memory:",&db)==SQLITE_OK);profile_t profile={db,0};int retained[2],queued_before_response[2];
 for(int mode=0;mode<2;mode++){
  assert(sqlite3_exec(db,"drop table if exists sip_registrations;create table sip_registrations(call_id text,contact text,expires integer);insert into sip_registrations values('own','sip:own@loopback',1200),('own','sip:own@loopback',1199),('other','sip:other@loopback',1200)",NULL,NULL,NULL)==SQLITE_OK);
  pending_count=0;
  cleanup(&profile,1,mode,"sip:own@loopback","own",1000,200);
  queued_before_response[mode]=pending_count;
  /* A genuine acknowledged refresh advances its absolute expiry one second.
   * Execute the old/current ACTUAL cleanup block on either side of it, then
   * let the ordinary deferred worker drain after the two SIP responses. */
  assert(sqlite3_exec(db,"update sip_registrations set expires=1201 where call_id='own'",NULL,NULL,NULL)==SQLITE_OK);
  cleanup(&profile,1,mode,"sip:own@loopback","own",1001,200);
  for(int i=0;i<pending_count;i++)execute(&profile,pending[i]);
  retained[mode]=scalar(db,"select count(*) from sip_registrations where call_id='own' and expires=1201");
  assert(scalar(db,"select count(*) from sip_registrations where call_id='other' and expires=1200")==1);
 }
 printf("{\"call_id_retained\":%d,\"contact_retained\":%d,\"call_id_deferred_before_response\":%d,\"contact_deferred_before_response\":%d}\n",retained[0],retained[1],queued_before_response[0],queued_before_response[1]);
 assert(sqlite3_close(db)==SQLITE_OK);return 0;}
'''
    cleanup_results={}
    for label,text in [('current',source.read_text()),('upstream',(args.prepared/'sofia_reg.upstream.c').read_text())]:
        c=work/(label+'-cleanup.c');exe=work/(label+'-cleanup')
        c.write_text(cleanup_prefix+expiry_cleanup(text)+cleanup_suffix)
        subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Wno-unused-function',str(c),'-lsqlite3','-o',str(exe)],check=True)
        cleanup_results[label]=json.loads(subprocess.check_output([str(exe)],text=True))
    assert cleanup_results['current']=={'call_id_retained':1,'contact_retained':1,'call_id_deferred_before_response':0,'contact_deferred_before_response':0}
    assert cleanup_results['upstream']=={'call_id_retained':0,'contact_retained':0,'call_id_deferred_before_response':1,'contact_deferred_before_response':1}
print('PASS actual patched/upstream C quota and expiry-cleanup statements: isolated SQLite collision/limit/refresh/realm/identity guards, second-boundary cleanup ordering in both Call-ID/contact modes, exact refreshed/foreign row preservation; no native PBX acceptance implied')
