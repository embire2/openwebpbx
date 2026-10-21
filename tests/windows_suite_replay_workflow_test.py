"""Evaluate the actual bounded job expression; no runner or PBX is invoked."""
from pathlib import Path
import itertools
import re
import unittest


class ReplayRouting(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = (Path(__file__).resolve().parents[1] / '.github/workflows/windows-suite.yml').read_text()
        cls.music = re.search(r'(?m)^  music:\n    if: \$\{\{ (.*?) \}\}$', source)[1]
        cls.suite = re.search(r'(?m)^  suite:\n    needs: music\n    if: \$\{\{ (.*?) \}\}$', source)[1]

    def evaluate(self, expression, replay, result, cancelled):
        # This exact allowlist forbids arbitrary source execution in the test.
        expected = {
            "inputs.replay_suite_run_id == ''",
            "always() && !cancelled() && (needs.music.result == 'success' || (needs.music.result == 'skipped' && inputs.replay_suite_run_id != ''))",
        }
        self.assertIn(expression, expected)
        value = expression.replace('inputs.replay_suite_run_id', repr(replay)).replace('needs.music.result', repr(result))
        value = value.replace('always()', 'True').replace('!cancelled()', repr(not cancelled)).replace('&&', 'and').replace('||', 'or')
        return eval(value, {'__builtins__': {}}, {})

    def test_exact_job_truth_table(self):
        for replay, result, cancelled in itertools.product(['', '39656143054'], ['success', 'failure', 'cancelled', 'skipped'], [False, True]):
            with self.subTest(replay=bool(replay), result=result, cancelled=cancelled):
                self.assertEqual(self.evaluate(self.music, replay, result, cancelled), not bool(replay))
                expected = not cancelled and (result == 'success' or (result == 'skipped' and bool(replay)))
                self.assertEqual(self.evaluate(self.suite, replay, result, cancelled), expected)


if __name__ == '__main__':
    unittest.main()
