"""Required actual installed Windows greeting call/record/replay acceptance.

Only owned fictional SIP accounts and generated WAV instructions are used.
Provider TTS, real telephones, carriers and external numbers are out of scope.
"""
import hashlib
import json
import math
import os
from pathlib import Path, PureWindowsPath
import re
import shutil
import struct
import time
import uuid
import wave

CASE='native_greetings_installed_worker_wire_record_replay_save'
FLAGS=('actual_windows_native','actual_installed_localservice_worker','backend_pid_unchanged',
       'actual_installed_lua_hashes','worker_claim_and_call_uuid_exact','one_owned_registered_phone',
       'instruction_decoded','recording_tone_decoded','wire_rfc2833_hash','replay_decoded',
       'ready_media_recording_exact','unique_audio_file','other_domain_custom_preserved',
       'localservice_default_storage_create_read_delete','no_storage_acl_grants',
       'owned_localservice_task_and_jobs_removed','owned_call_ended','owned_rows_files_removed',
       'no_provider_tts_or_external_calls')


def exact(value,keys):
    assert type(value) is dict and set(value)==set(keys),'Closed greeting proof required'
    return value


def icacls_path(powershell):
    """The owned Job uses lpApplicationName; it must not rely on PATH search."""
    system_root=PureWindowsPath(os.environ.get('SystemRoot','C:/Windows'))
    assert system_root.is_absolute() and re.fullmatch('[A-Za-z]:',system_root.drive) and '..' not in system_root.parts
    assert not any(ord(c)<32 for c in str(system_root))
    assert type(powershell) is str and PureWindowsPath(powershell)==system_root/'System32/WindowsPowerShell/v1.0/powershell.exe'
    return str(system_root/'System32/icacls.exe')


def status_record(value,directory):
    exact(value,('schema','state','call_uuid','media_uuid','directory','file_exists','file_sha256',
                 'partial_absent','media_exact','recording_exact','preserved'))
    assert type(value['schema']) is int and value['schema']==1
    assert value['state'] in ('cancelled','ready_to_call','calling','ready','failed')
    assert type(value['directory']) is str and Path(value['directory'])==Path(directory)
    for key in ('call_uuid','media_uuid'):
        assert value[key] is None or (type(value[key]) is str and re.fullmatch('[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}',value[key]))
    for key in ('file_exists','partial_absent','media_exact','recording_exact','preserved'):
        assert type(value[key]) is bool
    assert (value['file_sha256'] is None and value['file_exists'] is False) or (type(value['file_sha256']) is str and re.fullmatch('[a-f0-9]{64}',value['file_sha256']) and value['file_exists'] is True)
    return value


def job_closed(directory):
    row=exact(json.loads((directory/'process.safe.json').read_text()),
        ('schema','created_suspended','assigned_before_resume','resumed','owned_job_terminated',
         'owned_processes_closed','handles_closed','exit_code','ordinary_exit'))
    assert type(row['schema']) is int and row['schema']==1 and type(row['exit_code']) is int and row['exit_code']==0
    assert row['owned_job_terminated'] is False
    assert all(row[key] is True for key in ('created_suspended','assigned_before_resume','resumed','owned_processes_closed','handles_closed','ordinary_exit'))


def localservice_storage(f,main,runner,storage_root):
    """Reuse the exact already-qualified nonce/definition-bound task helper.

    Only the throwaway launcher/report scope receives test ACLs. The real
    greeting storage tree receives none, so original install permissions must
    actually permit the worker's default per-tenant create/read/delete pattern.
    """
    nonce=uuid.uuid4().hex
    root=Path(os.environ['RUNNER_TEMP'])/('OpenWebPBX-BackupPublication-'+nonce)
    root.mkdir();local=root/'localservice';local.mkdir();output=root/'output';output.mkdir()
    script=local/'read.ps1';report=output/'greetings.safe.json';request=root/'request.private.json'
    state=Path(f.s['private_state_root']);domain=f.s['domain']
    assert re.fullmatch('[a-f0-9-]{36}',domain)
    assert Path(storage_root)==state/'storage/greetings','The installed default Greetings root differs'
    storage=Path(storage_root)/domain/'greetings'/('native-permission-'+nonce)
    assert Path(storage_root).is_dir() and not Path(storage_root).is_symlink(),'The installed Greetings root is unavailable'
    parent_choices={path:path.exists() for path in (storage.parent,storage.parent.parent)}
    # Fixed paths are private fictional fixture identities, never caller input.
    def quoted(path):return str(path).replace("'","''")
    script.write_text("""$ErrorActionPreference='Stop'
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if($identity.User.Value -cne 'S-1-5-19'){throw 'The actual LocalService identity is required.'}
$directory='"""+quoted(storage)+"""';$file=Join-Path $directory 'owned.txt';$owned=$false
$parent=[IO.Path]::GetDirectoryName($directory);$tenant=[IO.Path]::GetDirectoryName($parent)
$parentBefore=[IO.Directory]::Exists($parent);$tenantBefore=[IO.Directory]::Exists($tenant);$primary=$null
try {
 if([IO.Directory]::Exists($directory)-or[IO.File]::Exists($directory)){throw 'A fresh probe directory is required.'}
 for($p=[IO.Path]::GetDirectoryName($directory);$p;$p=[IO.Path]::GetDirectoryName($p)){
  if([IO.Directory]::Exists($p)-and([IO.File]::GetAttributes($p)-band[IO.FileAttributes]::ReparsePoint)){throw 'Redirected storage is refused.'}
 }
 [void][IO.Directory]::CreateDirectory($directory);$owned=$true
 $bytes=[Text.Encoding]::UTF8.GetBytes('Owned greeting storage probe')
 $handle=[IO.File]::Open($file,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
 try{$handle.Write($bytes,0,$bytes.Length);$handle.Flush($true)}finally{$handle.Dispose()}
 if([Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($file))-cne'Owned greeting storage probe'){throw 'Stored bytes differ.'}
 [IO.File]::Delete($file);[IO.Directory]::Delete($directory,$false)
 if(!$parentBefore){[IO.Directory]::Delete($parent,$false)}
 if(!$tenantBefore){[IO.Directory]::Delete($tenant,$false)}
 $owned=$false
 if([IO.File]::Exists($file)-or[IO.Directory]::Exists($directory)){throw 'Owned storage remains.'}
 [IO.File]::WriteAllText('"""+quoted(report)+"""','{"schema":1,"actual_localservice":true,"default_storage_create_read_delete":true,"owned_storage_removed":true}',[Text.UTF8Encoding]::new($false))
}catch{$primary=$_;throw}finally{
 try{if($owned){
  if([IO.File]::Exists($file)){[IO.File]::Delete($file)}
  if([IO.Directory]::Exists($directory)){[IO.Directory]::Delete($directory,$false)}
  if(!$parentBefore-and[IO.Directory]::Exists($parent)){[IO.Directory]::Delete($parent,$false)}
  if(!$tenantBefore-and[IO.Directory]::Exists($tenant)){[IO.Directory]::Delete($tenant,$false)}
 }}catch{if($null-eq$primary){throw}}
 $identity.Dispose()
}
""",encoding='utf-8')
    helper=f.source/'tests/windows-backup-localservice-task.ps1'
    payload={'schema':1,'task_name':'OpenWebPBX-Backup-LocalService-'+nonce,'nonce':nonce,
             'root':str(root),'script_sha256':hashlib.sha256(script.read_bytes()).hexdigest(),'receipt':None}
    ownership=None;primary=None;closed=[];removed=False
    def run(command,label):
        directory=f.evidence/('greeting-permission-job-'+nonce+'-'+label);directory.mkdir()
        result=runner(command,directory,timeout=240);job_closed(directory);closed.append(directory)
        result.check_returncode();return result
    def task(operation):
        payload['receipt']=ownership;request.write_text(json.dumps(payload),encoding='utf-8')
        command="$env:OPENWEB_WINDOWS_BACKUP_TEST='1';& '"+quoted(helper)+"' -Operation '"+operation+"' -Request '"+quoted(request)+"'"
        result=run([main.WINPS,'-NoProfile','-NonInteractive','-Command',command],operation)
        assert len(result.stdout)<=16384 and not result.stderr.strip()
        return json.loads(result.stdout)
    try:
        for path,grant in ((root,'*S-1-5-19:(RX)'),(local,'*S-1-5-19:(OI)(CI)RX'),(output,'*S-1-5-19:(OI)(CI)M'),(script,'*S-1-5-19:R')):
            full='F' if path==script else '(OI)(CI)F'
            run([icacls_path(main.WINPS),str(path),'/inheritance:r','/grant:r','*S-1-5-32-544:'+full,'*S-1-5-18:'+full,grant],'acl-'+path.name)
        created=exact(task('register'),('schema','created','task_name','task_path','nonce','definition_sha256','script_sha256'))
        assert type(created['schema']) is int and created['schema']==1 and created['created'] is True
        assert created['task_name']==payload['task_name'] and created['task_path']=='\\' and created['nonce']==nonce and created['script_sha256']==payload['script_sha256']
        assert re.fullmatch('[a-f0-9]{64}',created['definition_sha256']);ownership=created
        done=exact(task('start-wait'),('schema','state','last_run_advanced','last_task_result'))
        assert type(done['schema']) is int and done['schema']==1 and done['state']=='completed' and done['last_run_advanced'] is True and type(done['last_task_result']) is int and done['last_task_result']==0
        proof=exact(json.loads(report.read_text()),('schema','actual_localservice','default_storage_create_read_delete','owned_storage_removed'))
        assert type(proof['schema']) is int and proof['schema']==1 and all(proof[k] is True for k in ('actual_localservice','default_storage_create_read_delete','owned_storage_removed'))
        assert not storage.exists() and all(path.exists()==before for path,before in parent_choices.items())
    except BaseException as error:primary=error;raise
    finally:
        if ownership is not None:
            try:
                cleanup=exact(task('cleanup'),('schema','state','owned_registration_removed'))
                assert type(cleanup['schema']) is int and cleanup['schema']==1 and cleanup['state']=='removed' and cleanup['owned_registration_removed'] is True
                removed=True
            except BaseException:
                if primary is None:raise
        if removed:shutil.rmtree(root)
    assert removed and closed and not root.exists()
    return True


def decoded_snapshot(media):
    return {'decoded_pcm':bytes(media['decoded_pcm'])}


def wave_tone(path,frequency):
    assert path.is_file() and not path.is_symlink() and 1644<=path.stat().st_size<=32000000
    with wave.open(str(path),'rb')as audio:
        assert audio.getnchannels()==1 and audio.getsampwidth()==2 and audio.getframerate() in (8000,16000,32000,48000)
        rate=audio.getframerate();frames=audio.getnframes()
        assert rate<=frames<=rate*15,'A bounded actual caller recording is required'
        raw=audio.readframes(frames);assert len(raw)==frames*2,'The actual WAV is incomplete'
        samples=struct.unpack('<'+'h'*frames,raw)
    samples=samples[-min(len(samples),rate*2):];power=sum(x*x for x in samples)
    assert power/len(samples)>100000
    cosine=sum(x*math.cos(2*math.pi*frequency*i/rate) for i,x in enumerate(samples))
    sine=sum(x*math.sin(2*math.pi*frequency*i/rate) for i,x in enumerate(samples))
    ratio=2*(cosine*cosine+sine*sine)/(len(samples)*power)
    assert ratio>=.8,'The committed greeting does not contain the actual known RTP message'
    return round(ratio,4)


def qualify(f,phone,original,main,Playback):
    f.active_case='native_greetings_installed_recording'
    cdr=main.load_module('windows_greeting_service_observer',f.source/'tests/windows_cdr_background.py')
    worker=cdr.observe_service(f,main.WINPS)
    owned=main.load_module('windows_greeting_owned_process',f.source/'tests/windows_meeting_owned_process.py')
    location=exact(f.cli('greetings-paths'),('schema','default_greeting_root'))
    assert type(location['schema']) is int and location['schema']==1
    storage=localservice_storage(f,main,owned.run,location['default_greeting_root'])
    # Physical installed paths must be verified before preparing any instruction
    # fixtures. The uncorrected missing-Lua installation refuses right here.
    prepared=exact(f.cli('greetings-prepare'),('schema','installed_lua_bound','prepared_only','greeting_uuid','directory'))
    assert type(prepared['schema']) is int and prepared['schema']==1 and prepared['installed_lua_bound'] is True and prepared['prepared_only'] is True
    assert re.fullmatch('[a-f0-9-]{36}',prepared['greeting_uuid'])
    playback=Playback(f.cli('services-info')['event_socket'],f.s['realm'])
    before=set(phone.dialogs);invite_start=len(phone.invites);primary=None;body=False;callid=None;media=None
    try:
        armed=exact(f.cli('greetings-arm'),('schema','ready_to_call'));assert type(armed['schema'])is int and armed['schema']==1 and armed['ready_to_call']is True
        callid,media=f.wait(lambda:next(((key,value)for key,value in list(phone.dialogs.items())if key not in before and value.get('acked')and value.get('incoming')),None),20)
        assert phone.thread.is_alive();phone.check_receiver()
        index,_=playback.prompt(callid,['/instruction.wav'],seconds=10)
        media['decoded_pcm'].clear();time.sleep(1.3)
        instruction=original.decoded_tone_check(decoded_snapshot(media),770)
        index,_=playback.prompt(callid,['tone_stream://%(500,0,1000)'],after=index,seconds=6)
        # RTP is generated by the existing real registered peer continuously;
        # do not replace recordFile or invoke any recording helper explicitly.
        time.sleep(3)
        status=status_record(f.cli('greetings-status'),prepared['directory']);assert status['state']=='calling' and status['call_uuid'] is not None and status['preserved'] is True
        with playback.lock:
            owned_events=[event for event in playback.events if event.get('variable_sip_call_id')==callid]
            assert owned_events and all(event.get('Unique-ID')==status['call_uuid'] for event in owned_events)
        assert phone.dtmf({'media':media,'text':phone.sdp(media),'callid':callid},'#')
        index,_=playback.prompt(callid,['/replay.wav'],after=index,seconds=10)
        index,path=playback.prompt(callid,['/recording.partial.wav'],after=index,seconds=6)
        assert Path(path).parent==Path(prepared['directory'])
        media['decoded_pcm'].clear();time.sleep(1.3)
        replay=original.decoded_tone_check(decoded_snapshot(media),phone.tone_hz)
        final=f.wait(lambda:(lambda row:row if row['state']=='ready' else None)(status_record(f.cli('greetings-status'),prepared['directory'])),12)
        f.wait(lambda:media.get('ended'),6);phone.check_receiver()
        assert final['call_uuid']==status['call_uuid'] and final['media_uuid']==prepared['greeting_uuid']
        assert all(final[key] is True for key in ('file_exists','partial_absent','media_exact','recording_exact','preserved'))
        file=Path(final['directory'])/'audio.wav';ratio=wave_tone(file,phone.tone_hz)
        digest=hashlib.sha256(file.read_bytes()).hexdigest();assert digest==final['file_sha256']
        assert len({row['callid'] for row in phone.invites[invite_start:]})==1
        assert cdr.observe_service(f,main.WINPS)['process_id']==worker['process_id']
        cleanup=exact(f.cli('greetings-cleanup'),('schema','owned_rows_and_files_removed','other_domain_and_custom_preserved_before_cleanup'))
        assert type(cleanup['schema']) is int and cleanup['schema']==1 and cleanup['owned_rows_and_files_removed'] is True and cleanup['other_domain_and_custom_preserved_before_cleanup'] is True
        body=True
    except BaseException as error:primary=error;raise
    finally:
        # On failure leave uncertain recording rows/files to the unchanged
        # canonical parent, which quiesces the real backend before deletion.
        # Do not infer Lua closure merely because its dispatch returned +OK.
        steps=[]
        if callid is not None and media is not None and not media.get('ended'):
            steps.append(('native_peer_close',lambda:phone.hangup_incoming(callid)))
        steps.append(('native_peer_close',playback.close))
        main.native_cleanup(primary,'native_case',steps)
    assert body and storage
    return {'state':'passed',**{name:True for name in FLAGS},'recording_sha256':digest,
            'instruction_decoded_ratio':instruction,'replay_decoded_ratio':replay,'recording_decoded_ratio':ratio}
