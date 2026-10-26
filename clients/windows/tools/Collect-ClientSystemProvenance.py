"""Failure-only, post-result Windows log observation. Never decides client acceptance."""
from pathlib import Path
import argparse,datetime,hashlib,importlib.util,json,ntpath,os,re,shutil,stat,sys

CORE_SHA='afb20f0f207ce0928570d8afd8bee08e3b736bffd7f4e48d3f4aa8fae9fc30de'
STORES=('ActiveStore','PersistentStore')
COMMANDS=('Get-NetFirewallRule','Get-NetFirewallProfile','Get-NetFirewallAddressFilter','Get-NetFirewallPortFilter','Get-NetFirewallApplicationFilter','Get-NetFirewallServiceFilter','Get-NetFirewallInterfaceFilter','Get-NetFirewallInterfaceTypeFilter','Get-NetFirewallSecurityFilter')

def unique(pairs):
    out={}
    for key,value in pairs:
        if key in out:raise ValueError('duplicate_key')
        out[key]=value
    return out

def read(path,limit):
    if not path.is_file() or path.is_symlink() or path.stat().st_size>limit:raise ValueError('bounded_ordinary_input')
    return json.loads(path.read_bytes(),object_pairs_hook=unique)

def digest(value):return hashlib.sha256(json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()).hexdigest()

def rule_digest(value):
    if type(value)is not str or not re.fullmatch(r'[A-Za-z0-9_.{}-]{1,160}',value):return None
    return hashlib.sha256(value.lower().strip('{}').encode('ascii')).hexdigest()

def path_category(value):
    # Lexical class only. No file, signature or network is opened here.
    if value is None or value=='':return 'not_specified'
    if type(value)is not str:return 'unrecognized'
    if value in ('Any','*'):return 'any_application'
    if value.lower()=='system':return 'system_pseudo_image'
    if re.match(r'(?i)^[a-z]:[\\/]windows[\\/]',value):return 'windows_path_prefix_not_signature'
    if re.search(r'(?i)[\\/]phone-client-media-[a-f0-9]{32}[\\/]',value):return 'owned_fixture_path_pattern_not_identity'
    return 'other_path_not_exported'

def snapshot_delta(before,after):
    for model in (before,after):
        if type(model)is not dict or set(model)!=set(('services','root_certificates','firewall')):raise ValueError('snapshot_shape')
        if type(model['services'])is not list or len(model['services'])>4096:raise ValueError('service_bound')
        if type(model['firewall'])is not dict or set(model['firewall'])!={s+'/'+c for s in STORES for c in COMMANDS}:raise ValueError('firewall_shape')
        if any(type(v)is not list or len(v)>8192 for v in model['firewall'].values()):raise ValueError('firewall_bound')
    def services(rows):
        out={}
        for row in rows:
            if type(row)is not dict or set(row)!={'name','state','mode','path','account'} or type(row['name'])is not str or not re.fullmatch(r'[A-Za-z0-9_.-]{1,128}',row['name'])or row['name']in out:raise ValueError('service_identity')
            out[row['name']]=row
        return out
    old=services(before['services']);new=services(after['services']);changed=[]
    for name in sorted(set(old)|set(new)):
        a=old.get(name);b=new.get(name)
        if a==b:continue
        states={'Running','Stopped','Start Pending','Stop Pending','Continue Pending','Pause Pending','Paused','Unknown'}
        changed.append({'name':name,'before_present':a is not None,'after_present':b is not None,
            'before_state':a['state']if a and a['state']in states else 'Unknown','after_state':b['state']if b and b['state']in states else 'Unknown',
            'state_changed':bool(a and b and a['state']!=b['state']),
            'definition_unchanged':bool(a and b and {k:v for k,v in a.items()if k!='state'}=={k:v for k,v in b.items()if k!='state'})})
    rules=[];identity=[];totals={};truncated=False
    for store in STORES:
        key=store+'/Get-NetFirewallRule';a={digest(r)for r in before['firewall'][key]};added=[r for r in after['firewall'][key]if digest(r)not in a];totals[store]=len(added)
        for row in sorted(added,key=digest):
            if len(rules)>=16:truncated=True;continue
            rid=rule_digest(row.get('InstanceID'));identity.append(rid)if rid else None
            filters=[]
            for kind in ['Get-NetFirewallApplicationFilter','Get-NetFirewallServiceFilter']:
                selected=[r for r in after['firewall'][store+'/'+kind]if type(row.get('InstanceID'))is str and (r.get('InstanceID')==row['InstanceID']or r.get('Name')==row['InstanceID'])]
                filters.append(selected[0]if len(selected)==1 else {})
            group=row.get('RuleGroup');resource=type(group)is str and bool(re.fullmatch(r'(?i)@(?:%systemroot%|[a-z]:[\\/]windows)[\\/]system32[\\/][a-z0-9_.-]+\.dll,-?[0-9]{1,8}',group))
            rules.append({'store':store,'row_sha256':digest(row),'rule_identity_sha256':rid,
                'program_path_class':path_category(filters[0].get('AppPath'))if filters[0]else'not_bound_to_rule',
                'service_filter_class':'any_service'if filters[1].get('ServiceName')in ('Any','*')else 'not_specified_or_other',
                'group_class':'windows_resource_reference_not_signer'if resource else 'other_or_empty',
                'signer_class':'not_retained_in_original_snapshot','actor_class':'not_retained_in_snapshot'})
    return {'services':changed[:16],'services_truncated':len(changed)>16,'added_rule_counts':totals,'added_rules':rules,
            'rules_truncated':truncated,'rule_identity_sha256':sorted(set(identity)),'original_system_gate_changed':False,'original_failure_overridden':False}

def core_gate_services(report):
    data=report.get('snapshot_diff',{}).get('service_changes',{})
    rows=data.get('rows',[])
    if type(rows)is not list or len(rows)>16:raise ValueError('bounded_core_service_delta')
    result=[];states={'Running','Stopped','Start Pending','Stop Pending','Continue Pending','Pause Pending','Paused','Unknown'}
    for row in rows:
        if type(row)is not dict or type(row.get('name'))is not str or not re.fullmatch(r'[A-Za-z0-9_.-]{1,128}',row['name'])or type(row.get('changed_properties'))is not list or any(v not in ['state','mode','path','account','present']for v in row['changed_properties']):raise ValueError('closed_core_service_delta')
        if type(row.get('before_present'))is not bool or type(row.get('after_present'))is not bool:raise ValueError('typed_core_service_presence')
        result.append({'name':row['name'],'before_present':row['before_present'],'after_present':row['after_present'],
            'before_state':row.get('before_state')if row.get('before_state')in states else'Unknown',
            'after_state':row.get('after_state')if row.get('after_state')in states else'Unknown',
            'definition_unchanged':bool(row['before_present']and row['after_present']and set(row['changed_properties'])<={'state'})})
    return result

def closed_events(value,request):
    expected={'schema','scope','logs','service_transition_events','matched_firewall_events','defender_event_count','parse_refused','elapsed_ms','configuration_changed','actor_absence_is_not_proof_of_absence','client_or_workflow_accepted','observation_truncated'}
    if type(value)is not dict or set(value)!=expected or type(value['schema'])is not int or value['schema']!=1 or value['scope']!='existing_local_events_only' or value['configuration_changed']is not False or value['actor_absence_is_not_proof_of_absence']is not True or value['client_or_workflow_accepted']is not False or type(value['observation_truncated'])is not bool:raise ValueError('closed_event_schema')
    if type(value['logs'])is not list or len(value['logs'])!=3:raise ValueError('closed_channel_count')
    for row,kind in zip(value['logs'],['scm','firewall','defender']):
        if type(row)is not dict or set(row)!={'kind','state','records'} or row['kind']!=kind or row['state']not in ['observed','capped','empty','unavailable','budget_exhausted']or type(row['records'])is not int or not 0<=row['records']<=64:raise ValueError('closed_channel_row')
        if row['state']in ['empty','unavailable','budget_exhausted']and row['records']!=0:raise ValueError('unavailable_channel_inference')
    if any(row['state']in ['capped','budget_exhausted']for row in value['logs'])and value['observation_truncated']is not True:raise ValueError('explicit_observation_truncation')
    for name,maximum in [('defender_event_count',64),('parse_refused',128),('elapsed_ms',30000)]:
        if type(value[name])is not int or not 0<=value[name]<=maximum:raise ValueError('bounded_event_counters')
    for name in ['service_transition_events','matched_firewall_events']:
        if type(value[name])is not list or len(value[name])>32:raise ValueError('bounded_event_rows')
    for row in value['service_transition_events']:
        if type(row)is not dict or set(row)!={'name','event_id','actor_class'} or row['name']not in request['service_names']or type(row['event_id'])is not int or row['event_id']not in [7036,7040,7045]or row['actor_class']!='not_available_in_SCM_transition_record':raise ValueError('closed_service_event')
    paths=['not_available','system_pseudo_image','other_not_exported','owned_fixture_pattern_after_cleanup','windows_image','defender_image']
    signers=['not_sampled','file_not_available','not_valid','valid_Microsoft','valid_other','unavailable']
    for row in value['matched_firewall_events']:
        if type(row)is not dict or set(row)!={'rule_identity_sha256','event_id','modifying_image_class','post_test_image_signer_class'} or row['rule_identity_sha256']not in request['rule_identity_sha256']or type(row['event_id'])is not int or not 0<=row['event_id']<=65535 or row['modifying_image_class']not in paths or row['post_test_image_signer_class']not in signers:raise ValueError('closed_firewall_event')
        if row['modifying_image_class']not in ['windows_image','defender_image']and row['post_test_image_signer_class']!='not_sampled':raise ValueError('unobserved_image_signer')
    return value

def write(path,value):
    with path.open('x',encoding='utf-8')as f:json.dump(value,f,indent=2);f.write('\n');f.flush();os.fsync(f.fileno())

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--source',required=True);parser.add_argument('--evidence',type=Path,required=True);args=parser.parse_args()
    if os.name!='nt' or os.environ.get('RUNNER_ENVIRONMENT')!='github-hosted' or os.environ.get('GITHUB_REPOSITORY')!='embire2/openwebpbx':raise ValueError('disposable_host_required')
    if args.source!=os.environ.get('PHONE_SOURCE_REF') or os.environ.get('GITHUB_REF_NAME')!='qualification/windows-phone100-core-media-20261026':raise ValueError('exact_source_branch_required')
    if sys.version_info[:3]!=(3,12,10):raise ValueError('exact_selected_interpreter_required')
    if not re.fullmatch('[a-f0-9]{40}',args.source)or not re.fullmatch('[1-9][0-9]{0,19}',os.environ.get('GITHUB_RUN_ID',''))or os.environ.get('GITHUB_RUN_ATTEMPT')!='1':raise ValueError('run_binding')
    temp=Path(os.environ['RUNNER_TEMP']).resolve(strict=True);evidence=args.evidence.resolve(strict=True)
    if evidence!=temp/'phone-system-provenance-evidence'or evidence.is_symlink()or list(evidence.iterdir()):raise ValueError('new_empty_evidence_required')
    repo=Path(os.environ['GITHUB_WORKSPACE']).resolve(strict=True);core=repo/'clients/windows/tools/WavProducerOwnedProcess.py';helper=repo/'clients/windows/tools/Read-ClientSystemEvents.ps1'
    if hashlib.sha256(core.read_bytes()).hexdigest()!=CORE_SHA:raise ValueError('original_job_core_required')
    root=os.environ.get('SystemRoot','');winps=Path(root)/'System32/WindowsPowerShell/v1.0/powershell.exe'
    if not re.fullmatch(r'[A-Za-z]:\\[^<>:"|?*\x00-\x1f]+',root)or not winps.is_file()or winps.is_symlink():raise ValueError('absolute_native_powershell_required')
    inputs={};status='not_observed';primary=None;proof=None;work=None;closed=False
    source={'schema':1,'source_commit':args.source,'run_id':os.environ['GITHUB_RUN_ID'],'workflow_scope':'post_failed_original_result_only','job_core_sha256':CORE_SHA,'helper_sha256':hashlib.sha256(helper.read_bytes()).hexdigest(),'driver_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'python_version':'3.12.10','python_executable_sha256':hashlib.sha256(Path(sys.executable).read_bytes()).hexdigest(),'original_artifacts_accepted':False}
    source['source_inputs']={str(path.relative_to(repo)).replace('\\','/'):{'bytes':path.stat().st_size,'sha256':hashlib.sha256(path.read_bytes()).hexdigest()}for path in [repo/'.github/workflows/windows-phone-core-media.yml',repo/'clients/windows/tools/Observe-ClientSystemProvenance.ps1',Path(__file__),helper,core,repo/'clients/windows/tools/Test-ClientMedia.ps1']}
    try:
        original=temp/'phone-core-media-evidence';producer=temp/'phone-wav-evidence'
        report=read(original/'report.json',131072);binding=read(original/'inputs.safe.json',16384);producer_report=read(producer/'report.json',131072)
        interpreter=read(producer/'owned-process-source.json',16384)
        if interpreter.get('python_sha256')!=source['python_executable_sha256']:raise ValueError('original_selected_interpreter_binding')
        if report.get('source_commit')!=args.source or binding.get('source_commit')!=args.source or report.get('state')not in ['failed','passed_software_media']or type(report.get('system_preserved'))is not bool or producer_report.get('source_commit')!=args.source or producer_report.get('state')!='failed':raise ValueError('original_failed_step_required')
        before_path=producer/'baseline.json';after_path=producer/'final.json';before=read(before_path,32*1024**2);after=read(after_path,32*1024**2);delta=snapshot_delta(before,after);core_services=core_gate_services(report)
        # The exact original result/snapshots already exist. Their hashes stay bound;
        # this later observer cannot rewrite them or participate in the client gate.
        for label,path in [('core_report',original/'report.json'),('core_binding',original/'inputs.safe.json'),('failed_producer_report',producer/'report.json'),('producer_before',before_path),('producer_after',after_path),('original_interpreter_binding',producer/'owned-process-source.json')]:inputs[label]={'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'bytes':path.stat().st_size}
        source['original_inputs']=inputs
        start=before_path.stat().st_mtime;end=after_path.stat().st_mtime
        if not 0<=end-start<=2700 or not start<=(original/'report.json').stat().st_mtime<=end:raise ValueError('bounded_original_time_window')
        service_names=sorted({r['name']for r in delta['services']}|{r['name']for r in core_services})
        request={'schema':1,'start_utc':datetime.datetime.fromtimestamp(start-2,datetime.timezone.utc).isoformat(),'end_utc':datetime.datetime.fromtimestamp(end+2,datetime.timezone.utc).isoformat(),'service_names':service_names[:16],'rule_identity_sha256':delta['rule_identity_sha256']}
        source['query_window_start_utc']=request['start_utc'];source['query_window_end_utc']=request['end_utc']
        work=evidence/'private-work';work.mkdir();request_path=work/'request.json';write(request_path,request)
        spec=importlib.util.spec_from_file_location('original_owned_job',core);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        outcome=module.run([str(winps),'-NoProfile','-NonInteractive','-File',str(helper),'-Request',str(request_path),'-Report',str(work/'events.safe.json')],work,timeout=30,working_directory=Path(root)/'System32')
        proof=read(work/'process.safe.json',8192)
        if outcome.returncode!=0 or set(proof)!={'schema','created_suspended','assigned_before_resume','resumed','owned_job_terminated','exit_code','owned_processes_closed','handles_closed','ordinary_exit'}or type(proof['schema'])is not int or proof['schema']!=1 or type(proof['exit_code'])is not int or proof['exit_code']!=0 or any(proof[k]is not True for k in ['created_suspended','assigned_before_resume','resumed','owned_processes_closed','handles_closed','ordinary_exit'])or proof['owned_job_terminated']is not False:raise ValueError('ordinary_owned_job_closure_required')
        events=read(work/'events.safe.json',65536)
        events=closed_events(events,request)
        result={'schema':1,'state':'observed_failure_only_provenance','source_commit':args.source,'run_id':os.environ['GITHUB_RUN_ID'],'producer_snapshot_delta':delta,'separate_original_core_gate_services':core_services,'service_query_names_truncated':len(service_names)>16,'events':events,'original_result_sha256':inputs['core_report']['sha256'],'client_or_workflow_accepted':False};status='observed';closed=True
    except BaseException as error:
        primary=error;result={'schema':1,'state':'provenance_unavailable','source_commit':args.source,'run_id':os.environ['GITHUB_RUN_ID'],'failure_type':type(error).__name__ if type(error).__name__ in ['ValueError','OSError','TimeoutExpired','RuntimeError']else'other','client_or_workflow_accepted':False,'original_failure_overridden':False}
        if work and (work/'process.safe.json').is_file():
            try:proof=read(work/'process.safe.json',8192)
            except Exception:pass
    finally:
        if work and closed:
            if any(f.is_symlink()for f in work.rglob('*')):closed=False
            else:shutil.rmtree(work)
        result['ordinary_owned_scope_removed']=bool(closed and work and not work.exists())
        source['observation_state']=status;write(evidence/'source.safe.json',source);write(evidence/'report.safe.json',result)
        if proof is not None:write(evidence/'process.safe.json',proof)
    print(json.dumps({'schema':1,'state':result['state'],'client_or_workflow_accepted':False,'original_failure_overridden':False}))
    return 0 if closed else 1

if __name__=='__main__':
    try:sys.exit(main())
    except Exception:print(json.dumps({'schema':1,'state':'refused_before_observation','client_or_workflow_accepted':False}));sys.exit(2)
