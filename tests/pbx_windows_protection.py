#!/usr/bin/env python3
"""Shared tenant policy against the Windows worker and disposable PostgreSQL.

Native ACL/service calls still need actual Windows qualification. This runner
never connects to Main: it supplies the independent backup suite's own cluster.
"""
import importlib.util
from pathlib import Path
import runpy
import sys

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('windows_backup_fixture',ROOT/'tests/pbx_windows_backups.py')
fixture=importlib.util.module_from_spec(spec);spec.loader.exec_module(fixture)
fixture.WindowsBackups.setUpClass()
try:
    sys.modules['backups']=fixture.b
    fixture.b.read_settings=lambda *args,**kwargs:fixture.WindowsBackups.source.copy()
    runpy.run_path(str(ROOT/'tests/pbx_protection.py'),run_name='__main__')
finally:
    fixture.WindowsBackups.tearDownClass()
