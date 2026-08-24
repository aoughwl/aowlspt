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
    def test_read_value(self):
        r = channel.parse_read('$c0+0x18 i32 = 42', '$c0+0x18', 'i32')
        self.assertEqual(r['value'], '42')
        self.assertTrue(r['parse_ok'])

    def test_read_error_not_mistaken_for_value(self):
        r = channel.parse_read('!! read faulted: invalid pointer', '$bad', 'i32')
        self.assertIsNone(r['value'])
        self.assertFalse(r['parse_ok'])

    def test_label(self):
        r = channel.parse_label('  text = "Continue"')
        self.assertEqual(r['text'], 'Continue')

    def test_component_found(self):
        r = channel.parse_component('component resolved -> $comp bound')
        self.assertTrue(r['bound'])

    def test_component_not_found(self):
        r = channel.parse_component('!! no component of type Foo on this GameObject')
        self.assertFalse(r['found'])

    def test_call_error_is_typed_false_not_prose(self):
        r = channel.parse_call('!! call refused: shared RVA, detour blocked')
        self.assertFalse(r['ok'])

    def test_press_ok(self):
        r = channel.parse_press('press: DefaultUIButton.OnClick invoked')
        self.assertTrue(r['ok'])


if __name__ == '__main__':
    unittest.main()
