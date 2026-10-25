"""Failure-only owned-Job observation; never changes the producer acceptance proof."""
import ctypes
import hashlib
import json
import os
from pathlib import Path, PureWindowsPath
import re
import time

CORE_SHA256 = 'afb20f0f207ce0928570d8afd8bee08e3b736bffd7f4e48d3f4aa8fae9fc30de'
MAX_PIDS = 16
BUDGET_MS = 100
# Exact direct raises in the unchanged pinned Job source. The error constructed
# at124 and later re-raised at145 deliberately stays unclassified.
ERRORS = {
    ('Owned disposable Windows process scope required.', 13): 'scope_refused',
    ('Owned process output exceeded its bound.', 92): 'parent_output_limit',
    ('Owned recorder process wait failed.', 95): 'parent_wait_refused',
    ('Owned descendant output exceeded its bound.', 102): 'descendant_output_limit',
    ('Recorder descendants survived ordinary closure.', 104): 'ordinary_descendants_survived',
    ('Exact owned suspended/active process survived cleanup.', 116): 'suspended_or_active_cleanup_refused',
    ('Owned job descendants survived termination.', 121): 'terminated_descendants_survived',
    ('Private recorder output exceeded its bound.', 151): 'final_output_limit',
}

def error_enum(error, core_path):
    if type(error) is not RuntimeError or len(error.args) != 1 or type(error.args[0]) is not str:
        return {'runtime_error': 'unclassified', 'core_origin_line': None}
    node = error.__traceback__
    last = None
    for _ in range(32):
        if node is None: break
        last = node
        node = node.tb_next
    if node is not None or last is None or last.tb_frame.f_code.co_filename != str(core_path):
        return {'runtime_error': 'unclassified', 'core_origin_line': None}
    value = ERRORS.get((error.args[0], last.tb_lineno))
    return {'runtime_error': value or 'unclassified', 'core_origin_line': last.tb_lineno if value else None}


def parsed_identity(pid, creation, image):
    if type(pid) is not int or not 0 < pid <= 0xffffffff or type(creation) is not int or not 0 < creation <= 0xffffffffffffffff:
        raise ValueError('Closed process identity required.')
    if type(image) is not str or not 1 <= len(image) <= 32768 or '\0' in image:
        raise ValueError('Bounded process image identity required.')
    name = PureWindowsPath(image).name
    return {'pid': pid, 'creation_filetime': creation,
            'image_basename': name if re.fullmatch(r'[A-Za-z0-9_.-]{1,128}', name) else 'unclassified'}


class NativeInspector:
    """Read-only kernel process/job queries, fixed capacity and cooperative budget.

    The original outer supervisor is the hard wall limit if a kernel query stalls.
    No command line, environment, token, file contents or global process list is read.
    """
    def __init__(self):
        if os.name != 'nt': raise ValueError('Native Windows observation only.')
        self.k = ctypes.WinDLL('kernel32', use_last_error=True)
        d = ctypes.c_uint32; b = ctypes.c_int32; h = ctypes.c_void_p
        class FT(ctypes.Structure): _fields_ = [('low', d), ('high', d)]
        class IDS(ctypes.Structure):
            _fields_ = [('assigned', d), ('listed', d), ('pids', ctypes.c_size_t * MAX_PIDS)]
        self.FT, self.IDS = FT, IDS
        signatures = {
            'QueryInformationJobObject': ([h, ctypes.c_int, h, d, ctypes.POINTER(d)], b),
            'OpenProcess': ([d, b, d], h), 'IsProcessInJob': ([h, h, ctypes.POINTER(b)], b),
            'GetProcessTimes': ([h, *([ctypes.POINTER(FT)] * 4)], b),
            'QueryFullProcessImageNameW': ([h, d, ctypes.c_wchar_p, ctypes.POINTER(d)], b),
            'GetProcessId': ([h], d), 'CloseHandle': ([h], b),
        }
        for name, (args, result) in signatures.items():
            f = getattr(self.k, name); f.argtypes, f.restype = args, result

    def __call__(self, job):
        start = time.monotonic(); deadline = start + BUDGET_MS / 1000
        result = {'state': 'unavailable', 'pid_capacity': MAX_PIDS, 'budget_ms': BUDGET_MS,
                  'assigned_count': None, 'listed_count': None, 'identities': [],
                  'unavailable_pids': [], 'process_handles_closed': True}
        row = self.IDS(); returned = ctypes.c_uint32()
        if not self.k.QueryInformationJobObject(job, 3, ctypes.byref(row), ctypes.sizeof(row), ctypes.byref(returned)):
            result['state'] = 'capacity_limit' if ctypes.get_last_error() == 234 else 'query_refused'
            return result
        result['assigned_count'], result['listed_count'] = int(row.assigned), int(row.listed)
        if row.assigned > MAX_PIDS or row.listed > MAX_PIDS or row.listed != row.assigned or not 8 + int(row.listed) * ctypes.sizeof(ctypes.c_size_t) <= returned.value <= ctypes.sizeof(row):
            result['state'] = 'capacity_limit'; return result
        pids = [int(x) for x in row.pids[:row.listed]]
        if len(pids) != len(set(pids)) or any(not 0 < x <= 0xffffffff for x in pids):
            result['state'] = 'identity_refused'; return result
        result['state'] = 'observed'
        for pid in pids:
            if time.monotonic() >= deadline:
                result['state'] = 'budget_limit'; break
            handle = self.k.OpenProcess(0x1000, False, pid)  # QUERY_LIMITED_INFORMATION only.
            if not handle:
                result['unavailable_pids'].append({'pid': pid, 'reason': 'open_refused_or_exited'}); continue
            try:
                member = ctypes.c_int32()
                if not self.k.IsProcessInJob(handle, job, ctypes.byref(member)) or not member.value or self.k.GetProcessId(handle) != pid:
                    result['unavailable_pids'].append({'pid': pid, 'reason': 'membership_changed_or_refused'}); continue
                if time.monotonic() >= deadline:
                    result['state'] = 'budget_limit'; break
                creation, exit_time, kernel, user = [self.FT() for _ in range(4)]
                if not self.k.GetProcessTimes(handle, *[ctypes.byref(x) for x in [creation, exit_time, kernel, user]]):
                    result['unavailable_pids'].append({'pid': pid, 'reason': 'creation_refused_or_exited'}); continue
                if time.monotonic() >= deadline:
                    result['state'] = 'budget_limit'; break
                image = ctypes.create_unicode_buffer(32769); size = ctypes.c_uint32(32768)
                if not self.k.QueryFullProcessImageNameW(handle, 0, image, ctypes.byref(size)) or size.value > 32768:
                    result['unavailable_pids'].append({'pid': pid, 'reason': 'image_refused_or_exited'}); continue
                if time.monotonic() >= deadline:
                    result['state'] = 'budget_limit'; break
                # Recheck exact Job membership after reading identity; PID alone is never ownership.
                if not self.k.IsProcessInJob(handle, job, ctypes.byref(member)) or not member.value:
                    result['unavailable_pids'].append({'pid': pid, 'reason': 'membership_changed_or_refused'}); continue
                result['identities'].append(parsed_identity(pid, (creation.high << 32) | creation.low, image.value))
            finally:
                if not self.k.CloseHandle(handle):
                    result['process_handles_closed'] = False; result['state'] = 'handle_close_refused'
        if time.monotonic() >= deadline and result['state'] == 'observed': result['state'] = 'budget_limit'
        return result


class DelegatedFunction:
    def __init__(self, original, invoke): self.original, self.invoke = original, invoke
    @property
    def argtypes(self): return self.original.argtypes
    @argtypes.setter
    def argtypes(self, value): self.original.argtypes = value
    @property
    def restype(self): return self.original.restype
    @restype.setter
    def restype(self, value): self.original.restype = value
    def __call__(self, *args): return self.invoke(self.original, args)


class FailureObserver:
    def __init__(self, module, core_path, inspector=None):
        self.module, self.core_path = module, Path(core_path)
        self.original_ctypes = module.ctypes
        self.inspector = inspector
        self.owned_job = None
        self.create_count = 0
        self.termination_count = 0
        self.snapshot = None
        self.proxy = None

    def created(self, original, args):
        value = original(*args)
        try:
            self.create_count += 1
            if self.create_count == 1 and args == (None, None) and value:
                self.owned_job = value
        except BaseException:
            self.snapshot = {'state': 'observer_refused'}
        return value

    def terminating(self, original, args):
        # Save/restore ctypes' private Win32 last-error slot. Queries must not change
        # the original API call's error semantics or suppress/change its return.
        saved = None
        try:
            saved = self.original_ctypes.get_last_error()
            self.termination_count += 1
            if self.create_count == 1 and self.termination_count == 1 and self.owned_job is not None and args == (self.owned_job, 1):
                inspector = self.inspector if self.inspector is not None else NativeInspector()
                self.snapshot = inspector(self.owned_job)
            else:
                self.snapshot = {'state': 'job_ownership_refused'}
        except BaseException:
            self.snapshot = {'state': 'observer_refused'}
        finally:
            try:
                if saved is not None: self.original_ctypes.set_last_error(saved)
            except BaseException:
                self.snapshot = {'state': 'last_error_restore_refused'}
        return original(*args)  # ALWAYS exactly one unchanged original termination call.

    def install(self):
        outer = self
        class KernelProxy:
            def __init__(self, real):
                self.real = real
                self.create = DelegatedFunction(real.CreateJobObjectW, outer.created)
                self.terminate = DelegatedFunction(real.TerminateJobObject, outer.terminating)
            def __getattr__(self, name):
                if name == 'CreateJobObjectW': return self.create
                if name == 'TerminateJobObject': return self.terminate
                return getattr(self.real, name)
        class CtypesProxy:
            def __getattr__(self, name): return getattr(outer.original_ctypes, name)
            def WinDLL(self, name, **kwargs):
                real = outer.original_ctypes.WinDLL(name, **kwargs)
                return KernelProxy(real) if name == 'kernel32' and kwargs == {'use_last_error': True} else real
        self.proxy = CtypesProxy(); self.module.ctypes = self.proxy

    def restore(self):
        self.module.ctypes = self.original_ctypes

    def record_failure(self, error, directory, request_sha256):
        observation = {'schema': 1, 'state': 'failure_only_observation',
                       'core_sha256': CORE_SHA256, 'observer_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                       'request_sha256': request_sha256, **error_enum(error, self.core_path),
                       'pre_termination': self.snapshot or {'state': 'not_observed'},
                       'acceptance_or_cleanup_proof': False}
        raw = json.dumps(observation, separators=(',', ':')).encode()
        if len(raw) > 16384: return False
        try:
            with (Path(directory) / 'failure-observation.safe.json').open('xb') as f:
                f.write(raw); f.flush(); os.fsync(f.fileno())
            return True
        except BaseException:
            return False  # Original failure remains; missing diagnostic never becomes acceptance.
