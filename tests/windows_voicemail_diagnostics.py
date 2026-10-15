#!/usr/bin/env python3
"""Exact voicemail stage/privacy controls using local files, never a PBX."""
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import wave

spec=importlib.util.spec_from_file_location('native_voicemail',Path(__file__).with_name('windows-native-acceptance.py'))
native=importlib.util.module_from_spec(spec);spec.loader.exec_module(native)
checks=0
def check(value):
    global checks
    assert value;checks+=1

stages=('voicemail_message_created','voicemail_recording_finalized','voicemail_mail_queued')
for stage,seconds in zip(stages,(20,15,15)):
    error=AssertionError('PRIVATE message /path/to/uuid/audio')
    class Failed:
        def wait(self,predicate,timeout):check(timeout==seconds);raise error
    f=Failed()
    try:native.voicemail_wait(f,stage,lambda:False,seconds)
    except AssertionError as failure:
        check(failure is error and f.native_substage==stage)
        check(error.native_failure['primary_substage']==stage and error.native_failure['primary_error_type']=='AssertionError')
        check('PRIVATE' not in json.dumps(error.native_failure))
        def broken():raise RuntimeError('PRIVATE cleanup')
        ran=[];native.native_cleanup(error,'native_case',[('native_peer_close',broken),('native_ledger_write',lambda:ran.append(True))])
        check(error.native_failure['primary_substage']==stage and error.native_failure['cleanup_substage']=='native_peer_close' and ran==[True])
    else:raise AssertionError('Voicemail wait failure was hidden')
try:native.voicemail_wait(SimpleNamespace(),'PRIVATE',lambda:True,1)
except AssertionError:check(True)
else:raise AssertionError('Unknown voicemail stage was accepted')

with tempfile.TemporaryDirectory() as folder:
    root=Path(folder);realm='pbx-0123456789ab.example.invalid'
    directory=root/'storage/voicemail/default'/realm/'8103';directory.mkdir(parents=True)
    path=directory/'msg_11111111-1111-4111-8111-111111111111.wav'
    status={'voicemail':[],'mail':[]}
    f=SimpleNamespace(s={'private_state_root':str(root),'realm':realm},cli=lambda action:status)
    facts,complete=native.voicemail_snapshot(f,'before')
    check(complete and facts=={'voicemail_before_message_count':0,'voicemail_before_mail_count':0,'voicemail_before_wav_count':0,'voicemail_before_wav_any_size_gt4096':False,'voicemail_before_wav_any_header_finalized':False})
    with wave.open(str(path),'wb') as wav:wav.setnchannels(1);wav.setsampwidth(2);wav.setframerate(8000);wav.writeframes(bytes(8000))
    facts,complete=native.voicemail_snapshot(f,'after')
    check(complete and facts['voicemail_after_message_count']==0 and facts['voicemail_after_wav_count']==1)
    check(facts['voicemail_after_wav_any_size_gt4096'] and facts['voicemail_after_wav_any_header_finalized'] and 'voicemail_after_recording_exists' not in facts)
    status['voicemail']=[{'voicemail_id':'8103','message_path':str(path),'voicemail_message_uuid':'PRIVATE_UUID','message':'PRIVATE_MESSAGE'}, {'voicemail_id':'8102','message_path':'PRIVATE_FOREIGN'}]
    status['mail']=[{'email_queue_uuid':'PRIVATE_UUID','message':'PRIVATE_MAIL'}]
    facts,complete=native.voicemail_snapshot(f,'after')
    check(complete and facts['voicemail_after_message_count']==1 and facts['voicemail_after_mail_count']==1)
    check(all(facts['voicemail_after_'+key] for key in ('recording_exists','recording_size_gt4096','recording_header_finalized')))
    check(all(type(value) in (int,bool) for value in facts.values()) and not any(value in json.dumps(facts) for value in ('PRIVATE',str(root),'11111111')))
    data=path.read_bytes();path.write_bytes(data[:4]+bytes(4)+data[8:])
    facts,complete=native.voicemail_snapshot(f,'after');check(complete and facts['voicemail_after_recording_exists'] and not facts['voicemail_after_recording_header_finalized'])
    path.write_bytes(b'RIFF'+bytes(4)+b'WAVE')
    facts,complete=native.voicemail_snapshot(f,'after');check(complete and not facts['voicemail_after_recording_size_gt4096'] and not facts['voicemail_after_recording_header_finalized'])
    path.unlink();facts,complete=native.voicemail_snapshot(f,'after');check(complete and not facts['voicemail_after_recording_exists'] and facts['voicemail_after_wav_count']==0)
    foreign=root/'PRIVATE_FOREIGN.wav';foreign.write_bytes(data);path.symlink_to(foreign)
    facts,complete=native.voicemail_snapshot(f,'after');check(not complete and 'voicemail_after_wav_count' not in facts)
    path.unlink();directory.rmdir();directory.symlink_to(root,target_is_directory=True)
    facts,complete=native.voicemail_snapshot(f,'after');check(not complete and 'voicemail_after_wav_count' not in facts)
    directory.unlink();directory.mkdir()
    for index in range(65):(directory/('ignored-'+str(index))).touch()
    facts,complete=native.voicemail_snapshot(f,'after');check(not complete and 'voicemail_after_wav_count' not in facts)
    status['voicemail']=[{}]*65;facts,complete=native.voicemail_snapshot(f,'after');check(not complete and facts=={})
    f.s['realm']='../PRIVATE';status['voicemail']=[];facts,complete=native.voicemail_snapshot(f,'after');check(not complete and 'voicemail_after_wav_count' not in facts)

source=Path(__file__).with_name('windows-native-acceptance.py').read_text()
for stage,seconds in zip(stages,(20,15,15)):check(("voicemail_wait(f,'"+stage+"'") in source)
check('time.sleep(32);caller.hangup(call)' in source)
print(f'PASS {checks} actual local-file voicemail stage/primary-cleanup/scoped scan/privacy controls; no PBX contacted')
