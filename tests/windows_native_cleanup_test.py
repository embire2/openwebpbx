#!/usr/bin/env python3
"""Failure ownership controls; no Windows/PBX acceptance is inferred."""
import importlib.util
from pathlib import Path

spec=importlib.util.spec_from_file_location('native_cleanup',Path(__file__).with_name('windows-native-acceptance.py'))
native=importlib.util.module_from_spec(spec);spec.loader.exec_module(native)
checks=0
def check(value):
    global checks
    assert value;checks+=1

def raised(kind):
    try:raise kind('PRIVATE credential-shaped message must not enter facts')
    except BaseException as error:return error

ran=[];primary=raised(AssertionError);first=raised(RuntimeError)
def broken():ran.append('failed');raise first
native.native_cleanup(primary,'g729_answer_validation',[
    ('g729_alternate_unregister',broken),('g729_peer_close',lambda:ran.append('closed')),
    ('g729_regular_reregister',lambda:ran.append('restored'))])
check(ran==['failed','closed','restored'])
check(primary.native_failure['primary_error_type']=='AssertionError')
check(primary.native_failure['primary_substage']=='g729_answer_validation')
check(primary.native_failure['cleanup_error_type']=='RuntimeError')
check(primary.native_failure['cleanup_substage']=='g729_alternate_unregister')
check(primary.native_failure['cleanup_failure_count']==1)
check('PRIVATE' not in str(primary.native_failure))
native.native_cleanup(primary,'native_case',[('native_peer_unregister',broken),('native_peer_close',lambda:ran.append('outerclosed'))])
check(primary.native_failure['primary_substage']=='g729_answer_validation')
check(primary.native_failure['cleanup_substage']=='g729_alternate_unregister')
check(primary.native_failure['cleanup_failure_count']==2)
try:native.native_cleanup(None,'g729_media',[('g729_alternate_unregister',broken),('g729_peer_close',lambda:ran.append('afterfailure'))])
except RuntimeError as error:
    check(error is first)
    check(error.native_failure['primary_substage']=='g729_alternate_unregister')
else:raise AssertionError('Cleanup-only failure was hidden')
check(ran[-1]=='afterfailure')
check(native.native_exception_fields(primary,'unknown')=={})
check(native.native_cleanup(None,'native_case',[('native_peer_close',lambda:None)]) is None)
print(f'PASS {checks} native primary/cleanup preservation controls; no PBX contacted')
