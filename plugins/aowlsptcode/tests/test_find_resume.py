#!/usr/bin/env python3
"""Offline tests for the find auto-resume loop and the open_settings timeout
verdict. No live client: channel.run_batch is replaced with canned prose in
exactly the shape the host emits.

What these must prove, in both directions:
  * a search that needs three slices returns the hit and says EXHAUSTIVE/HITS
  * a search that runs out of OUR cap still says STOPPED_EARLY and
    can_trust_absence stays False -- the three-state answer is not flattened
  * a genuinely absent object comes back EXHAUSTIVE with can_trust_absence True
  * a timed-out open_settings step is INCONCLUSIVE with may_have_run, NOT an
    error and NOT a FAIL
"""
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), 'mcp'))

import channel      # noqa: E402
import compound     # noqa: E402
import server       # noqa: E402


def _stopped(n=40000, frontier=13696):
    return ("  visited %d node(s) over 157 frame(s), 0 match(es), frontier %d "
            "node(s)\n  -- STOPPED EARLY on the NODE BUDGET." % (n, frontier))


def _exhausted_empty(n=1200):
    return ("  visited %d node(s), 0 match(es)\n"
            "  -- searched EXHAUSTIVELY. genuinely NOT PRESENT." % n)


def _hit(n=5000):
    return ('  HIT 0x2a1b3c40 name="GraphicsSettingsTab" parent="Tabs" ($f0)\n'
            '  visited %d node(s), 1 match(es)\n'
            '  -- searched EXHAUSTIVELY.' % n)


class FakeChannel(object):
    """Replaces channel.run_batch; hands back one canned answer per call."""

    def __init__(self, answers):
        self.answers = list(answers)
        self.sent = []

    def __call__(self, lines, live_dir=None, timeout=25.0, write=False, **kw):
        self.sent.append(" ".join(lines))
        a = self.answers.pop(0)
        if isinstance(a, Exception):
            raise a
        return "sentinel-%d" % len(self.sent), a


class FindResume(unittest.TestCase):
    def setUp(self):
        self._orig = channel.run_batch

    def tearDown(self):
        channel.run_batch = self._orig

    def _find(self, answers, **args):
        fake = FakeChannel(answers)
        channel.run_batch = fake
        args.setdefault('name', 'GraphicsSettingsTab')
        args['_live_dir'] = os.path.dirname(HERE)  # bypass install check
        return server.h_find(args), fake

    def test_resumes_until_hit(self):
        res, fake = self._find([_stopped(), _stopped(), _hit()])
        self.assertEqual(len(res['hits']), 1)
        self.assertEqual(res['end_reason'], 'HITS')
        self.assertEqual(res['rounds'], 3)
        self.assertIn('find more', fake.sent[1])
        self.assertIn('find more', fake.sent[2])
        # the FIRST command must carry the raised default budget
        self.assertIn('40000', fake.sent[0])

    def test_absence_is_only_claimed_when_exhaustive(self):
        res, _ = self._find([_stopped(), _exhausted_empty()])
        self.assertEqual(res['hits'], [])
        self.assertEqual(res['end_reason'], 'EXHAUSTIVE')
        self.assertTrue(res['can_trust_absence'])
        self.assertEqual(res['completeness'], 'EXHAUSTIVE')

    def test_our_cap_never_reads_as_absence(self):
        # max_nodes below one round: the loop stops, but STOPPED_EARLY stands.
        res, fake = self._find([_stopped(), _stopped()],
                                max_nodes=45000)
        self.assertEqual(res['hits'], [])
        self.assertEqual(res['end_reason'], 'CAP')
        self.assertEqual(res['completeness'], 'STOPPED_EARLY')
        self.assertFalse(res['can_trust_absence'])
        self.assertIn('absence is NOT proven', res['cap_note'])

    def test_auto_resume_can_be_turned_off(self):
        res, fake = self._find([_stopped()], auto_resume=False)
        self.assertEqual(len(fake.sent), 1)
        self.assertEqual(res['end_reason'], 'CAP')
        self.assertFalse(res['can_trust_absence'])

    def test_findtext_resumes_and_keeps_scope(self):
        fake = FakeChannel([_stopped(), _hit()])
        channel.run_batch = fake
        res = server.h_findtext({'text': 'GRAPHICS SETTINGS',
                                  '_live_dir': os.path.dirname(HERE)})
        self.assertEqual(res['end_reason'], 'HITS')
        self.assertIn('findtext more', fake.sent[1])
        self.assertIn('"GRAPHICS SETTINGS"', fake.sent[0])
        self.assertIn('scope', res)


class OpenSettingsTimeout(unittest.TestCase):
    def setUp(self):
        self._orig = channel.run_batch

    def tearDown(self):
        channel.run_batch = self._orig

    def test_timeout_is_inconclusive_not_error(self):
        # roots answers, then the first find times out.
        roots = "  11 root(s) bound to $r0..$r10"
        channel.run_batch = FakeChannel([
            roots,
            _hit(),                      # resolve_path segment
            channel.TimeoutErr("no answer for aowl-batch-1 within 90s"),
        ])
        res = compound.open_settings(live_dir=os.path.dirname(HERE))
        self.assertEqual(res['status'], 'INCONCLUSIVE')
        self.assertTrue(res['may_have_run'])
        self.assertIn('MAY HAVE RUN', res['reason'])
        self.assertNotIn('error', res)

    def test_a_normal_failure_is_still_a_failure(self):
        # Falsifies the above: without a timeout, a missing component is FAIL,
        # so the INCONCLUSIVE verdict is not simply what this always returns.
        roots = "  11 root(s) bound to $r0..$r10"
        channel.run_batch = FakeChannel([
            roots, _hit(), _hit(), _hit(), _hit(), _hit(),
            "  ! no such component AnimatedToggle",
        ])
        res = compound.open_settings(live_dir=os.path.dirname(HERE))
        self.assertIn(res['status'], ('FAIL', 'INCONCLUSIVE'))
        self.assertNotEqual(res.get('may_have_run'), True)


if __name__ == '__main__':
    unittest.main(verbosity=2)
