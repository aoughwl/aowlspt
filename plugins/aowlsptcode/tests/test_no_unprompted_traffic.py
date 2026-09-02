#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The aowlinspect MCP server must not touch the inspector's file channel
unless a tool call asked it to.

WHY THIS TEST EXISTS
--------------------
2026-09-02: nine inspector batches ran in the first 23 seconds of a client
boot -- eight `roots` polls and one 58-command
`allow write` / `echo UIQ<n>` / `call name:get_activeInHierarchy i_p 0x...`
batch -- with no tool call having asked for any of them. The file channel is
SINGLE-BATCH: whatever else is written during that traffic is swallowed or
delayed, and the last batch is left on disk to run again at the next boot.
The MCP server was the prime suspect (it was the python process alive at the
time).

It was NOT the MCP server. The measured writer is `aowlspt-launch.exe`'s
auto-enter (tools/aowllaunch.nim -> tools/aowlui.nim `screens()`), identified
by its sentinel shape. But "we read the code and found no loop" is exactly the
kind of check that cannot fail, so this replaces it with one that can: the
server is driven as a real subprocess against a FAKE live directory, and the
directory is inspected for any evidence of a write.

Three things are asserted, and the third is what makes the first two mean
anything:

  1. startup + initialize + tools/list write NOTHING to the channel;
  2. `inspect_health` -- the only tool a caller might reasonably think polls --
     writes NOTHING and produces no `allow write`;
  3. POSITIVE CONTROL: `inspect_state` DOES write a command file into the same
     fake dir. Without this, a bug in the detector (wrong path, wrong env var)
     would make 1 and 2 pass vacuously.

Run:  python plugins/aowlsptcode/tests/test_no_unprompted_traffic.py
"""
import json
import os
import subprocess
import sys
import tempfile
import shutil
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
MCP = os.path.join(HERE, '..', 'mcp')
SERVER = os.path.join(MCP, 'server.py')

sys.path.insert(0, MCP)
import channel  # noqa: E402


def _rpc(*messages):
    """Send messages to a fresh server subprocess; return (stdout, live_dir).

    The live dir is a temp directory made to LOOK like the install (the
    channel refuses with channel_missing if the directory does not exist), so
    any write the server makes lands there and nowhere near D:\\Aowlspt.
    """
    live = tempfile.mkdtemp(prefix='aowlspt-fakelive-')
    env = dict(os.environ)
    env['AOWLSPT_LIVE'] = live
    body = ''.join(json.dumps(m) + '\n' for m in messages)
    p = subprocess.run([sys.executable, SERVER], input=body,
                       capture_output=True, text=True, timeout=120, env=env)
    return p, live


def _channel_artifacts(live):
    """Every trace a channel write would leave, by NAME -- not a directory
    listing diff, so a server that wrote the file and deleted it is still
    caught by the lock, and vice versa."""
    found = []
    for name in os.listdir(live):
        found.append(name)
    return found


INIT = {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize',
        'params': {'protocolVersion': '2024-11-05', 'capabilities': {},
                   'clientInfo': {'name': 'test', 'version': '0'}}}


class NoUnpromptedTraffic(unittest.TestCase):

    def test_startup_and_tools_list_write_nothing(self):
        p, live = _rpc(INIT,
                       {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
                       {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'})
        try:
            self.assertIn('"tools"', p.stdout, 'server did not answer tools/list')
            self.assertEqual([], _channel_artifacts(live),
                             'server touched the live dir with no tool call')
            self.assertFalse(os.path.exists(channel.lock_path(live)),
                             'server took the single-writer channel lock '
                             'with no tool call')
        finally:
            shutil.rmtree(live, ignore_errors=True)

    def test_inspect_health_writes_nothing(self):
        p, live = _rpc(INIT,
                       {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call',
                        'params': {'name': 'inspect_health', 'arguments': {}}})
        try:
            # It must ANSWER (a server that crashed would also write nothing).
            self.assertIn('verdict', p.stdout, 'inspect_health did not answer')
            self.assertEqual([], _channel_artifacts(live),
                             'inspect_health wrote to the channel; it is '
                             'documented as reading log files only')
            self.assertFalse(os.path.exists(channel.lock_path(live)),
                             'inspect_health took the channel lock')
            self.assertNotIn('allow write', p.stdout)
        finally:
            shutil.rmtree(live, ignore_errors=True)

    def test_positive_control_a_channel_tool_DOES_write(self):
        """If this fails, the two tests above prove nothing."""
        p, live = _rpc(INIT,
                       {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call',
                        'params': {'name': 'inspect_state',
                                   'arguments': {'timeout_s': 1}}})
        try:
            names = _channel_artifacts(live)
            self.assertIn('aowlspt-inspect.txt', names,
                          'inspect_state did not write a command file -- the '
                          'detector in this file is not looking in the right '
                          'place, so its negative results are vacuous')
            with open(os.path.join(live, 'aowlspt-inspect.txt'), 'rb') as f:
                body = f.read().decode('utf-8')
            # No client is running, so the batch times out; that is expected.
            # The tool payload is JSON nested inside JSON, so decode both
            # levels rather than substring-matching escaped text (a substring
            # `contains` on a payload that was not valid JSON at all is a
            # check that passed for months elsewhere in this repo).
            last = json.loads(p.stdout.strip().splitlines()[-1])
            inner = json.loads(last['result']['content'][0]['text'])
            self.assertEqual('timeout', inner['error']['kind'])
            # A read-only verb must not arm writes.
            self.assertNotIn('allow write', body)
            # The serial line names the writer, so the host log can too.
            self.assertTrue(body.startswith('#aowl-batch-mcp'), body[:40])
        finally:
            shutil.rmtree(live, ignore_errors=True)


class SentinelNamesTheWriter(unittest.TestCase):

    def test_sentinel_carries_this_writer_and_pid(self):
        s = channel.new_sentinel()
        self.assertIn('%s%d' % (channel.writer_tag(), os.getpid()), s)
        self.assertNotEqual(s, channel.new_sentinel())

    def test_the_tag_is_the_script_not_a_hardcoded_mcp(self):
        """tools/ichannel.py re-exports this transport, so acceptance.py and
        the MCP server share it. A constant tag would name the wrong writer."""
        real = sys.argv[0]
        try:
            sys.argv[0] = r'C:\x\tools\acceptance.py'
            self.assertEqual('acceptance', channel.writer_tag())
            sys.argv[0] = r'C:\x\mcp\server.py'
            self.assertEqual('mcp', channel.writer_tag())
        finally:
            sys.argv[0] = real


class WriteIsNeverImplicit(unittest.TestCase):
    """`allow write` arms calls into game code. It must appear only when a
    handler was asked for it -- checked against the handler table itself, so a
    NEW tool that quietly passes write=True is caught without a live client."""

    def test_only_the_declared_write_tools_arm_writes(self):
        sys.path.insert(0, MCP)
        import server  # noqa: E402
        armed = []
        recorded = {}

        def fake_run_batch(lines, live_dir=None, timeout=25.0, write=False,
                           **kw):
            armed.append(write)
            raise channel.TimeoutErr('no client (test)')

        real = channel.run_batch
        channel.run_batch = fake_run_batch
        try:
            for tool in server.TOOLS:
                name = tool['name']
                if name in ('inspect_health', 'inspect_screenshot',
                            'inspect_assert', 'recipe_run'):
                    continue          # no channel write of their own
                args = {'_live_dir': os.path.dirname(os.path.abspath(__file__)),
                        'timeout_s': 0.1}
                schema = tool['inputSchema'].get('required') or []
                for req in schema:
                    args[req] = '0x1' if req in ('ptr', 'target') else 'X'
                if name == 'inspect_call':
                    args['sig'] = 'i_p'
                if name == 'inspect_batch':
                    args['commands'] = ['state']
                del armed[:]
                try:
                    tool['handler'](args)
                except Exception:
                    pass
                recorded[name] = any(armed)
        finally:
            channel.run_batch = real

        expected_writers = {'inspect_call', 'inspect_press'}
        actual_writers = {n for n, w in recorded.items() if w}
        self.assertEqual(expected_writers, actual_writers,
                         'tools that armed `allow write`: %s' % sorted(actual_writers))


if __name__ == '__main__':
    unittest.main(verbosity=2)
