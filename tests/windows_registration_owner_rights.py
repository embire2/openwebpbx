"""Native CPython private-directory ACL / exact registration validation controls."""
import argparse,ast,ctypes,hashlib,importlib.util,json,os,subprocess,sys
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
for n in ('source','previous','work-root'):p.add_argument('--'+n,type=Path,required=True)
a=p.parse_args();assert os.name=='nt' and ctypes.windll.shell32.IsUserAnAdmin();assert not a.work_root.exists();a.work_root.mkdir(mode=0o700);checks=0
ps=Path(os.environ.get('SystemRoot','C:/Windows'))/'System32/WindowsPowerShell/v1.0/powershell.exe'
def need(v):
    global checks
    assert v
    checks+=1

def load(path,name):
    s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);sys.modules[name]=m;s.loader.exec_module(m);return m

def literal(path):
    t=ast.parse(path.read_text());f=next(n for n in t.body if isinstance(n,ast.FunctionDef)and n.name=='registration_private');return next(n.value.value for n in ast.walk(f)if isinstance(n,ast.Assign)and any(isinstance(t,ast.Name)and t.id=='code'for t in n.targets))

def child(code,value):
    return subprocess.run([str(ps),'-NoProfile','-NonInteractive','-Command',code],input=json.dumps(value).encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=20)

result={'state':'failed','actual_native_OS_recipe':True,'actual_SYSTEM_claim':False,'metadata_adapters_for_variants_only':True,'product_paths_tasks_services_ports_touched':False}
try:
    directory=a.work_root/'image-onboarding';directory.mkdir(mode=0o700);session=directory/'session.json';session.write_bytes(b'{}')
    paths=[a.work_root,directory,session];context={'paths':[str(x)for x in paths],'root':str(a.work_root)}
    read=r'''$v=[Console]::In.ReadToEnd()|ConvertFrom-Json;$r=@();foreach($p in $v.paths){$a=Get-Acl -LiteralPath $p;$r+=@{path=$p;directory=(Get-Item -LiteralPath $p).PSIsContainer;sddl=$a.Sddl;owner=$a.GetOwner([Security.Principal.SecurityIdentifier]).Value}};$r|ConvertTo-Json -Compress'''
    native=child(read,context);(a.work_root/'native-metadata.stdout.private').write_bytes(native.stdout);need(native.returncode==0);entries=json.loads(native.stdout.decode('utf-8-sig'));need(len(entries)==3 and all(x['owner']in('S-1-5-18','S-1-5-32-544')for x in entries));need(all('OW' in x['sddl']for x in entries))
    current=load(a.source,'registration_owner_rights_current');old=load(a.previous,'registration_owner_rights_previous')
    refused=False
    try:old.registration_private(paths,a.work_root)
    except old.BackupError:refused=True
    need(refused);current.registration_private(paths,a.work_root);need(True)
    code=literal(a.source);guard="if($ace -isnot [Security.AccessControl.CommonAce] -or $ace.IsCallback){throw 'Unknown registration ACE refused.'}";need(guard in code and guard in literal(a.previous));head,body=code.split('\n',1);need(head=="$ErrorActionPreference='Stop';$v=[Console]::In.ReadToEnd()|ConvertFrom-Json")
    prefix=r'''$ErrorActionPreference='Stop';$ctx=[Console]::In.ReadToEnd()|ConvertFrom-Json;$script:map=@{};foreach($x in $ctx.entries){$x|Add-Member -NotePropertyName baseSddl -NotePropertyValue $x.sddl;$script:map[$x.path]=$x};$entry=$script:map[$ctx.target];$raw=[Security.AccessControl.RawSecurityDescriptor]::new($entry.sddl);$index=-1;for($i=0;$i-lt $raw.DiscretionaryAcl.Count;$i++){if($raw.DiscretionaryAcl[$i].SecurityIdentifier.Value-ceq 'S-1-3-4'){$index=$i}};if($index-lt 0){throw 'Native OWNER_RIGHTS fixture required'};$ace=$raw.DiscretionaryAcl[$index]
switch($ctx.case){
 'unknown'{$ace.SecurityIdentifier=[Security.Principal.SecurityIdentifier]::new('S-1-5-20')}
 'creator_group'{$ace.SecurityIdentifier=[Security.Principal.SecurityIdentifier]::new('S-1-3-1')}
 'creator_owner'{$ace.SecurityIdentifier=[Security.Principal.SecurityIdentifier]::new('S-1-3-0')}
 'unprivileged_owner'{$raw.Owner=[Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1000')}
 'other_mask'{$ace.AccessMask=1179785}
 'other_flags'{$ace.AceFlags=[Security.AccessControl.AceFlags]::None}
 'duplicate'{$raw.DiscretionaryAcl.InsertAce($raw.DiscretionaryAcl.Count,$ace)}
 'unprotected_root'{$raw.SetFlags([Security.AccessControl.ControlFlags]([int]$raw.ControlFlags-band (-bnot [int][Security.AccessControl.ControlFlags]::DiscretionaryAclProtected)))}
 'system_owner'{$raw.Owner=[Security.Principal.SecurityIdentifier]::new('S-1-5-18')}
 'no_owner_rights'{$raw.DiscretionaryAcl.RemoveAce($index)}
 'unchanged'{}
 default{throw 'Unknown fixture mutation'}
};$entry.sddl=$raw.GetSddlForm([Security.AccessControl.AccessControlSections]::All)
function Get-Acl {param([string]$LiteralPath)$row=$script:map[$LiteralPath];if(!$row){throw 'Unknown fixture path'};$a=if($row.directory){[Security.AccessControl.DirectorySecurity]::new()}else{[Security.AccessControl.FileSecurity]::new()};$a.SetSecurityDescriptorSddlForm($row.baseSddl);$raw=[Security.AccessControl.RawSecurityDescriptor]::new($row.sddl);$a.SetOwner($raw.Owner);$a.SetAccessRuleProtection([bool]($raw.ControlFlags-band [Security.AccessControl.ControlFlags]::DiscretionaryAclProtected),$true);$a|Add-Member -NotePropertyName RawFixtureSddl -NotePropertyValue $row.sddl;return $a}
Update-TypeData -TypeName System.Security.AccessControl.ObjectSecurity -MemberType ScriptProperty -MemberName Sddl -Value {$this.RawFixtureSddl} -Force
$v=$ctx.context;[Console]::Error.WriteLine('VALIDATION_PREDICATE_ENTERED')
'''
    for case in ('unchanged','system_owner','no_owner_rights','unknown','creator_group','creator_owner','unprivileged_owner','other_mask','other_flags','duplicate','unprotected_root'):
        target=str(a.work_root if case=='unprotected_root'else directory)
        r=child(prefix+body,{'entries':entries,'context':context,'case':case,'target':target});expected=case in('unchanged','system_owner','no_owner_rights');need((r.returncode==0)==expected)
        if not expected:need('VALIDATION_PREDICATE_ENTERED' in r.stderr.decode(errors='replace'))
        (a.work_root/(case+'.stderr.private')).write_bytes(r.stderr)
    # File-specific inherited OWNER_RIGHTS remains accepted; explicit/foreign
    # file flags and nonprivileged owner still refuse through the same predicate.
    for case in ('unchanged','other_flags','unprivileged_owner','other_mask','duplicate'):
        r=child(prefix+body,{'entries':entries,'context':context,'case':case,'target':str(session)});need((r.returncode==0)==(case=='unchanged'))
        if case!='unchanged':need('VALIDATION_PREDICATE_ENTERED' in r.stderr.decode(errors='replace'))
        (a.work_root/('file-'+case+'.stderr.private')).write_bytes(r.stderr)
    result.update(state='passed',checks=checks,fixtureEntries=entries,sourceSHA256=hashlib.sha256(a.source.read_bytes()).hexdigest(),originalSourceSHA256=hashlib.sha256(a.previous.read_bytes()).hexdigest())
except BaseException as e:result.update(errorType=type(e).__name__,checks=checks);raise
finally:
    (a.work_root/'result.private.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items()if k!='fixtureEntries'}))
