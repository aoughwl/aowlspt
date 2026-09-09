#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Unit tests for channel.py -- run/parse logic only, no live client, no
network I/O. All file-channel interaction is faked via injected read_out/
write_cmd/sleep/now callables.

Run:  python plugins/aowlsptcode/tests/test_channel.py
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'mcp'))
import channel  # noqa: E402


class FakeClock(object):
    def __init__(self):
        self.t = 0.0

    def now(self):
        return self.t

    def sleep(self, s):
        self.t += s


class RunBatchStaleness(unittest.TestCase):
    """The property the task cares about most: never return an answer that
    is not provably for THIS batch's sentinel."""

    def test_returns_only_when_sentinel_present(self):
        clock = FakeClock()
        written = {}
        # out-file starts with a PREVIOUS batch's answer sitting in it.
        state = {'out': '#111\nHIT 0xdead name="Stale"\necho aowl-batch-OLD\n'}

        def read_out():
            return state['out']

        def write_cmd(body):
            written['body'] = body
            # Simulate the host answering three polls later, with the NEW
            # sentinel embedded in the new body.
            state['delay'] = 3

        sentinel_holder = {}

        def write_cmd_and_answer(body):
            write_cmd(body)
            # extract the sentinel this call actually used
            first_line = body.splitlines()[-1]
            sent = first_line.split(' ', 1)[1]
            sentinel_holder['s'] = sent

        polls = {'n': 0}

        def read_out_delayed():
            polls['n'] += 1
            if polls['n'] < 3:
                return state['out']  # still stale
            return 'HIT 0xbeef name="Fresh"\necho %s\n' % sentinel_holder['s']

        sentinel, text = channel.run_batch(
            ['find Fresh'], live_dir='C:\\fake', timeout=100,
            sleep=clock.sleep, now=clock.now,
            read_out=read_out_delayed, write_cmd=write_cmd_and_answer)

        self.assertIn(sentinel, sentinel_holder['s'] if False else sentinel)
        self.assertNotIn('Stale', text)
        self.assertIn('Fresh', text)

    def test_timeout_is_typed_not_stale_read(self):
        clock = FakeClock()

        def read_out():
            return '#000\nsome old unrelated content\necho aowl-batch-999\n'

        def write_cmd(body):
            pass

        with self.assertRaises(channel.TimeoutErr):
            channel.run_batch(['state'], live_dir='C:\\fake', timeout=1.0,
                               sleep=clock.sleep, now=clock.now,
                               read_out=read_out, write_cmd=write_cmd)

    def test_two_calls_never_share_a_sentinel(self):
        s1 = channel.new_sentinel()
        s2 = channel.new_sentinel()
        self.assertNotEqual(s1, s2)


class ParseFind(unittest.TestCase):
    def test_exhaustive_with_hits(self):
        raw = (
            '  visited 42 node(s) over 1 frame(s), 2 match(es), frontier 0 node(s)\n'
            '    HIT 0x1000 name="PlayButton"  parent="MenuRoot"   ($f1)\n'
            '    HIT 0x2000 name="PlayButtonShadow"  parent="MenuRoot"   ($f2)\n'
            '  -- the subtree was searched EXHAUSTIVELY. Every match is listed above.\n'
            '  matches are bound to $f1..$f2 for the rest of this batch'
        )
        r = channel.parse_find(raw)
        self.assertEqual(r['completeness'], 'EXHAUSTIVE')
        self.assertTrue(r['can_trust_absence'])
        self.assertFalse(r['resumable'])
        self.assertEqual(len(r['hits']), 2)
        self.assertEqual(r['hits'][0]['ptr'], '0x1000')
        self.assertEqual(r['hits'][0]['name'], 'PlayButton')
        self.assertEqual(r['hits'][0]['var'], '$f1')

    def test_stopped_early_no_hits_is_not_absence(self):
        raw = (
            '  visited 5000 node(s) over 40 frame(s), 0 match(es), frontier 1200 node(s)\n'
            '  -- STOPPED EARLY on the NODE BUDGET. This is NOT proof the subject is absent.'
        )
        r = channel.parse_find(raw)
        self.assertEqual(r['completeness'], 'STOPPED_EARLY')
        self.assertFalse(r['can_trust_absence'])
        self.assertTrue(r['resumable'])
        self.assertEqual(r['hits'], [])

    def test_nothing_examined_is_distinct_from_exhaustive_miss(self):
        raw = '  -- NOTHING WAS EXAMINED (0 valid nodes visited). This is NOT evidence the search subject is absent.'
        r = channel.parse_find(raw)
        self.assertEqual(r['completeness'], 'NOTHING_EXAMINED')
        self.assertFalse(r['can_trust_absence'])


class ParseFindText(unittest.TestCase):
    def test_scope_and_inactive_skipped_survive(self):
        raw = (
            '  searching ALL 11 scene root(s) for TMP text containing "play" '
            '(case-insensitive; budget 50000 nodes, scope: ACTIVE nodes only -- '
            'pass `all` to include inactive)\n'
            '  visited 900 node(s) over 3 frame(s), 1 match(es), frontier 0 node(s), '
            '4 inactive node(s) skipped\n'
            '    HIT 0x3000 name="Btn" parent="Root" text="Play"   ($f1)\n'
            '  -- the subtree was searched EXHAUSTIVELY. Every match is listed above.'
        )
        r = channel.parse_findtext(raw)
        self.assertEqual(r['scope'], 'ACTIVE_ONLY')
        self.assertEqual(r['inactive_skipped'], 4)
        self.assertEqual(len(r['hits']), 1)


class ParseRoots(unittest.TestCase):
    def test_binds_range(self):
        raw = ('  11 root(s) bound to $r0..$r10 as TRANSFORMS -- the same kind '
               'of pointer $c0 and $f1 are.')
        r = channel.parse_roots(raw)
        self.assertEqual(r['count'], 11)
        self.assertEqual(len(r['roots']), 11)
        self.assertEqual(r['roots'][0]['transform_var'], '$r0')
        self.assertEqual(r['roots'][10]['gameobject_var'], '$rgo10')


class ParseReadLabelComponentCallPress(unittest.TestCase):
    """Fixtures below are the literal shapes iOut/iErr emit at each command's
    real call site in inspect.nim, not assumed prose -- see channel.py
    docstrings for the line numbers."""

    def test_read_value(self):
        r = channel.parse_read('  0x1234 as i32 = 42', '$c0+0x18', 'i32')
        self.assertEqual(r['value'], '42')
        self.assertTrue(r['parse_ok'])

    def test_read_error_not_mistaken_for_value(self):
        r = channel.parse_read('  ! read faulted: invalid pointer', '$bad', 'i32')
        self.assertIsNone(r['value'])

    def test_label(self):
        r = channel.parse_label('  text = "Continue"')
        self.assertEqual(r['text'], 'Continue')

    def test_component_found(self):
        raw = '  FOUND Button component = 0xABCDEF  klass=0x123   ($comp)'
        r = channel.parse_component(raw)
        self.assertTrue(r['bound'])
        self.assertTrue(r['found'])

    def test_component_not_found(self):
        raw = ('  ! GetComponent returned NULL -- this is an ANSWER, not a '
               'crash. Either this object genuinely has no Foo ...')
        r = channel.parse_component(raw)
        self.assertFalse(r['found'])
        self.assertFalse(r['bound'])

    def test_call_error_is_typed_false_not_prose(self):
        r = channel.parse_call('  ! rva 0x1000: not committed or not executable')
        self.assertFalse(r['ok'])

    def test_call_ptr_return(self):
        raw = '  -> ptr 0xDEADBEEF  readable, klass=0x123   (bound to $_)'
        r = channel.parse_call(raw)
        self.assertTrue(r['ok'])
        self.assertEqual(r['ret_type'], 'ptr')
        self.assertEqual(r['returned'], '0xDEADBEEF')

    def test_call_i64_return(self):
        r = channel.parse_call('  -> i64 42 (0x000000000000002A)')
        self.assertEqual(r['ret_type'], 'i64')
        self.assertEqual(r['returned'], '0x000000000000002A')

    def test_call_void_return(self):
        r = channel.parse_call('  -> returned without faulting (void)')
        self.assertTrue(r['ok'])
        self.assertEqual(r['ret_type'], 'void')

    def test_press_ok(self):
        raw = ('  target klass = 0x1  OnClick(+0x120) = 0xABC\n'
                '  returned without faulting.')
        r = channel.parse_press(raw)
        self.assertTrue(r['ok'])

    def test_press_refused(self):
        raw = '  ! that slot is NULL -- no handler is wired to this button.'
        r = channel.parse_press(raw)
        self.assertFalse(r['ok'])


class ParseTreeAndParent(unittest.TestCase):
    def test_tree_nodes(self):
        raw = ('  tree from 0x1 name="Root" (max depth 4, max 500 nodes)\n'
               '    "Root"  0x1  (2 child)\n'
               '      + "Child A"  0x2\n'
               '      + "Child B"  0x3  (1 child)\n'
               '  3 node(s) printed  -- complete.')
        r = channel.parse_tree(raw)
        self.assertEqual(len(r['nodes']), 3)
        self.assertEqual(r['nodes'][1]['name'], 'Child A')
        self.assertEqual(r['nodes'][2]['child_count'], 1)
        self.assertTrue(r['complete'])
        self.assertFalse(r['truncated'])

    def test_parent_levels(self):
        raw = ('    [0] transform=0x1 klass=0x10 name="Row" go=0x2 activeSelf=true\n'
               '    [1] (null parent -- this is the hierarchy root)')
        r = channel.parse_parent(raw)
        self.assertEqual(len(r['levels']), 1)
        self.assertEqual(r['levels'][0]['name'], 'Row')
        self.assertTrue(r['levels'][0]['active_self'])
        self.assertTrue(r['reached_root'])


class ParseChildrenReal(unittest.TestCase):
    def test_children_real_shape(self):
        raw = ('  childCount = 2\n'
               '  via Transform::GetChild / get_childCount, Object::get_name (calls)\n'
               '    [0] transform=0x1 ($c0)  go=0x2 ($g0)  name="Background"\n'
               '    [1] transform=0x3 ($c1)  go=0x4 ($g1)  name="Label"\n'
               '  transforms bound to $c0..$c1, GameObjects to $g0..$g1. NOTE: ...')
        r = channel.parse_children(raw)
        self.assertEqual(len(r['children']), 2)
        self.assertEqual(r['children'][1]['name'], 'Label')
        self.assertEqual(r['child_count'], 2)
        self.assertTrue(r['parse_ok'])


_TOOLS = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                      '..', '..', '..', 'tools')
sys.path.insert(0, _TOOLS)
import inspectfixtures  # noqa: E402 -- the ONE measured corpus


_MATCHES_RE = __import__('re').compile(r'(\d+) match\(es\)')


class HitLinesAgainstTheMeasuredCorpus(unittest.TestCase):
    """Replay every recorded `find` / `findtext` answer through the SHARED
    parser and check the hit count against the host's OWN `K match(es)` line.

    This is the check that could have caught the bug it was written for: the
    old `_HIT_RE` returned [] for every findtext answer, and nothing compared
    that [] to anything the host said. Comparing to the host's own count means
    a parser that finds FEWER hits than were printed fails, rather than
    quietly reporting a shorter list.
    """

    def _entries(self, verb):
        es = [e for e in inspectfixtures.load().entries if e.verb == verb]
        self.assertTrue(es, 'no %s fixtures loaded -- this test would pass '
                             'vacuously on an empty corpus' % verb)
        return es

    def _check(self, verb):
        checked_hits = 0
        for e in self._entries(verb):
            printed = [l for l in e.output.splitlines()
                       if l.strip().startswith('HIT ')]
            parsed = channel.parse_find(e.output)['hits']
            self.assertEqual(
                len(parsed), len(printed),
                '%s: parsed %d of %d HIT lines the host printed'
                % (e.eid, len(parsed), len(printed)))
            m = _MATCHES_RE.search(e.output)
            if m:
                self.assertEqual(
                    len(parsed), int(m.group(1)),
                    '%s: host said %s match(es), parser produced %d'
                    % (e.eid, m.group(1), len(parsed)))
            for h in parsed:
                self.assertTrue(h['ptr'].startswith('0x'))
                self.assertTrue(h['name'])
                self.assertTrue(h['var'].startswith('$f'))
            checked_hits += len(parsed)
        return checked_hits

    def test_every_find_hit_line_parses(self):
        # The corpus really does carry find hits; a corpus with none would
        # make this whole class unfalsifiable.
        self.assertGreater(self._check('find'), 0)

    def test_every_findtext_hit_line_parses(self):
        self.assertGreater(self._check('findtext'), 0)

    def test_findtext_active_flag_survives_both_spellings(self):
        act = channel.parse_find(
            inspectfixtures.fx('findtext-clones-donor-caption'))['hits']
        self.assertEqual(len(act), 24)
        self.assertTrue(all(h['active'] is True for h in act))
        self.assertEqual(act[0]['text'], 'Interface language')
        self.assertEqual(act[0]['parent'], 'Settings Drop Down(Clone)')

        inact = channel.parse_find(
            inspectfixtures.fx('findtext-placeholder-inactive-only'))['hits']
        self.assertEqual(len(inact), 12)
        self.assertTrue(all(h['active'] is False for h in inact))

    def test_find_hits_have_active_none_not_false(self):
        """`find` prints no flag. None means UNKNOWN; reporting False would be
        a fabricated measurement (and would make every find hit look
        unpressable)."""
        hits = channel.parse_find(
            inspectfixtures.fx('find-toggles-strip-with-clones'))['hits']
        self.assertEqual(len(hits), 18)
        self.assertTrue(all(h['active'] is None for h in hits))
        self.assertTrue(all(h['text'] is None for h in hits))

    def test_echo_and_summary_lines_are_not_hits(self):
        """NEGATIVE CONTROL. The command echo and the `visited` summary are the
        two lines a sloppy pattern eats; a parser that scores them would report
        hits for a walk that found none."""
        for eid in ('findtext-clones-donor-caption', 'find-toggles-strip-with-clones'):
            noise = "\n".join(l for l in inspectfixtures.fx(eid).splitlines()
                              if not l.strip().startswith('HIT '))
            self.assertIn('>', noise)
            self.assertIn('visited', noise)
            self.assertEqual(channel.parse_find(noise)['hits'], [], eid)

    def test_a_hit_never_reaches_into_the_next_line(self):
        """A HIT line with its `($fN)` binding stripped must not borrow the
        NEXT line's binding -- that would invent a hit and mislabel a var."""
        raw = ('    HIT 0x1000  name="A"  parent="P"  text="t"  activeInHierarchy=true\n'
               '    HIT 0x2000  name="B"  parent="P"  text="t"  activeInHierarchy=true   ($f2)\n')
        hits = channel.parse_find(raw)['hits']
        self.assertEqual([h['ptr'] for h in hits], ['0x2000'])


if __name__ == '__main__':
    unittest.main()
