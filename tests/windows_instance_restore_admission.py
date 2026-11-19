#!/usr/bin/env python3
"""AST-only full-recovery admission/TLS controls; optional private native locks.

No installed module initialization, product paths, SQL, service/task operations,
certificate-store writes or ACL changes. Native holders exit naturally.
"""
import argparse
import ast
import concurrent.futures
import contextlib
import datetime as dt
import hashlib
import json
import os
from pathlib import Path, PureWindowsPath
import re
import subprocess
import sys
import tempfile
import time
import types

ROOT = Path(__file__).resolve().parents[1]
BACKUPS = ROOT/'packaging/windows/backups.py'
PROTECTION = ROOT/'packaging/debian/protection.py'
CONTROL = ROOT/'packaging/windows/Backup-Control.ps1'
SOURCE = BACKUPS.read_text(encoding='utf-8')
checks = []


def check(value, label):
    if not value:
        raise AssertionError(label)
    checks.append(label)


def extract(source, names):
    nodes = [node for node in ast.parse(source).body
             if isinstance(node, (ast.FunctionDef, ast.ClassDef)) and node.name in names]
    if {node.name for node in nodes} != set(names):
        raise AssertionError('Exact source definitions required')
    return nodes


def source_controls():
    start = SOURCE.index('@contextlib.contextmanager\ndef instance_restore_guard(')
    end = SOURCE.index('\n\ndef same_restore_https_address(', start)
    previous = SOURCE[:start] + '''def restore(source, password, settings, **kwargs):
    safe_private_directory(STORE)
    with exclusive_guard(UPGRADE_LOCK), exclusive_guard(STORE/'worker.lock'), registration_guard(ROOTS):
        return _restore(source, password, settings, **kwargs)\n''' + SOURCE[end:]
    previous = previous.replace("if ('runtime-config/phone-tls.json' in manifest['files']\n                and not same_instance_phone_tls(extracted, manifest, settings, allow_existing=allow_existing)):",
                                "if 'runtime-config/phone-tls.json' in manifest['files']:")
    check(hashlib.sha256(previous.encode()).hexdigest() == '841f1f15d34f357e03da95419eea2420293eb9a2e5d8eb8f0c6c41455decada6',
          'Entire original Windows backup module exact outside two reviewed closures')
    protection = PROTECTION.read_text(encoding='utf-8')
    prior = protection.replace("                admission = {'worker_admission': True} if os.name == 'nt' else {}\n", '').replace(', **admission)', ')')
    check(hashlib.sha256(prior.encode()).hexdigest() == 'b7cef859af219dd1fb9e5b2b3f35baa8ea178d72a7e97d07d9e6c62e708cd7af',
          'Entire protection module exact outside Windows explicit admission forwarding')
    tree = ast.parse(protection)
    calls = [n for n in ast.walk(tree) if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)
             and isinstance(n.func.value, ast.Name) and n.func.value.id == 'full' and n.func.attr == 'restore']
    forwarded = [n for n in calls if any(k.arg is None and isinstance(k.value, ast.Name) and k.value.id == 'admission'
                                        for k in n.keywords)]
    check(len(calls) == 3 and len(forwarded) == 2, 'Only two scheduled full restore calls forward explicit admission; import stays default')
    control = CONTROL.read_text(encoding='utf-8')
    first = control.index('function Confirm-OpenWebRestorePhoneCertificate(')
    last = control.index('\nfunction Plan {', first)
    old_control = control[:first] + control[last + 1:]
    old_control = old_control.replace(",'phone-tls-identity')][string]$Operation", ")][string]$Operation")
    old_control = old_control.replace("  'phone-tls-identity'{$result=@{confirmed=[bool](Confirm-OpenWebRestorePhoneCertificate ([string]$value.thumbprint) ([string]$value.certificate_sha256))}}\n", '')
    check(hashlib.sha256(old_control.encode()).hexdigest() == '7057c045d43664ea946f2b1dd6d54dc17757224d3a6f57667cbf511dcaac41b3',
          'Entire original Backup-Control exact outside readonly identity function/dispatch')
    assignment = next(n.value for n in ast.walk(tree) if isinstance(n, ast.Assign)
                      and any(isinstance(t, ast.Name) and t.id == 'admission' for t in n.targets))
    for platform, wanted in [('nt', {'worker_admission': True}), ('posix', {})]:
        check(eval(compile(ast.Expression(assignment), '<actual worker admission>', 'eval'),
                   {'os': types.SimpleNamespace(name=platform)}) == wanted, 'Actual '+platform+' caller option exact')


def backend(work, *, windows=True, clock=None, guard=None):
    state = work/'state'
    (state/'updates').mkdir(parents=True, exist_ok=True)
    store = work/'store'; store.mkdir(exist_ok=True)
    private = work/'registration'; (private/'image-onboarding').mkdir(parents=True, exist_ok=True)
    names = {'BackupError', 'BackupBusy', 'reparse', 'ordinary', 'windows_exclusive_guard',
             'exclusive_guard', 'backup_worker_guard', 'registration_guard', 'instance_restore_guard', 'restore',
             'lock_file', 'unlock_file'}
    ns = {'os': os if windows and os.name == 'nt' else types.SimpleNamespace(name='nt' if windows else 'posix'),
          'Path': Path, 'contextlib': contextlib, 'time': clock or time,
          'STATE': state, 'STORE': store, 'UPGRADE_LOCK': work/'upgrade.lock',
          'ROOTS': {'registration-state': private}, 'REGISTRATION_FILES': (),
          'registration_private': lambda *args: None, 'secure_acl': lambda *args, **kw: None,
          'safe_private_directory': lambda path: path}
    if os.name == 'nt':
        import msvcrt
        ns['msvcrt'] = msvcrt
    else:
        import fcntl
        ns['fcntl'] = fcntl
    exec(compile(ast.Module(body=extract(SOURCE, names), type_ignores=[]), str(BACKUPS), 'exec'), ns)
    if guard:
        ns['exclusive_guard'] = guard(ns)
    ns['restore_pending'] = lambda: (state/'held').exists()
    return ns


def portable_guards(work):
    class Clock:
        def __init__(self): self.now = 0; self.sleeps = []
        def monotonic(self): return self.now
        def sleep(self, seconds): self.sleeps.append(seconds); self.now += seconds

    for index in range(3):
        clock = Clock(); state = {'held': [], 'attempts': 0, 'body': 0, 'waits_without_locks': []}
        def make(ns):
            @contextlib.contextmanager
            def guard(path):
                label = 'image' if path.name == 'worker.lock' and path.parent.name == 'image-onboarding' else ('store' if path.parent == ns['STORE'] else 'upgrade')
                if label == ['upgrade', 'store', 'image'][index]:
                    state['attempts'] += 1
                    if state['attempts'] == 1: raise ns['BackupBusy']('native contention fixture')
                state['held'].append(label)
                try: yield
                finally: state['held'].remove(label)
            return guard
        ns = backend(work/str(index), clock=clock, guard=make)
        original_sleep = clock.sleep
        def sleep(seconds):
            state['waits_without_locks'].append(not state['held']); original_sleep(seconds)
        clock.sleep = sleep
        def body(*args, **kwargs): state['body'] += 1; return 'once'
        ns['_restore'] = body
        check(ns['restore'](None, None, {}, worker_admission=True) == 'once' and state['body'] == 1
              and state['waits_without_locks'] == [True] and not state['held'],
              'Compound acquisition '+str(index)+' releases every prior handle before retry and runs body once')
    for kind in ['busy', 'fatal']:
        ns = backend(work/('body-'+kind), guard=lambda ns: lambda path: contextlib.nullcontext())
        counter = []
        error = ns['BackupBusy'] if kind == 'busy' else ns['BackupError']
        def body(*args, **kw): counter.append(1); raise error('body failure')
        ns['_restore'] = body
        try: ns['restore'](None, None, {}, worker_admission=True)
        except error: pass
        check(counter == [1], kind+' guarded body exception executes exactly once')
    for flag in [False, 1, 'true']:
        ns = backend(work/('default-'+str(flag)))
        attempts = []
        @contextlib.contextmanager
        def busy(path): attempts.append(path); raise ns['BackupBusy']('old nonblocking'); yield
        ns['exclusive_guard'] = busy
        try: ns['restore'](None, None, {}, worker_admission=flag)
        except ns['BackupBusy']: pass
        check(len(attempts) == 1, 'CLI/default/nonboolean '+str(flag)+' retains original nonblocking admission')
    for marker in ['held', 'updates/maintenance']:
        ns = backend(work/('hold-'+marker.replace('/', '-')), guard=lambda ns: lambda path: contextlib.nullcontext())
        (ns['STATE']/marker).write_bytes(b'fixture')
        body = []; ns['_restore'] = lambda *a, **k: body.append(1)
        try: ns['restore'](None, None, {}, worker_admission=True)
        except ns['BackupBusy']: pass
        check(not body, 'Fresh durable '+marker+' rechecked inside compound guard before body')
    ns = backend(work/'fatal', guard=lambda ns: lambda path: contextlib.nullcontext())
    @contextlib.contextmanager
    def fatal(path): raise ns['BackupError']('permission/path fixture'); yield
    ns['exclusive_guard'] = fatal
    try: ns['restore'](None, None, {}, worker_admission=True)
    except ns['BackupError']: check(True, 'Fatal acquisition error propagates without retry')
    else: raise AssertionError('Fatal acquisition was accepted')
    ns = backend(work/'linux', windows=False, guard=lambda ns: lambda path: contextlib.nullcontext())
    ns['restore_pending'] = lambda: (_ for _ in ()).throw(AssertionError('Windows gate on Linux'))
    ns['_restore'] = lambda *a, **k: 'linux'
    check(ns['restore'](None, None, {}, worker_admission=True) == 'linux', 'Linux keeps original guard/body behavior')


def tls_fixture(work, *, validity='current', keypair=True, dns='owned.example.test'):
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID
    work.mkdir(parents=True, exist_ok=True)
    state=work/'state'; config=work/'config'; archived=work/'archive'; tls=state/'phone-tls'
    for path in [tls,config,archived/'fusionpbx-config',archived/'runtime-config',archived/'phone-tls']:path.mkdir(parents=True, exist_ok=True)
    now=dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    key=rsa.generate_private_key(public_exponent=65537,key_size=2048)
    name=x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,'owned.example.test')])
    before,after = {'current':(-1,1),'expired':(-2,-1),'future':(1,2)}[validity]
    certificate=(x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
                 .serial_number(x509.random_serial_number()).not_valid_before(now+dt.timedelta(days=before))
                 .not_valid_after(now+dt.timedelta(days=after)).add_extension(x509.SubjectAlternativeName([x509.DNSName(dns)]),False)
                 .sign(key,hashes.SHA256()))
    pem=certificate.public_bytes(serialization.Encoding.PEM)
    private_key=key if keypair else rsa.generate_private_key(public_exponent=65537,key_size=2048)
    agent=private_key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption())+pem
    metadata={'RestorePending':False,'Hostname':'owned.example.test','Port':5061,
              'ExpiresUtc':certificate.not_valid_after_utc.isoformat(),
              'CertificateThumbprint':certificate.fingerprint(hashes.SHA1()).hex().upper()}
    values={'fusionpbx-config/openweb-template.key':os.urandom(32),
            'runtime-config/phone-tls.json':json.dumps(metadata).encode(),'phone-tls/agent.pem':agent,'phone-tls/cafile.pem':pem}
    current={name: config/'openweb-template.key' if name.startswith('fusionpbx') else state/'phone-tls.json' if name.startswith('runtime') else tls/Path(name).name for name in values}
    for name,value in values.items(): current[name].write_bytes(value);(archived/name).write_bytes(value)
    ns={'Path':Path,'dt':dt,'json':json,'re':re,'KEY':config/'openweb-template.key','STATE':state,'ROOTS':{'phone-tls':tls}}
    exec(compile(ast.Module(body=extract(SOURCE,{'BackupError','reparse','ordinary','same_instance_phone_tls'}),type_ignores=[]),str(BACKUPS),'exec'),ns)
    calls=[]
    def control(operation,value):calls.append((operation,value));return {'confirmed':True}
    ns['control']=control
    return ns,archived,{'files':{name:{} for name in values}},current,values,metadata,calls


def portable_tls(work):
    ns,archive,manifest,current,values,metadata,calls=tls_fixture(work)
    settings={'openweb.public_host':'owned.example.test'}
    def decision(flag=True): return ns['same_instance_phone_tls'](archive,manifest,settings,allow_existing=flag)
    def reset():
        for name,value in values.items():current[name].write_bytes(value);(archive/name).write_bytes(value)
        manifest['files'] = {name:{} for name in values}
        ns['control']=lambda operation,value: {'confirmed':True}
        settings['openweb.public_host']='owned.example.test'
    check(decision() and len(calls)==1 and calls[0][0]=='phone-tls-identity', 'Safe same-instance proof checks actual current store certificate identity read-only')
    check(all(current[name].read_bytes()==value and (archive/name).read_bytes()==value for name,value in values.items()), 'Safe TLS decision preserves exact current/archive bytes')
    for flag in [False,1,'true',None]: check(not decision(flag), 'Only exact allow_existing True admits current TLS '+str(flag))
    for name in values:
        reset();current[name].write_bytes(values[name]+b'mismatch')
        check(not decision(), 'Replacement/mismatched current '+name+' retains pending policy')
        reset();current[name].unlink()
        check(not decision(), 'Missing current '+name+' retains pending policy')
    for field,bad in [('RestorePending',True),('Hostname','foreign.example.test'),('Port',5060),('Port',True),
                      ('ExpiresUtc','2000-01-01T00:00:00+00:00'),('ExpiresUtc','2030-01-01'),('CertificateThumbprint','0'*40)]:
        reset();changed=dict(metadata);changed[field]=bad;value=json.dumps(changed).encode()
        current['runtime-config/phone-tls.json'].write_bytes(value);(archive/'runtime-config/phone-tls.json').write_bytes(value)
        check(not decision(), 'Invalid current metadata '+field+' '+str(bad)+' retains pending policy')
    reset();settings['openweb.public_host']='foreign.example.test';check(not decision(),'Foreign current public hostname refuses same-instance reuse')
    for proof in [{'confirmed':False},{'confirmed':1},None]:
        reset();ns['control']=lambda *a, proof=proof:proof
        check(not decision(),'Missing/negative/nonboolean current-store proof refuses TLS reuse '+str(proof))
    reset();name='phone-tls/agent.pem';value=values[name].replace(b'PRIVATE KEY',b'INVALID KEY')
    current[name].write_bytes(value);(archive/name).write_bytes(value);check(not decision(),'Invalid or mismatched private key refuses TLS reuse')
    reset();manifest['files'].pop('phone-tls/cafile.pem');check(not decision(),'Incomplete authenticated TLS inventory retains pending policy')
    for options,label in [({'validity':'expired'},'Expired current certificate'),({'validity':'future'},'Not-yet-valid current certificate'),
                          ({'keypair':False},'Actual valid different private key'),({'dns':'foreign.example.test'},'Certificate SAN for foreign hostname')]:
        other=tls_fixture(work/label.replace(' ','-'),**options)
        check(not other[0]['same_instance_phone_tls'](other[1],other[2],{'openweb.public_host':'owned.example.test'},allow_existing=True),label+' retains pending policy')
    reset();value=b'x'*31
    current['fusionpbx-config/openweb-template.key'].write_bytes(value);(archive/'fusionpbx-config/openweb-template.key').write_bytes(value)
    check(not decision(),'Matching but non32-byte current/archive master key refuses same-instance reuse')
    reset();ns['reparse']=lambda path:Path(path)==current['phone-tls/agent.pem']
    try:decision()
    except ns['BackupError']:check(True,'Ordinary-path guard remains fatal for TLS material links')
    else:raise AssertionError('Linked TLS material was accepted')
    ns['reparse']=lambda path:False
    def provider_failure(*args):raise PermissionError('private provider access fixture')
    ns['control']=provider_failure
    try:decision()
    except PermissionError:check(True,'Unexpected provider/access errors remain fatal rather than TLS mismatch fallback')
    else:raise AssertionError('Provider/access failure was swallowed')


def native_immediate(work):
    facts=[]
    for kind in ['busy','fatal']:
        ns=backend(work/kind);count=[]
        exception=ns['BackupBusy'] if kind=='busy' else ns['BackupError']
        def body(*a,**k):count.append(1);raise exception('body-only fixture')
        ns['_restore']=body;started=time.monotonic()
        try:ns['restore'](None,None,{},worker_admission=True)
        except exception:pass
        check(count==[1] and time.monotonic()-started<3,'Native '+kind+' body executes once and is never retried')
        facts.append({'case':'body-'+kind,'body_count':len(count)})
    ns=backend(work/'missing-path');ns['UPGRADE_LOCK']=work/'missing-parent'/'upgrade.lock';ns['_restore']=lambda *a,**k:(_ for _ in ()).throw(AssertionError('unexpected body'))
    started=time.monotonic()
    try:ns['restore'](None,None,{},worker_admission=True)
    except ns['BackupError'] as error:check(not isinstance(error,ns['BackupBusy']) and time.monotonic()-started<3,'Native missing path is fatal without retry/body')
    else:raise AssertionError('Missing operation path accepted')
    return facts


def portable():
    source_controls()
    with tempfile.TemporaryDirectory(prefix='openweb-instance-restore-portable-') as temporary:
        work=Path(temporary);portable_guards(work/'guards');portable_tls(work/'tls')


def native_holder(lock,seconds,ready,upgrade=None,hold=None):
    for path in [lock,ready,*([upgrade] if upgrade else []),*([hold] if hold else [])]:
        relative=path.resolve().relative_to(Path(tempfile.gettempdir()).resolve())
        if (not relative.parts or not relative.parts[0].startswith('openweb-instance-restore-')
                or any(PureWindowsPath(str(path)).is_relative_to(PureWindowsPath(root)) for root in ['C:/OpenWebPBX','C:/ProgramData/OpenWebPBX'])
                or any(p.is_symlink() or (p.exists() and getattr(p.stat(),'st_file_attributes',0)&0x400) for p in [path,*path.parents])):
            raise RuntimeError('Private TEMP holder path required')
    ns=backend(lock.parent/'holder-backend')
    with ns['exclusive_guard'](lock):
        ready.write_bytes(b'ready');started=time.monotonic()
        if upgrade:
            time.sleep(1)
            with ns['backup_worker_guard'](upgrade): ready.with_suffix('.upgrade-acquired').write_bytes(b'owned handle only')
        if hold:
            time.sleep(max(0,seconds-1-(time.monotonic()-started)))
            Path(hold).write_bytes(b'fixture durable hold')
        time.sleep(max(0,seconds-(time.monotonic()-started)))


def native_case(work,name):
    ns=backend(work)
    ns['_restore']=lambda *a,**k:'body-once'
    paths=[ns['UPGRADE_LOCK'],ns['STORE']/'worker.lock',ns['ROOTS']['registration-state']/'image-onboarding/worker.lock']
    index={'upgrade':0,'store':1,'image-deadlock':2,'timeout':1,'restore-hold':0,'maintenance-hold':2}[name]
    ready=work/'holder.ready';seconds=35 if name=='timeout' else 15
    arguments=[sys.executable,'-I','-B',str(Path(__file__).resolve()),'--holder',str(paths[index]),str(seconds),str(ready)]
    if name=='image-deadlock':arguments+=['--upgrade',str(ns['UPGRADE_LOCK'])]
    if name in ['restore-hold','maintenance-hold']:
        arguments+=['--hold',str(ns['STATE']/('held' if name=='restore-hold' else 'updates/maintenance'))]
    child=subprocess.Popen(arguments,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    try:
        limit=time.monotonic()+10
        while not ready.exists() and time.monotonic()<limit and child.poll() is None:time.sleep(.02)
        check(ready.exists(),'Native '+name+' holder acquired real private lock')
        started=time.monotonic();old_busy=False
        try:ns['restore'](None,None,{})
        except ns['BackupBusy']:old_busy=True
        check(old_busy and time.monotonic()-started<3,'Native '+name+' original nonblocking path refuses contention')
        count=[]
        def body(*a,**k):count.append(1);return 'body-once'
        ns['_restore']=body;started=time.monotonic();error=None
        try:result=ns['restore'](None,None,{},worker_admission=True)
        except BaseException as caught:error=caught;result=None
        elapsed=time.monotonic()-started
        if name=='timeout':check(isinstance(error,ns['BackupBusy']) and not count and 29.5<=elapsed<34,'Native compound acquisition expires at real30s without body')
        elif name in ['restore-hold','maintenance-hold']:
            check(isinstance(error,ns['BackupBusy']) and not count and elapsed>=14,'Native '+name+' rechecks fresh hold AFTER real wait')
        else:check(error is None and result=='body-once' and count==[1] and elapsed>=14,'Native '+name+' waits natural15s and executes body once')
        if name=='image-deadlock':check(ready.with_suffix('.upgrade-acquired').exists(),'Image holder acquired upgrade lock while worker released entire failed compound attempt')
        output,stderr=child.communicate(timeout=40)
        check(child.returncode==0 and not stderr,'Native '+name+' holder exits naturally without stderr')
        for path in paths:
            with ns['exclusive_guard'](path):pass
        check(True,'Native '+name+' all handles reacquired after body/refusal')
        return {'case':name,'worker_seconds':elapsed,'body_count':len(count),'holder_exit':child.returncode,'worker_admission':True}
    finally:
        # Never terminate the holder to produce a passing contention result.
        if child.poll() is None:child.communicate(timeout=45)


def native_certificate(work):
    """Extract only the readonly function; ephemeral certificate/provider stub."""
    code=r'''
param([string]$Source,[string]$Output)
$ErrorActionPreference='Stop'
$tokens=$null;$parse=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Source,[ref]$tokens,[ref]$parse)
if($parse.Count){throw 'Control source does not parse'}
$function=$ast.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq'Confirm-OpenWebRestorePhoneCertificate'},$true)
if($function.Count-ne1){throw 'Exact readonly certificate function required'}
. ([scriptblock]::Create($function[0].Extent.Text))
$rsa=[Security.Cryptography.RSACng]::new(2048);$certificate=$null;$public=$null;$expired=$null;$future=$null
$checks=0;$script:selected=$null;$script:requested=@();$script:providerError=$false
function Get-Item {param([string]$LiteralPath,[string]$ErrorAction)
 $script:requested+=$LiteralPath
 if($script:providerError){throw [UnauthorizedAccessException]::new('Private fixture access refusal')}
 if(!$script:selected){throw [Management.Automation.ItemNotFoundException]::new('Private fixture missing')}
 if($LiteralPath-cne('Cert:\LocalMachine\My\'+$script:selected.Thumbprint)){throw 'Readonly provider path differs'}
 return $script:selected
}
function Need([bool]$Value){if(!$Value){throw 'Readonly certificate control failed'};$script:checks++}
try{
 Need $rsa.Key.IsEphemeral
 $request=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=private-fixture.invalid',$rsa,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
 $certificate=$request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddHours(-1),[DateTimeOffset]::UtcNow.AddHours(1))
 $digest=[Security.Cryptography.SHA256]::Create();try{$hash=([BitConverter]::ToString($digest.ComputeHash($certificate.RawData))).Replace('-','').ToLowerInvariant()}finally{$digest.Dispose()}
 $script:selected=$certificate;Need (Confirm-OpenWebRestorePhoneCertificate $certificate.Thumbprint $hash)
 Need (!(Confirm-OpenWebRestorePhoneCertificate $certificate.Thumbprint ('0'*64)))
 Need (!(Confirm-OpenWebRestorePhoneCertificate 'invalid' $hash))
 $public=[Security.Cryptography.X509Certificates.X509Certificate2]::new($certificate.RawData);$script:selected=$public
 Need (!(Confirm-OpenWebRestorePhoneCertificate $certificate.Thumbprint $hash))
 $script:selected=$null;Need (!(Confirm-OpenWebRestorePhoneCertificate $certificate.Thumbprint $hash))
 $expired=$request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddHours(-2),[DateTimeOffset]::UtcNow.AddHours(-1));$script:selected=$expired
 $digest=[Security.Cryptography.SHA256]::Create();try{$expiredHash=([BitConverter]::ToString($digest.ComputeHash($expired.RawData))).Replace('-','').ToLowerInvariant()}finally{$digest.Dispose()}
 Need (!(Confirm-OpenWebRestorePhoneCertificate $expired.Thumbprint $expiredHash))
 $future=$request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddHours(1),[DateTimeOffset]::UtcNow.AddHours(2));$script:selected=$future
 $digest=[Security.Cryptography.SHA256]::Create();try{$futureHash=([BitConverter]::ToString($digest.ComputeHash($future.RawData))).Replace('-','').ToLowerInvariant()}finally{$digest.Dispose()}
 Need (!(Confirm-OpenWebRestorePhoneCertificate $future.Thumbprint $futureHash))
 $script:selected=$certificate;$script:providerError=$true;$fatal=$false
 try{$null=Confirm-OpenWebRestorePhoneCertificate $certificate.Thumbprint $hash}catch [UnauthorizedAccessException]{$fatal=$true}
 Need $fatal
 $value=@{passed=$true;checks=$checks;source_ast_only=$true;ephemeral_certificate_only=$true;certificate_store_writes=$false;provider_paths_fixed=$true}
 $stream=[IO.File]::Open($Output,'CreateNew','Write','None');try{$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($value|ConvertTo-Json));$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}finally{foreach($item in @($certificate,$public,$expired,$future,$rsa)){if($item){$item.Dispose()}}}
'''
    script=work/'readonly-cert-fixture.ps1';script.write_text(code,encoding='utf-8')
    result=work/'readonly-cert.safe.json'
    powershell=Path(os.environ['SystemRoot'])/'System32/WindowsPowerShell/v1.0/powershell.exe'
    environment={k:v for k,v in os.environ.items() if k.upper()!='PSMODULEPATH'}
    environment['PSModulePath']=str(Path(os.environ['SystemRoot'])/'System32/WindowsPowerShell/v1.0/Modules')
    completed=subprocess.run([str(powershell),'-NoProfile','-NonInteractive','-Mta','-ExecutionPolicy','Bypass','-File',str(script),'-Source',str(CONTROL),'-Output',str(result)],env=environment,capture_output=True,timeout=60)
    check(completed.returncode==0 and result.exists(),'Native WinPS5.1 readonly certificate function passes ephemeral/provider controls')
    value=json.loads(result.read_text(encoding='utf-8-sig'));check(value['passed'] and value['checks']==9,'Native eight certificate decisions plus ephemeral key assertion checked without certificate-store writes')
    return value


def native(work):
    if os.name!='nt':raise RuntimeError('Actual Windows required')
    expected=Path(tempfile.gettempdir()).resolve();absolute=work.resolve()
    if (work.exists() or absolute.parent!=expected or not absolute.name.startswith('openweb-instance-restore-')
            or any(PureWindowsPath(str(absolute)).is_relative_to(PureWindowsPath(root)) for root in ['C:/OpenWebPBX','C:/ProgramData/OpenWebPBX'])
            or any(path.is_symlink() or getattr(path.stat(),'st_file_attributes',0)&0x400 for path in [expected,*expected.parents])):
        raise RuntimeError('New ordinary private Windows TEMP fixture required')
    work.mkdir()
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        results=list(pool.map(lambda name:native_case(work/name,name),['upgrade','store','image-deadlock','timeout','restore-hold','maintenance-hold']))
    cert=native_certificate(work)
    immediate=native_immediate(work/'immediate')
    result={'passed':True,'checks':len(checks),'native_cases':results,'readonly_certificate':cert,
            'native_immediate':immediate,
            'source_sha256':{str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest() for path in [BACKUPS,PROTECTION,CONTROL,Path(__file__)]},
            'source_ast_only':True,'installed_module_initialization':False,'services_tasks_SQL_certificate_store_writes':False}
    (work/'native-result.safe.json').write_text(json.dumps(result,indent=2))
    print(json.dumps({'passed':True,'checks':len(checks),'native_cases':len(results),'readonly_certificate_controls':cert['checks']}))


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--native',action='store_true');parser.add_argument('--work-root',type=Path)
    parser.add_argument('--holder',nargs=3);parser.add_argument('--upgrade',type=Path);parser.add_argument('--hold',type=Path)
    args=parser.parse_args()
    if args.holder:
        lock,seconds,ready=args.holder;native_holder(Path(lock),float(seconds),Path(ready),args.upgrade,args.hold);return
    portable();portable_count=len(checks)
    if args.native:
        if args.work_root is None:parser.error('--work-root required')
        native(args.work_root)
    else:print(json.dumps({'passed':True,'portable_checks':portable_count,'source_ast_only':True}))


if __name__=='__main__':main()
