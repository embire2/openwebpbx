"""QA-only Windows job: attach a suspended child before it can spawn descendants."""
import ctypes
from ctypes import wintypes as w
import os
import json
from pathlib import Path
import subprocess
import time


def run(command, directory, timeout=240):
    if os.name != 'nt' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted' or os.environ.get('GITHUB_REPOSITORY') != 'embire2/openwebpbx':
        raise RuntimeError('Owned disposable Windows process scope required.')
    if not isinstance(command, list) or not command or any(type(x) is not str or '\0' in x for x in command) or timeout != 240:
        raise ValueError('Exact bounded browser command required.')
    directory = Path(directory)
    if not directory.is_dir() or directory.is_symlink():
        raise ValueError('Existing private process evidence directory required.')
    k = ctypes.WinDLL('kernel32', use_last_error=True)
    SIZE = ctypes.c_size_t
    class SA(ctypes.Structure):
        _fields_ = [('length', w.DWORD), ('descriptor', w.LPVOID), ('inherit', w.BOOL)]
    class SI(ctypes.Structure):
        _fields_ = [('cb', w.DWORD), ('reserved', w.LPWSTR), ('desktop', w.LPWSTR), ('title', w.LPWSTR),
                   ('x', w.DWORD), ('y', w.DWORD), ('xs', w.DWORD), ('ys', w.DWORD), ('xc', w.DWORD), ('yc', w.DWORD),
                   ('fill', w.DWORD), ('flags', w.DWORD), ('show', w.WORD), ('reserved2size', w.WORD),
                   ('reserved2', ctypes.POINTER(ctypes.c_byte)), ('stdin', w.HANDLE), ('stdout', w.HANDLE), ('stderr', w.HANDLE)]
    class PI(ctypes.Structure):
        _fields_ = [('process', w.HANDLE), ('thread', w.HANDLE), ('pid', w.DWORD), ('tid', w.DWORD)]
    class BASIC(ctypes.Structure):
        _fields_ = [('process_time', ctypes.c_longlong), ('job_time', ctypes.c_longlong), ('flags', w.DWORD),
                   ('min_working', SIZE), ('max_working', SIZE), ('active_limit', w.DWORD), ('affinity', SIZE), ('priority', w.DWORD), ('scheduling', w.DWORD)]
    class IO(ctypes.Structure):
        _fields_ = [(x, ctypes.c_ulonglong) for x in ('read_ops', 'write_ops', 'other_ops', 'read_bytes', 'write_bytes', 'other_bytes')]
    class EXT(ctypes.Structure):
        _fields_ = [('basic', BASIC), ('io', IO), ('process_memory', SIZE), ('job_memory', SIZE), ('peak_process', SIZE), ('peak_job', SIZE)]
    class ACCOUNT(ctypes.Structure):
        _fields_ = [('user', ctypes.c_longlong), ('kernel', ctypes.c_longlong), ('period_user', ctypes.c_longlong),
                   ('period_kernel', ctypes.c_longlong), ('faults', w.DWORD), ('total', w.DWORD), ('active', w.DWORD), ('terminated', w.DWORD)]
    signatures = {
        'CreateJobObjectW': ([ctypes.POINTER(SA), w.LPCWSTR], w.HANDLE),
        'SetInformationJobObject': ([w.HANDLE, ctypes.c_int, w.LPVOID, w.DWORD], w.BOOL),
        'QueryInformationJobObject': ([w.HANDLE, ctypes.c_int, w.LPVOID, w.DWORD, w.LPVOID], w.BOOL),
        'AssignProcessToJobObject': ([w.HANDLE, w.HANDLE], w.BOOL),
        'TerminateJobObject': ([w.HANDLE, w.UINT], w.BOOL),
        'CreateFileW': ([w.LPCWSTR, w.DWORD, w.DWORD, ctypes.POINTER(SA), w.DWORD, w.DWORD, w.HANDLE], w.HANDLE),
        'CreateProcessW': ([w.LPCWSTR, w.LPWSTR, w.LPVOID, w.LPVOID, w.BOOL, w.DWORD, w.LPVOID, w.LPCWSTR, ctypes.POINTER(SI), ctypes.POINTER(PI)], w.BOOL),
        'ResumeThread': ([w.HANDLE], w.DWORD), 'WaitForSingleObject': ([w.HANDLE, w.DWORD], w.DWORD),
        'GetExitCodeProcess': ([w.HANDLE, ctypes.POINTER(w.DWORD)], w.BOOL),
        'TerminateProcess': ([w.HANDLE, w.UINT], w.BOOL), 'CloseHandle': ([w.HANDLE], w.BOOL),
    }
    for name, (args, returns) in signatures.items():
        getattr(k, name).argtypes = args; getattr(k, name).restype = returns
    def checked(value):
        if not value: raise ctypes.WinError(ctypes.get_last_error())
        return value
    handles = []; job = None; process = PI(); assigned = False; primary = None; clean = False; result = None; handle_close_failed = False; resumed = False; terminated = False
    streams = [directory / 'stdout.private.log', directory / 'stderr.private.log']
    def active():
        row = ACCOUNT(); checked(k.QueryInformationJobObject(job, 1, ctypes.byref(row), ctypes.sizeof(row), None)); return row.active
    def close_process():
        nonlocal handle_close_failed
        for name in ('thread', 'process'):
            handle = getattr(process, name)
            if handle:
                setattr(process, name, None)
                if not k.CloseHandle(handle):
                    handle_close_failed = True
                    raise ctypes.WinError(ctypes.get_last_error())
    try:
        job = checked(k.CreateJobObjectW(None, None))
        limits = EXT(); limits.basic.flags = 0x2000  # KILL_ON_JOB_CLOSE; never permit breakaway.
        checked(k.SetInformationJobObject(job, 9, ctypes.byref(limits), ctypes.sizeof(limits)))
        security = SA(ctypes.sizeof(SA), None, True)
        for path in ['NUL', *map(str, streams)]:
            handle = k.CreateFileW(path, 0x80000000 if path == 'NUL' else 0x40000000, 1, ctypes.byref(security), 3 if path == 'NUL' else 1, 0x80, None)
            if handle == ctypes.c_void_p(-1).value: raise ctypes.WinError(ctypes.get_last_error())
            handles.append(handle)
        startup = SI(); startup.cb = ctypes.sizeof(SI); startup.flags = 0x100
        startup.stdin, startup.stdout, startup.stderr = handles
        command_line = ctypes.create_unicode_buffer(subprocess.list2cmdline(command))
        checked(k.CreateProcessW(command[0], command_line, None, None, True, 0x08000004, None, None, ctypes.byref(startup), ctypes.byref(process)))
        checked(k.AssignProcessToJobObject(job, process.process)); assigned = True
        if k.ResumeThread(process.thread) == 0xffffffff: raise ctypes.WinError(ctypes.get_last_error())
        resumed = True
        deadline = time.monotonic() + timeout
        while True:
            status = k.WaitForSingleObject(process.process, 100)
            if any(path.stat().st_size > 8 * 1024**2 for path in streams): raise RuntimeError('Owned process output exceeded its bound.')
            if status != 258: break
            if time.monotonic() >= deadline: raise subprocess.TimeoutExpired(command, timeout)
        if status != 0: raise RuntimeError('Owned browser process wait failed.')
        code = w.DWORD(); checked(k.GetExitCodeProcess(process.process, ctypes.byref(code)))
        result = code.value
        close_process()
        deadline = time.monotonic() + 10
        while active() and time.monotonic() < deadline: time.sleep(.05)
        if active(): raise RuntimeError('Browser descendants survived ordinary closure.')
        clean = True; result = code.value
    except BaseException as error:
        primary = error
    finally:
        try:
            if assigned and active():
                terminated = True
                checked(k.TerminateJobObject(job, 1))
            elif process.process and not assigned:
                checked(k.TerminateProcess(process.process, 1))
            if process.process and k.WaitForSingleObject(process.process, 5000) != 0:
                raise RuntimeError('Exact owned suspended/active process survived cleanup.')
            close_process()
            if assigned:
                deadline = time.monotonic() + 5
                while active() and time.monotonic() < deadline: time.sleep(.05)
                if active(): raise RuntimeError('Owned job descendants survived termination.')
            clean = not handle_close_failed
            if handle_close_failed:
                if primary is None: primary = RuntimeError('An owned process handle did not close.')
                primary.owned_process_cleanup_failed = True
        except BaseException as error:
            if primary is None: primary = error
            else: primary.owned_process_cleanup_failed = True
        finally:
            for handle in [process.thread, process.process, *handles, job]:
                if handle and not k.CloseHandle(handle):
                    handle_close_failed = True
                    clean = False
                    if primary is None: primary = ctypes.WinError(ctypes.get_last_error())
                    primary.owned_process_cleanup_failed = True
    try:
        with (directory / 'process.safe.json').open('x', encoding='utf-8') as proof:
            json.dump({'schema': 1, 'created_suspended': bool(process.pid), 'assigned_before_resume': assigned,
                       'resumed': resumed, 'owned_job_terminated': terminated, 'exit_code': result,
                       'owned_processes_closed': clean, 'handles_closed': not handle_close_failed,
                       'ordinary_exit': primary is None}, proof)
    except BaseException as error:
        if primary is None: primary = error
    if primary is not None:
        primary.owned_processes_closed = clean
        raise primary
    output = []
    for path in streams:
        if path.stat().st_size > 8 * 1024**2: raise RuntimeError('Private browser output exceeded its bound.')
        output.append(path.read_text(encoding='utf-8', errors='replace'))
    return subprocess.CompletedProcess(command, result, *output)
