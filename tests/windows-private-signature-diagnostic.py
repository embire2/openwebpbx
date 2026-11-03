#!/usr/bin/env python3
"""Closed diagnostics for the unchanged, guarded private signature CLI only."""
import json
from pathlib import Path
import re
import runpy
import sys

def signature_failure(error):
    """Closed validate-only telemetry; never export messages, paths or values."""
    kinds = {'ValueError', 'RuntimeError', 'ImportError', 'ModuleNotFoundError',
             'FileNotFoundError', 'PermissionError', 'IsADirectoryError', 'NotADirectoryError',
             'OSError', 'UnicodeDecodeError', 'JSONDecodeError', 'KeyError', 'TypeError',
             'AttributeError', 'InvalidSignature', 'Error'}
    kind = type(error).__name__
    if kind not in kinds:
        kind = 'OtherError'
    reason = {'ImportError': 'dependency_import', 'ModuleNotFoundError': 'dependency_import',
              'InvalidSignature': 'signature_invalid', 'JSONDecodeError': 'metadata_json',
              'UnicodeDecodeError': 'metadata_encoding', 'KeyError': 'python_shape',
              'TypeError': 'python_shape', 'AttributeError': 'python_shape',
              'FileNotFoundError': 'input_io', 'PermissionError': 'input_io',
              'IsADirectoryError': 'input_io', 'NotADirectoryError': 'input_io',
              'OSError': 'input_io'}.get(kind, 'unknown')
    if type(error) in (ValueError, RuntimeError):
        reason = {'Explicit disposable hosted Windows updater runner required.': 'runner_guard',
                  'The private owned updater input path is required.': 'input_guard',
                  'The exact owned qualification identity is required.': 'input_guard',
                  'Root-reviewed canary provenance bytes differ.': 'provenance_bytes',
                  'The independently captured actual target facts differ from Root review.': 'target_facts_bytes',
                  'The actual full-suite candidate source/run/facts differ.': 'target_identity',
                  'The private signed feed is not current.': 'feed_time',
                  'The production asset URL/version validators must remain intact.': 'asset_contract',
                  'The root-reviewed complete archive checksum or size differs.': 'archive_integrity'}.get(str(error), reason)
    source, line = 'external_component', 0
    frame = error.__traceback__
    while frame is not None:
        name = re.split(r'[/\\]', frame.tb_frame.f_code.co_filename)[-1]
        if name in {'windows-updater-fixture.py', 'windows-actual-candidate-preparation.py',
                    'windows-canary-preparation.py', 'windows_candidate_archive.py'} and 1 <= frame.tb_lineno <= 100000:
            source, line = name, frame.tb_lineno
        frame = frame.tb_next
    return {'schema': 1, 'producer': 'windows-private-signature-validation', 'state': 'failed',
            'exception_type': kind, 'reason': reason, 'source_basename': source, 'source_line': line}


def main():
    arguments = sys.argv[1:]
    if len(arguments) != 4 or arguments[0] != '--input' or arguments[2:] != ['--action', 'validate']:
        raise ValueError('Only the exact private signature validate invocation is allowed.')
    source = Path(__file__).with_name('windows-updater-fixture.py')
    original = sys.argv
    try:
        sys.argv = [str(source), *arguments]
        runpy.run_path(str(source), run_name='__main__')
    finally:
        sys.argv = original


if __name__ == '__main__':
    try:
        main()
    except SystemExit as error:
        if error.code not in (None, 0):
            cause = error.__context__ if isinstance(error.__context__, Exception) else error
            print(json.dumps(signature_failure(cause), separators=(',', ':')), flush=True)
        raise
    except Exception as error:
        print(json.dumps(signature_failure(error), separators=(',', ':')), flush=True)
        raise
