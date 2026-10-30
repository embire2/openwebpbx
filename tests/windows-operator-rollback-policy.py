#!/usr/bin/env python3
"""Read-only, source-bound Windows operator rollback policy projection.

Only the installed helper's explicit instance notify/reset timestamp is modeled.
All raw bytes of every other policy field/row remain equal. No SQL is written.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import hmac
import importlib.util
import json
import os
from pathlib import Path
import re

RESET = "UPDATE public.v_pbx_update_policies SET mode=''notify'',updated_at=now() WHERE scope_key=''instance'';"
FIELDS = {'scope_key','mode','channel','maintenance_hour','maintenance_duration','updated_by','updated_at','android_minimum_version'}

def tokens(raw):
    if type(raw) is not str or len(raw)>65536:raise ValueError('Bounded raw policy rows required')
    decoder=json.JSONDecoder();i=0;result={}
    def whitespace():
        nonlocal i
        while i<len(raw) and raw[i].isspace():i+=1
    whitespace()
    if raw[i:i+1]!='{':raise ValueError('Policy object required')
    i+=1
    while True:
        whitespace()
        if raw[i:i+1]=='}':i+=1;break
        key,end=decoder.raw_decode(raw,i);i=end;whitespace()
        if type(key) is not str or key in result or raw[i:i+1]!=':':raise ValueError('Unique policy fields required')
        i+=1;whitespace();start=i;value,i=decoder.raw_decode(raw,i);result[key]=(start,i,value);whitespace()
        if raw[i:i+1]=='}':i+=1;break
        if raw[i:i+1]!=',':raise ValueError('Policy delimiter differs')
        i+=1
    whitespace()
    if i!=len(raw) or set(result)!=FIELDS:raise ValueError('Exact original policy schema required')
    return result

def utc(value):
    if type(value) is not str:raise ValueError('Explicit aware timestamp required')
    result=datetime.fromisoformat(value.replace('Z','+00:00'))
    if result.tzinfo is None:raise ValueError('Explicit aware timestamp required')
    return result.astimezone(timezone.utc)

def project(before, after, started, finished):
    if type(before) is not list or type(after) is not list or not 1<=len(before)==len(after)<=1000:raise ValueError('Exact bounded policy inventory required')
    start,end=utc(started),utc(finished)
    if not start<=end:raise ValueError('Actual operator window required')
    def indexed(rows):
        out={}
        for raw in rows:
            parsed=tokens(raw);scope=parsed['scope_key'][2]
            if type(scope) is not str or not re.fullmatch(r'instance|tenant:[0-9a-f-]{36}',scope) or scope in out:raise ValueError('Exact unique policy scopes required')
            out[scope]=(raw,parsed)
        if 'instance' not in out:raise ValueError('Original instance policy required')
        return out
    old,new=indexed(before),indexed(after)
    if old.keys()!=new.keys():raise ValueError('Policy scope inventory changed')
    normalized=[]
    for scope,(raw,fields) in new.items():
        prior,previous=old[scope]
        if scope!='instance':
            if raw!=prior:raise ValueError('Tenant policy changed')
            normalized.append(raw);continue
        if fields['mode'][2]!='notify' or not start<=utc(fields['updated_at'][2])<=end:raise ValueError('Source-bound instance reset/window differs')
        # Replace only the two exact JSON value tokens; field order, whitespace,
        # number representation and every other token remain byte-exact.
        for key in sorted(('mode','updated_at'),key=lambda k:fields[k][0],reverse=True):
            a,b,_=fields[key];x,y,_=previous[key];raw=raw[:a]+prior[x:y]+raw[b:]
        if raw!=prior:raise ValueError('Unmodeled instance policy fields changed')
        normalized.append(raw)
    return sorted(normalized)

def digest(rows,key):
    # Match the original PHP snapshot's json_agg -> associative decode ->
    # JSON_UNESCAPED_SLASHES encoding, preserving native column order.
    values=[json.loads(row) for row in sorted(rows)]
    return hmac.new(key,json.dumps(values,separators=(',',':')).encode(),hashlib.sha256).hexdigest()

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('action',choices=['before','after']);p.add_argument('--baseline',type=Path,required=True);p.add_argument('--output',type=Path)
    p.add_argument('--helper-source',type=Path,required=True);p.add_argument('--helper-sha256',required=True)
    p.add_argument('--started');p.add_argument('--finished');a=p.parse_args()
    if os.name!='nt' or os.environ.get('GITHUB_ACTIONS')!='true' or os.environ.get('OPENWEB_WINDOWS_UPDATER_TEST')!='1':raise RuntimeError('Disposable Windows updater qualification only')
    raw=a.helper_source.read_bytes()
    if hashlib.sha256(raw).hexdigest()!=a.helper_sha256 or raw.decode('utf-8-sig').count(RESET)!=1:raise RuntimeError('Exact signed helper/reset source required')
    spec=importlib.util.spec_from_file_location('operator_policy_backup',Path('C:/OpenWebPBX/tools/backups.py'));b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)
    rows=b.query(b.read_settings(),"select coalesce(json_agg(value order by value),'[]') from (select row_to_json(t)::text value from public.v_pbx_update_policies t) p",json_result=True)
    key=(a.baseline.parent/'audit.key').read_bytes()
    if len(key)!=32:raise RuntimeError('Original independent audit key required')
    facts={'schema':1,'helper_sha256':a.helper_sha256,'reset_sql_sha256':hashlib.sha256(RESET.encode()).hexdigest(),'raw_hmac':digest(rows,key)}
    if a.action=='before':
        for row in rows:tokens(row)
        with a.baseline.open('x',encoding='utf-8') as f:json.dump(facts|{'raw_rows':rows},f);f.flush();os.fsync(f.fileno())
        print(json.dumps(facts));return
    original=json.loads(a.baseline.read_text())
    if original['helper_sha256']!=a.helper_sha256 or digest(original['raw_rows'],key)!=original['raw_hmac'] or original['reset_sql_sha256']!=facts['reset_sql_sha256']:raise RuntimeError('Original private policy/source capture changed')
    normalized=project(original['raw_rows'],rows,a.started,a.finished)
    if digest(normalized,key)!=original['raw_hmac']:raise RuntimeError('Exact original policy projection differs')
    with a.output.open('x',encoding='utf-8') as f:json.dump(facts|{'state':'passed','original_hmac':original['raw_hmac'],'normalized_after_hmac':digest(normalized,key),'scope':'exact source-modeled instance notify/timestamp; all other policy fields and tenant rows byte-exact'},f);f.flush();os.fsync(f.fileno())
    print(json.dumps({'state':'passed','source_modeled_instance_reset':True}))
if __name__=='__main__':main()
