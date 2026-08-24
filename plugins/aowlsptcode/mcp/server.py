#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""aowlinspect MCP server for the aowlsptcode Claude Code plugin.

Zero-dependency (stdlib only), matching aowlcode's nimlang server's runtime
choice. Speaks JSON-RPC 2.0 over stdio: initialize, notifications/initialized,
tools/list, tools/call.

Wraps the aowlspt live inspector's file channel (see channel.py) as typed
tools: one MCP call == one sentinel-guarded write/poll/parse round trip, never
a raw prose blob as the primary return, and completeness/scope flags carried
as explicit fields rather than folded into a plain hit list.

Nothing here writes to stdout except JSON-RPC responses.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import channel  # noqa: E402

PROTOCOL_VERSION = '2024-11-05'
SERVER_INFO = {'name': 'aowlinspect', 'version': '0.1.0'}


def _err(kind, message, **extra):
    d = {'error': {'kind': kind, 'message': message}}
    d['error'].update(extra)
    return d


def _run(lines, args, parse, write=False):
    """Shared plumbing: run a batch through channel.run_batch, translate any
    InspectorError into a typed {'error': {...}} result, otherwise hand the
    raw text to `parse` and return its dict (parse's own dict, augmented with
    the sentinel so a caller can correlate)."""
    live_dir = args.get('_live_dir')  # test-injection only, not a public arg
    timeout = float(args.get('timeout_s', 25.0))
    try:
        sentinel, raw = channel.run_batch(lines, live_dir=live_dir,
                                           timeout=timeout, write=write)
    except channel.TimeoutErr as e:
        return _err('timeout', str(e))
    except channel.ChannelMissing as e:
        return _err('channel_missing', str(e))
    except channel.WriteNotAllowed as e:
        return _err('write_not_allowed', str(e))
    result = parse(raw)
    result['sentinel'] = sentinel
    return result


# ---------------------------------------------------------------------------
# Tool handlers. Each takes the already-validated `arguments` dict.
# ---------------------------------------------------------------------------

def h_state(a):
    return _run(['state'], a, channel.parse_state)


def h_roots(a):
    return _run(['roots'], a, channel.parse_roots)


def h_find(a):
    name = a['name']
    parts = ['find %s' % name]
    if a.get('root'):
        parts = ['find %s %s' % (name, a['root'])]
    if a.get('budget'):
        parts[0] += ' %s' % a['budget']
    return _run(parts, a, channel.parse_find)


def h_findtext(a):
    text = a['text']
    line = 'findtext %s' % text
    if a.get('root'):
        line += ' %s' % a['root']
    if a.get('budget'):
        line += ' %s' % a['budget']
    if a.get('include_inactive'):
        line += ' all'
    return _run([line], a, channel.parse_findtext)


def h_children(a):
    return _run(['children %s' % a['ptr']], a, channel.parse_children)


def h_tree(a):
    depth = a.get('depth')
    line = 'tree %s%s' % (a['ptr'], (' %s' % depth) if depth else '')
    return _run([line], a, channel.parse_children)


def h_parent(a):
    depth = a.get('depth')
    line = 'parent %s%s' % (a['ptr'], (' %s' % depth) if depth else '')
    return _run([line], a, channel.parse_children)


def h_read(a):
    expr, type_ = a['expr'], a['type']
    return _run(['read %s %s' % (expr, type_)], a,
                lambda raw: channel.parse_read(raw, expr, type_))


def h_component(a):
    return _run(['component %s %s' % (a['ptr'], a['type_name'])], a,
                channel.parse_component)


def h_label(a):
    return _run(['label %s' % a['ptr']], a, channel.parse_label)


def h_call(a):
    line = 'call %s %s' % (a['target'], a['sig'])
    if a.get('args'):
        line += ' ' + ' '.join(str(x) for x in a['args'])
    return _run([line], a, channel.parse_call, write=True)


def h_press(a):
    return _run(['press %s' % a['ptr']], a, channel.parse_press, write=True)


def h_recipe_run(a):
    """Replay a stored aowlfacts recipe. Read-only lookup into the fact
    store's SQLite DB (mode=ro), then the steps are sent through the same
    sentinel-guarded channel as every other tool -- a recipe's steps may
    themselves include `allow write`/`call`/`press` lines, so this is only
    as safe as the recipe it replays; it does not add its own write gate on
    top."""
    try:
        description, steps, status = channel.load_recipe(a['name'])
    except channel.RecipeNotFound as e:
        return _err('recipe_not_found', str(e))
    if not steps:
        return _err('empty_recipe', 'recipe %r has no steps' % a['name'])
    result = _run(steps, a, lambda raw: {'raw': raw, 'parse_ok': False})
    if 'error' not in result:
        result['description'] = description
        result['status'] = status
        result['steps_run'] = steps
    return result


TOOLS = [
    {'name': 'inspect_state', 'description':
     'Session/host status prose from the live inspector (`state`). '
     'No stable structured schema is known yet -- returns raw text with '
     'parse_ok=false rather than inventing fields.',
     'inputSchema': {'type': 'object', 'properties': {
         'timeout_s': {'type': 'number'}}},
     'handler': h_state},
    {'name': 'inspect_roots', 'description':
     'Every scene root including DontDestroyOnLoad, bound to $r0..$rN '
     '(transforms) / $rgo0..$rgoN (gameobjects). Use before any find/children '
     'call from a cold menu.',
     'inputSchema': {'type': 'object', 'properties': {
         'timeout_s': {'type': 'number'}}},
     'handler': h_roots},
    {'name': 'inspect_find', 'description':
     'find NAME [ROOT] [BUDGET] -- case-insensitive GameObject-NAME substring '
     'search. Result carries `completeness` (EXHAUSTIVE/STOPPED_EARLY/'
     'HIT_CAP/NOTHING_EXAMINED) and `can_trust_absence`: an empty hit list is '
     'NOT proof of absence unless can_trust_absence is true.',
     'inputSchema': {'type': 'object', 'required': ['name'], 'properties': {
         'name': {'type': 'string'},
         'root': {'type': 'string', 'description': 'a $-anchor or 0x pointer'},
         'budget': {'type': 'integer'},
         'timeout_s': {'type': 'number'}}},
     'handler': h_find},
    {'name': 'inspect_findtext', 'description':
     'findtext TEXT [ROOT] [BUDGET] -- search by DISPLAYED TMP text, not '
     'object name. `include_inactive` controls whether inactive nodes are '
     'included, and the actual scope used is echoed back in `scope` -- never '
     'assume the request flag was honoured without checking it.',
     'inputSchema': {'type': 'object', 'required': ['text'], 'properties': {
         'text': {'type': 'string'},
         'root': {'type': 'string'},
         'budget': {'type': 'integer'},
         'include_inactive': {'type': 'boolean'},
         'timeout_s': {'type': 'number'}}},
     'handler': h_findtext},
    {'name': 'inspect_children', 'description': 'children EXPR -- direct children of a transform/gameobject.',
     'inputSchema': {'type': 'object', 'required': ['ptr'], 'properties': {
         'ptr': {'type': 'string'}, 'timeout_s': {'type': 'number'}}},
     'handler': h_children},
    {'name': 'inspect_tree', 'description': 'tree EXPR [DEPTH] -- subtree dump.',
     'inputSchema': {'type': 'object', 'required': ['ptr'], 'properties': {
         'ptr': {'type': 'string'}, 'depth': {'type': 'integer'},
         'timeout_s': {'type': 'number'}}},
     'handler': h_tree},
    {'name': 'inspect_parent', 'description': 'parent EXPR [N] -- walk up N ancestors.',
     'inputSchema': {'type': 'object', 'required': ['ptr'], 'properties': {
         'ptr': {'type': 'string'}, 'depth': {'type': 'integer'},
         'timeout_s': {'type': 'number'}}},
     'handler': h_parent},
    {'name': 'inspect_read', 'description':
     'read EXPR TYPE -- typed memory read (i8..i64,u8..u64,f32,f64,ptr,bool,str,klass).',
     'inputSchema': {'type': 'object', 'required': ['expr', 'type'], 'properties': {
         'expr': {'type': 'string'}, 'type': {'type': 'string'},
         'timeout_s': {'type': 'number'}}},
     'handler': h_read},
    {'name': 'inspect_component', 'description':
     'component EXPR TypeName -- resolve a component on a GameObject, binds $comp.',
     'inputSchema': {'type': 'object', 'required': ['ptr', 'type_name'], 'properties': {
         'ptr': {'type': 'string'}, 'type_name': {'type': 'string'},
         'timeout_s': {'type': 'number'}}},
     'handler': h_component},
    {'name': 'inspect_label', 'description': 'label EXPR -- TMP_Text content.',
     'inputSchema': {'type': 'object', 'required': ['ptr'], 'properties': {
         'ptr': {'type': 'string'}, 'timeout_s': {'type': 'number'}}},
     'handler': h_label},
    {'name': 'inspect_call', 'description':
     'call TARGET SIG [ARGS...] -- direct IL2CPP call by RVA. WRITE-GATED: '
     'requires liveInspectorWrite on the host; never call this against a '
     'live client you do not control.',
     'inputSchema': {'type': 'object', 'required': ['target', 'sig'], 'properties': {
         'target': {'type': 'string'}, 'sig': {'type': 'string'},
         'args': {'type': 'array', 'items': {'type': 'string'}},
         'timeout_s': {'type': 'number'}}},
     'handler': h_call},
    {'name': 'inspect_press', 'description':
     'press EXPR -- EFT DefaultUIButton.OnClick path. WRITE-GATED, same caveat as inspect_call.',
     'inputSchema': {'type': 'object', 'required': ['ptr'], 'properties': {
         'ptr': {'type': 'string'}, 'timeout_s': {'type': 'number'}}},
     'handler': h_press},
    {'name': 'recipe_run', 'description':
     'Replay a stored aowlfacts recipe (read-only lookup into '
     '%USERPROFILE%\\.aowl\\facts.db, recipe.steps_json) through the '
     'sentinel-guarded channel. A recipe\'s own steps may write/call/press; '
     'this adds no extra gate beyond what the recipe already does.',
     'inputSchema': {'type': 'object', 'required': ['name'], 'properties': {
         'name': {'type': 'string'}, 'timeout_s': {'type': 'number'}}},
     'handler': h_recipe_run},
]
TOOLS_BY_NAME = {t['name']: t for t in TOOLS}


def tools_list_payload():
    return [{'name': t['name'], 'description': t['description'],
              'inputSchema': t['inputSchema']} for t in TOOLS]


def make_response(req_id, result):
    return {'jsonrpc': '2.0', 'id': req_id, 'result': result}


def make_error(req_id, code, message):
    return {'jsonrpc': '2.0', 'id': req_id, 'error': {'code': code, 'message': message}}


def handle_tools_call(params):
    name = params.get('name')
    arguments = params.get('arguments') or {}
    tool = TOOLS_BY_NAME.get(name)
    if tool is None:
        return {'content': [{'type': 'text',
                              'text': json.dumps({'error': {'kind': 'unknown_tool',
                                                             'message': name}})}],
                'isError': True}
    try:
        result = tool['handler'](arguments)
    except KeyError as e:
        result = _err('missing_argument', 'missing required argument: %s' % e)
    except Exception as e:
        result = _err('crash', '%s: %s' % (type(e).__name__, e))
    is_error = isinstance(result, dict) and 'error' in result
    text = json.dumps(result, separators=(',', ':'), ensure_ascii=False)
    payload = {'content': [{'type': 'text', 'text': text}]}
    if is_error:
        payload['isError'] = True
    return payload


def dispatch(msg):
    method = msg.get('method')
    req_id = msg.get('id')
    params = msg.get('params') or {}
    if method == 'initialize':
        return make_response(req_id, {
            'protocolVersion': PROTOCOL_VERSION,
            'capabilities': {'tools': {}},
            'serverInfo': SERVER_INFO,
        })
    if method in ('notifications/initialized', 'initialized'):
        return None
    if method == 'ping':
        return make_response(req_id, {})
    if method == 'tools/list':
        return make_response(req_id, {'tools': tools_list_payload()})
    if method == 'tools/call':
        return make_response(req_id, handle_tools_call(params))
    if req_id is None:
        return None
    return make_error(req_id, -32601, 'method not found: %s' % method)


def main():
    stdin, stdout = sys.stdin, sys.stdout
    while True:
        line = stdin.readline()
        if not line:
            break
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            stdout.write(json.dumps(make_error(None, -32700, 'parse error')) + '\n')
            stdout.flush()
            continue
        if isinstance(msg, list):
            for sub in msg:
                resp = dispatch(sub)
                if resp is not None:
                    stdout.write(json.dumps(resp) + '\n')
            stdout.flush()
            continue
        resp = dispatch(msg)
        if resp is not None:
            stdout.write(json.dumps(resp) + '\n')
            stdout.flush()


if __name__ == '__main__':
    main()
