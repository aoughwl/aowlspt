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
import compound  # noqa: E402

import health  # noqa: E402

# `shot` (the screenshot capture) lives in the aowlspt SOURCE REPO's `tools/`,
# not in this plugin. That is fine for us and fatal for everyone else: this
# plugin is PUBLIC and installs on its own, so a top-level `import shot` makes
# THE WHOLE SERVER FAIL TO START on any machine without the private repo --
# every tool lost, for one optional capability.
#
# It is therefore optional and imported LAZILY. `compound` has already located
# the repo (or established that there is none) and put its `tools/` on sys.path,
# so this only has to try.
_shot = None
_shot_why = ""


def _get_shot():
    """The screenshot module, or None with a reason. Never raises."""
    global _shot, _shot_why
    if _shot is not None or _shot_why:
        return _shot
    try:
        import shot as _s          # noqa: F401
        _shot = _s
    except Exception as e:
        _shot_why = (
            "screen capture needs `tools/shot.py` from the aowlspt SOURCE "
            "repo, which is private and is not installed here (%s). Every "
            "other tool works without it -- they talk to the live client "
            "through the file channel and need only the game install. Set "
            "AOWLSPT_REPO to a checkout to enable this one." % e)
    return _shot

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
    except channel.ChannelBusy as e:
        # NOT a timeout. Another writer holds the single-writer lock, so this
        # batch was never sent -- blaming the host for a shell-side collision
        # is what happened on 2026-08-31 and cost the session.
        return _err('channel_busy', str(e))
    except channel.TimeoutErr as e:
        # A timeout is silent about WHY. If the host's own counters say it is
        # wedged mid-batch, say WEDGED -- the host's prose says the opposite.
        msg = str(e)
        try:
            import sys as _sys, os as _os
            _tools = _os.path.join(_os.path.dirname(_os.path.dirname(
                _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__))))),
                'tools')
            if _tools not in _sys.path:
                _sys.path.insert(0, _tools)
            from ui import wedge_verdict           # noqa: E402
            w = wedge_verdict(channel.paths(live_dir)['log'])
            if w:
                return _err('wedged', w)
        except Exception:
            pass
        return _err('timeout', msg)
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


# WHY THESE NUMBERS.
#
# Measured 2026-09-01 with the Settings screen OPEN ON SCREEN:
#
#     > find GraphicsSettingsTab
#       visited 20000 node(s) over 157 frame(s), 0 match(es),
#       frontier 13696 node(s) -- STOPPED EARLY on the NODE BUDGET.
#
# The inspector's default 20,000-node budget is smaller than this scene, so a
# search for a live, visible object costs 157 frames and returns nothing. The
# tool was honest (STOPPED EARLY, not "absent") and that honesty stays -- but
# the caller had to know to type `find more` by hand, and a caller who did not
# read `completeness` would read the empty hit list as absence.
#
# 20000 visited + 13696 frontier means the reachable set is >33,696 nodes, so
# one slice of 40,000 covers this scene with headroom. FIND_MAX_NODES is the
# ceiling across ALL resume rounds, and it is caller-visible (`max_nodes`) so
# an expensive search is a choice, not a surprise.
FIND_BUDGET = 40000
FIND_MAX_NODES = 400000
FIND_MAX_ROUNDS = 20


def _find_resume(first_line, more_verb, a, parse):
    """Issue `find`/`findtext`, then `... more` until one of exactly three
    things ends it, and SAY WHICH:

        EXHAUSTIVE   -- the search finished; an empty hit list IS absence
        HITS         -- at least one match, stopped there
        CAP          -- our own max_nodes/rounds ran out; still STOPPED EARLY,
                        and absence is still NOT proven

    The three-state answer survives: `completeness` is whatever the LAST
    response actually said, never rewritten, and `can_trust_absence` comes
    from the parser. `end_reason` is added alongside, not instead.
    """
    budget = int(a.get('budget') or FIND_BUDGET)
    max_nodes = int(a.get('max_nodes') or FIND_MAX_NODES)
    auto = a.get('auto_resume', True)
    # A 40,000-node slice takes hundreds of frames; the shared 25s default was
    # sized for a one-shot verb and would time out on the slice itself.
    if not a.get('timeout_s'):
        a = dict(a)
        a['timeout_s'] = 90.0

    res = _run([first_line], a, parse)
    if 'error' in res:
        return res
    res['rounds'] = 1
    res['budget_per_round'] = budget
    res['visited_total'] = res.get('visited') or 0
    res['end_reason'] = ('HITS' if res['hits'] else
                         'EXHAUSTIVE' if res['completeness'] == 'EXHAUSTIVE'
                         else 'CAP')
    if not auto:
        res['auto_resume'] = False
        return res

    rounds = 1
    while (not res['hits'] and res.get('resumable')
           and rounds < FIND_MAX_ROUNDS
           and res['visited_total'] < max_nodes):
        nxt = _run(['%s more %d' % (more_verb, budget)], a, parse)
        if 'error' in nxt:
            # A failed resume must not read as a finished search.
            nxt['end_reason'] = 'RESUME_FAILED'
            nxt['rounds'] = rounds
            nxt['visited_total'] = res['visited_total']
            return nxt
        rounds += 1
        nxt['rounds'] = rounds
        nxt['budget_per_round'] = budget
        nxt['visited_total'] = res['visited_total'] + (nxt.get('visited') or 0)
        # $fN handles are rebound PER BATCH by the host, so only the LAST
        # round's vars are live. Merging hit lists across rounds without
        # saying that would hand the caller stale anchors.
        nxt['hits_from_earlier_rounds'] = res['hits'] + res.get(
            'hits_from_earlier_rounds', [])
        nxt['vars_valid_for'] = 'this round only ($fN is rebound per batch)'
        res = nxt
        res['end_reason'] = ('HITS' if res['hits'] else
                             'EXHAUSTIVE' if res['completeness'] == 'EXHAUSTIVE'
                             else 'CAP')

    res['auto_resume'] = True
    res['rounds'] = rounds
    if res['end_reason'] == 'CAP':
        res['cap_note'] = (
            'stopped on OUR cap (max_nodes=%d, rounds=%d), not on the scene '
            'ending -- this is STOPPED EARLY and absence is NOT proven; raise '
            'max_nodes or budget' % (max_nodes, rounds))
    return res


def h_find(a):
    name = a['name']
    line = 'find %s' % name
    if a.get('root'):
        line += ' %s' % a['root']
    line += ' %d' % int(a.get('budget') or FIND_BUDGET)
    return _find_resume(line, 'find', a, channel.parse_find)


def h_findtext(a):
    # QUOTE THE TEXT. The inspector tokenises on whitespace, so a multi-word
    # subject was split and the second word was parsed as the ROOT argument:
    #
    #     findtext GRAPHICS SETTINGS   ->   ! not an address: SETTINGS
    #
    # Measured 2026-09-01 hunting a settings-screen bug. `inspect_path` already
    # auto-quotes its segments for exactly this reason; findtext did not, and
    # the failure is worse here because a caller who does not read `raw` sees an
    # empty hit list and can easily read it as "the text is not on screen".
    text = a['text']
    if not (len(text) >= 2 and text[0] == '"' and text[-1] == '"'):
        text = '"%s"' % text.replace('"', '')
    line = 'findtext %s' % text
    if a.get('root'):
        line += ' %s' % a['root']
    line += ' %d' % int(a.get('budget') or FIND_BUDGET)
    if a.get('include_inactive'):
        line += ' all'
    return _find_resume(line, 'findtext', a, channel.parse_findtext)


def h_children(a):
    return _run(['children %s' % a['ptr']], a, channel.parse_children)


def h_tree(a):
    depth = a.get('depth')
    line = 'tree %s%s' % (a['ptr'], (' %s' % depth) if depth else '')
    return _run([line], a, channel.parse_tree)


def h_parent(a):
    depth = a.get('depth')
    line = 'parent %s%s' % (a['ptr'], (' %s' % depth) if depth else '')
    return _run([line], a, channel.parse_parent)


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


def h_screenshot(a):
    crop = None
    if a.get('crop'):
        parts = [int(x) for x in a['crop'].split(',')]
        if len(parts) != 4:
            return _err('bad_crop', 'crop must be "x,y,w,h"')
        crop = tuple(parts)
    mod = _get_shot()
    if mod is None:
        # A typed refusal naming the real reason, not an ImportError traceback
        # that reads like this tool is broken. On a public install its absence
        # is expected.
        return _err('unavailable', _shot_why)
    result = mod.capture(process_name=a.get('process', 'EscapeFromTarkov.exe'),
                         crop=crop, max_width=int(a.get('max_width', 1200)))
    if not result.get('ok'):
        return _err('capture_failed', result.get('reason', 'unknown'), **result)
    return result


def h_path(a):
    try:
        return compound.resolve_path(a['path'], live_dir=a.get('_live_dir'),
                                      timeout=float(a.get('timeout_s', 25.0)),
                                      budget=int(a.get('budget', 20000)))
    except channel.InspectorError as e:
        return _err(e.kind, str(e))


def h_open_settings(a):
    try:
        return compound.open_settings(live_dir=a.get('_live_dir'),
                                       timeout=float(a.get('timeout_s', 180.0)))
    except channel.InspectorError as e:
        return _err(e.kind, str(e))


def h_batch(a):
    try:
        return compound.run_batch_commands(a['commands'], live_dir=a.get('_live_dir'),
                                            timeout=float(a.get('timeout_s', 30.0)),
                                            write=bool(a.get('write', False)))
    except channel.InspectorError as e:
        return _err(e.kind, str(e))


def h_assert(a):
    try:
        return compound.run_assertion(a['name'], live_dir=a.get('_live_dir'),
                                       root=a.get('root'),
                                       mods_built=bool(a.get('mods_built', False)),
                                       guid=a.get('guid'))
    except compound.AssertionUnknown as e:
        return _err('unknown_assertion', str(e))
    except channel.InspectorError as e:
        return _err(e.kind, str(e))


def h_health(a):
    """No channel round trip: this reads the install's own log files, so it
    answers even when the client is gone or the channel is wedged -- which is
    exactly when the question matters most."""
    return health.check(live=a.get('_live_dir'))

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
     'search, AUTO-RESUMED (`find more`) until the search is EXHAUSTIVE, a hit '
     'is found, or max_nodes is reached; `end_reason` says which of the three. '
     'Default budget 40000/round (the menu scene is >33696 nodes; the '
     'inspector default of 20000 returned zero hits for objects visibly on '
     'screen). Result still carries `completeness` (EXHAUSTIVE/STOPPED_EARLY/'
     'HIT_CAP/NOTHING_EXAMINED) and `can_trust_absence`: an empty hit list is '
     'NOT proof of absence unless can_trust_absence is true.',
     'inputSchema': {'type': 'object', 'required': ['name'], 'properties': {
         'name': {'type': 'string'},
         'root': {'type': 'string', 'description': 'a $-anchor or 0x pointer'},
         'budget': {'type': 'integer', 'description': 'nodes per round (default 40000)'},
         'max_nodes': {'type': 'integer', 'description':
                       'ceiling across ALL resume rounds (default 400000)'},
         'auto_resume': {'type': 'boolean', 'description':
                         'default true; false for one single slice'},
         'timeout_s': {'type': 'number'}}},
     'handler': h_find},
    {'name': 'inspect_findtext', 'description':
     'findtext TEXT [ROOT] [BUDGET] -- search by DISPLAYED TMP text, not '
     'object name. AUTO-RESUMES like inspect_find (same budget/max_nodes/'
     'end_reason contract). `include_inactive` controls whether inactive nodes are '
     'included, and the actual scope used is echoed back in `scope` -- never '
     'assume the request flag was honoured without checking it.',
     'inputSchema': {'type': 'object', 'required': ['text'], 'properties': {
         'text': {'type': 'string'},
         'root': {'type': 'string'},
         'budget': {'type': 'integer', 'description': 'nodes per round (default 40000)'},
         'max_nodes': {'type': 'integer'},
         'auto_resume': {'type': 'boolean'},
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
    {'name': 'inspect_screenshot', 'description':
     'Screenshot the EscapeFromTarkov window BY HWND, even when it is not '
     'focused/foreground (PrintWindow PW_RENDERFULLCONTENT; falls back to '
     'BitBlt and says so; a near-black/uniform result from BOTH paths is '
     'reported as a FAILURE, never handed back as if it were real). '
     'THIS IS THE MOST EXPENSIVE ACTION AVAILABLE -- use it ONLY for '
     'genuinely VISUAL questions (layout, overlap, "does this look right", '
     '"where is this on screen"). Every other question -- does a control '
     'exist, what text does it show, what state is it in -- goes through '
     'inspect_find/inspect_findtext/inspect_label/inspect_state instead. '
     'Returns a PNG PATH plus width/height/mean_luminance, never inline '
     'image bytes.',
     'inputSchema': {'type': 'object', 'properties': {
         'process': {'type': 'string', 'description': 'default EscapeFromTarkov.exe'},
         'crop': {'type': 'string', 'description': '"x,y,w,h" to grab a sub-region'},
         'max_width': {'type': 'integer', 'description': 'downscale width cap, default 1200'}}},
     'handler': h_screenshot},
    {'name': 'inspect_path', 'description':
     'Resolve a slash path like "Preloader UI/BottomPanel/Content/TaskBar/'
     'Tabs/Settings/SettingsButton" from the scene roots in ONE call -- the '
     'walk that used to be a `find` per hop, each its own round trip. Fails '
     'FAST at the first missing segment and reports whether that miss is '
     'EXHAUSTIVE (trustworthy) or STOPPED_EARLY/HIT_CAP (inconclusive, not '
     'proof of absence).',
     'inputSchema': {'type': 'object', 'required': ['path'], 'properties': {
         'path': {'type': 'string'}, 'budget': {'type': 'integer'},
         'timeout_s': {'type': 'number'}}},
     'handler': h_path},
    {'name': 'inspect_open_settings', 'description':
     'The whole fact #109 recipe as one call: walk Preloader UI -> TaskBar '
     '-> Tabs -> the Settings child (LAST child, bottom-right icon) -> '
     'SettingsButton -> component AnimatedToggle -> call rva:0x55ba430 '
     'v_pb $comp 1 -> confirm via `state` that $settings is now bound. '
     'Returns status PASS/FAIL/INCONCLUSIVE with the measured evidence at '
     'whichever step it stopped, never just a bool. A step that times out is '
     'reported as INCONCLUSIVE with may_have_run=true, NOT as an error: the '
     'batch is drained on Unity main thread and a busy client has been '
     'measured returning a timeout while the screen DID open. Does NOT launch the '
     'client or drive the mode selector -- the menu must already be up.',
     'inputSchema': {'type': 'object', 'properties': {
         'timeout_s': {'type': 'number'}}},
     'handler': h_open_settings},
    {'name': 'inspect_batch', 'description':
     'Send several raw inspector verbs in ONE channel round trip (the file '
     'channel already supports multi-line batches; this just exposes it). '
     'Returns the combined raw text plus a best-effort per-command parse -- '
     'read the `note` field: parsing multiple commands of the SAME verb '
     '(e.g. two `find`s) back out of one combined blob is unreliable, so '
     'prefer this for independent single-purpose verbs, and prefer the '
     'single-verb tools when you need precise per-call attribution.',
     'inputSchema': {'type': 'object', 'required': ['commands'], 'properties': {
         'commands': {'type': 'array', 'items': {'type': 'string'}},
         'write': {'type': 'boolean'}, 'timeout_s': {'type': 'number'}}},
     'handler': h_batch},
    {'name': 'inspect_health', 'description':
     'Is the client ALIVE, showing an ERROR DIALOG, or GONE? Reads the '
     "install's own host log -- no channel round trip -- so it answers even "
     'when the inspector channel is wedged or the client has died, which is '
     'when you most need it. USE THIS FIRST when a batch times out, when '
     'the client goes quiet, or before concluding a run is merely idle: an '
     'in-game error dialog leaves the process alive and the log silent, '
     'which is indistinguishable from a healthy client waiting at '
     'profile-select. Returns verdict ALIVE/ERRORDIALOG/GONE/UNKNOWN plus '
     'the dialog text, and `can_trust_quiet`: when false the host was NOT '
     'catching dialogs, so a quiet log proves nothing and an idle reading '
     'must be treated as INCONCLUSIVE, not as a pass.',
     'inputSchema': {'type': 'object', 'properties': {}},
     'handler': h_health},
    {'name': 'inspect_assert', 'description':
     'Run ONE named acceptance assertion from tools/acceptance.py against '
     'an ALREADY-RUNNING client with Settings ALREADY OPEN (call '
     'inspect_open_settings first) and return PASS/FAIL/INCONCLUSIVE plus '
     'the measured numbers that made the call. Does NOT launch the client '
     'or navigate menus -- per CLAUDE.md, a subagent must never start/stop '
     'the game, and this tool may run inside one. Known names: tab_count, '
     'no_donor_caption, no_placeholder_text, spawner_one_active_toggle, '
     'postfx_group, one_panel_active_per_group, no_faults, settings_json.',
     'inputSchema': {'type': 'object', 'required': ['name'], 'properties': {
         'name': {'type': 'string'}, 'root': {'type': 'string'},
         'mods_built': {'type': 'boolean'}, 'guid': {'type': 'string'}}},
     'handler': h_assert},
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
