"""QA-only restore-startup acquisition; real guarded body executes once.

The live backend can legitimately hold a short CDR read lease. This helper
retries only a typed BackupBusy raised while entering the existing guard.
"""
import contextlib
import math
import time
import types
import unittest

DEADLINE_SECONDS = 30.0
INTERVAL_SECONDS = 0.1


@contextlib.contextmanager
def acquire(module, path, *, seconds=DEADLINE_SECONDS, interval=INTERVAL_SECONDS,
            clock=time.monotonic, sleep=time.sleep):
    if (type(seconds) not in (int, float) or not math.isfinite(seconds) or seconds <= 0 or seconds > 30
            or type(interval) not in (int, float) or not math.isfinite(interval) or interval <= 0 or interval > 1):
        raise ValueError('The qualification acquisition budget is invalid.')
    deadline = clock() + seconds
    last_busy = None
    last_traceback = None
    while True:
        if last_busy is not None and clock() >= deadline:
            raise last_busy.with_traceback(last_traceback)
        stack = contextlib.ExitStack()
        try:
            stack.enter_context(module.exclusive_guard(path))
        except module.BackupBusy as error:
            stack.close()
            last_busy, last_traceback = error, error.__traceback__
            remaining = deadline - clock()
            if remaining <= 0:
                raise  # Keep this actual native refusal and its original traceback.
            sleep(min(interval, remaining))
        except BaseException:
            stack.close()
            raise
        else:
            if clock() >= deadline:
                stack.close()
                if last_busy is not None:
                    raise last_busy.with_traceback(last_traceback)
                raise TimeoutError('The qualification acquisition deadline expired before its body.')
            break
    # Deliberately outside the acquisition catch. Even a BackupBusy from the
    # protected operation propagates once and never repeats an operation.
    with stack:
        yield


class AcquisitionControls(unittest.TestCase):
    def module(self, refusals):
        class Busy(RuntimeError):
            pass
        state = {'entries': 0, 'releases': 0, 'time': 0.0, 'sleeps': []}

        @contextlib.contextmanager
        def guard(path):
            state['entries'] += 1
            if refusals:
                failure = refusals.pop(0)
                if failure is not None:
                    raise failure
            try:
                yield
            finally:
                state['releases'] += 1

        def sleep(value):
            state['sleeps'].append(value)
            state['time'] += value

        module = types.SimpleNamespace(BackupBusy=Busy, exclusive_guard=guard)
        return module, state, lambda: state['time'], sleep

    def test_busy_then_free_enters_body_once_and_releases(self):
        failures = []
        module, state, clock, sleep = self.module(failures)
        failures.extend([module.BackupBusy('first'), module.BackupBusy('second'), None])
        body = []
        with acquire(module, 'owned', clock=clock, sleep=sleep):
            body.append('once')
        self.assertEqual((body, state['entries'], state['releases']), (['once'], 3, 1))
        self.assertEqual(state['sleeps'], [.1, .1])

    def test_deadline_retains_exact_final_native_exception_without_body(self):
        failures = []
        module, state, clock, sleep = self.module(failures)
        first, last = module.BackupBusy('first'), module.BackupBusy('final native refusal')
        failures.extend([first, last, module.BackupBusy('must not attempt after deadline')])
        with self.assertRaises(module.BackupBusy) as raised:
            with acquire(module, 'owned', seconds=.2, clock=clock, sleep=sleep):
                self.fail('A contended operation body must not run.')
        self.assertIs(raised.exception, last)
        self.assertEqual((state['entries'], state['releases'], state['time']), (2, 0, .2))

    def test_permission_or_path_error_is_never_retried(self):
        for error in (PermissionError('permission'), FileNotFoundError('path'), ValueError('identity')):
            with self.subTest(kind=type(error).__name__):
                module, state, clock, sleep = self.module([error])
                with self.assertRaises(type(error)) as raised:
                    with acquire(module, 'owned', clock=clock, sleep=sleep):
                        self.fail('An invalid acquisition cannot enter its body.')
                self.assertIs(raised.exception, error)
                self.assertEqual((state['entries'], state['releases'], state['sleeps']), (1, 0, []))

    def test_guarded_busy_and_other_body_errors_are_not_retried_or_relabelled(self):
        for kind in ('busy', 'other'):
            module, state, clock, sleep = self.module([])
            error = module.BackupBusy('original body') if kind == 'busy' else RuntimeError('original body')
            body = []
            with self.assertRaises(type(error)) as raised:
                with acquire(module, 'owned', clock=clock, sleep=sleep):
                    body.append(1)
                    raise error
            self.assertIs(raised.exception, error)
            self.assertEqual((body, state['entries'], state['releases'], state['sleeps']), ([1], 1, 1, []))

    def test_sleep_never_exceeds_remaining_budget(self):
        failures = []
        module, state, clock, sleep = self.module(failures)
        error = module.BackupBusy('held')
        failures.extend([error] * 3)
        with self.assertRaises(module.BackupBusy):
            with acquire(module, 'owned', seconds=.15, clock=clock, sleep=sleep):
                self.fail('The lease remains held.')
        self.assertEqual(len(state['sleeps']), 2)
        self.assertAlmostEqual(sum(state['sleeps']), .15)
        self.assertAlmostEqual(state['sleeps'][1], .05)

    def test_malformed_budget_refuses_before_native_guard(self):
        for value in (True, 0, -1, 31, float('nan'), float('inf'), '30'):
            module, state, clock, sleep = self.module([])
            with self.subTest(value=str(value)), self.assertRaises(ValueError):
                with acquire(module, 'owned', seconds=value, clock=clock, sleep=sleep):
                    self.fail('An invalid budget cannot run.')
            self.assertEqual(state['entries'], 0)

    def test_expired_budget_cannot_acquire_a_newly_free_lock(self):
        failures = []
        module, state, clock, sleep = self.module(failures)
        original = module.BackupBusy('last actual native refusal')
        failures.extend([original, None])
        with self.assertRaises(module.BackupBusy) as raised:
            with acquire(module, 'owned', seconds=.1, clock=clock, sleep=sleep):
                self.fail('The retry deadline has already passed.')
        self.assertIs(raised.exception, original)
        self.assertEqual((state['entries'], state['releases']), (1, 0))


if __name__ == '__main__':
    unittest.main()
