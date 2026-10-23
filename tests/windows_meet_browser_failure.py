"""Actual closed browser failure producers; no browser/server is launched."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('actual_meet_browser_failure', ROOT/'tests/windows-meet-browser.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class BrowserFailureControls(unittest.TestCase):
    def test_closed_values_copy_and_privacy(self):
        kinds = ['timeout', 'type', 'reference', 'range', 'security', 'invalid_state', 'not_supported', 'target_closed', 'other']
        operations = ['none', 'peer_lookup', 'stats', 'analyser_create', 'analyser_source', 'analyser_connect', 'analyser_output', 'spectrum', 'canvas_create', 'canvas_draw', 'canvas_read', 'complete']
        for kind in kinds:
            for operation in operations:
                row = dict(kind=kind, operation=operation)
                result = module.browser_failure_fields(row)
                self.assertEqual(result, {'meeting_browser_failure': row})
                self.assertIsNot(result['meeting_browser_failure'], row)
        for row in [None, [], {}, True, 'PRIVATE', {'kind':'type'}, {'operation':'stats'}, {'kind':1,'operation':'stats'}, {'kind':'type','operation':['stats']}, {'kind':'type','operation':'stats','raw':'PRIVATE'}, {'kind':'PRIVATE','operation':'stats'}, {'kind':'type','operation':'PRIVATE'}]:
            self.assertEqual(module.browser_failure_fields(row), {})
        self.assertNotIn('PRIVATE', json.dumps(module.browser_failure_fields({'kind':'type','operation':'stats'})))

    @unittest.skipUnless(shutil.which('node'), 'Node required for the actual closed CJS producer')
    def test_actual_inert_proof_stages_and_exception_classifier(self):
        result = subprocess.run([shutil.which('node'), str(ROOT/'tests/windows_meet_failure.cjs')], capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        proof = json.loads(result.stdout)
        self.assertEqual(proof['state'], 'passed')
        self.assertGreaterEqual(proof['checks'], 67)
        self.assertIs(proof['actual_proof_source'], True)
        self.assertIs(proof['actual_media_qualified'], False)
        self.assertIs(proof['network_or_server_changed'], False)


if __name__ == '__main__':
    unittest.main()
