#!/usr/bin/env python3
"""Compile the actual registrar quota statements against real isolated SQLite."""
import argparse,hashlib,json,subprocess,tempfile
from pathlib import Path

parser=argparse.ArgumentParser();parser.add_argument('--prepared',type=Path,required=True);args=parser.parse_args()
source=args.prepared/'freeswitch/src/mod/endpoints/mod_sofia/sofia_reg.c'
assert hashlib.sha256(source.read_bytes()).hexdigest()=='5319b1b6c26708149552f3135e96ee2e693009890cb5b0aeee3169a81c0c20e7'

def quota(text):
    section=text.index('/* The max-registrations-per-extension-option only affects REGISTER-authentications */')
    start=text.index('\t\tuint32_t count = 0;',section);end=text.index('\t\tfree(sql);',start)+len('\t\tfree(sql);')
    return text[start:end]+'\n return count;\n'

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
print('PASS actual patched/upstream C quota statements: isolated SQLite collision, own limit, same-Call-ID refresh, realm isolation, no/empty/untrusted force, quoted identity and multiple-contact checks; no native PBX acceptance implied')
