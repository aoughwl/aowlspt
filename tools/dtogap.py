#!/usr/bin/env python
"""dtogap.py -- diff what the CLIENT deserializes against what WE emit, offline.

Mechanism (no wire capture is needed to learn the client's SHAPE):
  * client side: the DTO class the client deserializes a route into is read out
    of the DECRYPTED global-metadata via tools/il2cpp_resolve.Resolver -- the
    same resolver, behind the same mandatory System.String self-check
    (_stringLength@0x10 / _firstChar@0x14) tools/fldoff.py runs. If that
    self-check fails, NOTHING else is printed and the exit code is non-zero.
  * our side: the top-level keys we actually emit, read from a served payload
    (a capture response .json, or any file passed with --sample).

## The route -> DTO map is CURATED, and that is a real limitation

EFT's request methods are GENERIC (`Task<T> GetGlobalConfig()`), so the DTO is a
caller-supplied type argument and the route literal is a separate string in the
string-literal table; metadata does NOT hand you route -> DTO. Every entry in
ROUTES below was matched BY NAME by a human and carries how strong that match
is. `--dto <TypeName>` overrides it. A route with no entry prints INCONCLUSIVE;
it is never guessed.

## What a "hole" is, and what this tool CANNOT tell you

An EXPECTED-BUT-MISSING field is only a real hole if the client dereferences it.
Metadata gives a field's TYPE, not its use, so this reports the one thing it can
establish -- the Il2CppTypeEnum tag on the field:

  VALUE  value type (int/float/bool/enum/struct/Nullable<T>). Absent from JSON,
         Newtonsoft leaves the CLR default. It cannot NRE. It can still be
         semantically wrong (a 0 where an id was wanted).
  REF    reference type (string/class/array/List/Dictionary). Absent from JSON
         the field stays null, and ANY dereference is a crash or a hang.
         Whether it IS dereferenced is NOT established here; that needs
         disassembly of the consumers, which this tool does not do.

So the ranked output is "REF first", NOT "proven fatal first". Say so when you
quote it.

## PROVENANCE: the right-hand column is only meaningful once you know WHOSE

`--provenance ours|bsg` labels the sample, and the report names the server it
just measured. The default sample for a mapped route comes from the raid1
CAPTURE, which is REAL BSG TRAFFIC -- so by default this tool answers "what
does the client declare that even BSG omits?", NOT "what are our holes".
Unlabelled samples are refused rather than attributed to the wrong server.

## MEMBERS, not fields -- Newtonsoft binds PROPERTIES

Enumerating il2cpp FIELDS gets the member model wrong. See dto_fields.

## [JsonProperty] renames -- RESOLVED (was the dominant noise source)

EFT DTOs rename fields on the wire (`KeepAliveResponse.UtcTime` is `utc_time`,
`SelectProfileResponse.ClientSettings` is `config`). Those names live in CUSTOM
ATTRIBUTE blobs; tools/il2cpp_attrs.py now decodes them, behind its own
mandatory five-rename self-check, and this tool diffs against the WIRE name
whenever one exists. A renamed field is matched silently and annotated
`[JsonProperty]`; it no longer shows up as a false MISSING.

Residual, and it is reported rather than hidden: ~1.2% of attribute blobs in
this metadata use an argument encoding the reader does not model. A field whose
blob is unparseable is listed as ATTR-UNPARSEABLE and keeps its declared name --
its MISSING/ok verdict is INCONCLUSIVE, not a result.
"""
import argparse, json, os, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
REPO = os.path.dirname(HERE)

import gamepaths as _gp  # noqa: E402  (the binary the host runs against)
GAMEASM = _gp.gameasm()
METADEC = os.environ.get("AOWL_METADEC",
                         os.path.join(REPO, ".cache", "global-metadata.dec.dat"))

# route -> (DTO type name or None, confidence, note)
#   named  the class name is the route's own noun (strong)
#   weak   plausible by name only -- treat the output as INCONCLUSIVE
#   n/a    nothing to diff (client-sent, or no named response class)
# entries are (dto, confidence, note[, json path inside the sample])
ROUTES = {
    # LocationResponse was WRONG: it declares Location/Weathers/Season and has
    # zero overlap with what the route serves. Found by key-set search
    # (--whichdto) once [JsonProperty] renames decoded: the only type in the
    # whole assembly whose wire keys are {locations, paths}.
    "/client/locations":                   ("JsonType.LocationSettings", "named", ""),
    "/client/globals":                     ("EFT.GlobalConfiguration", "named", "", "data.config"),
    "/client/game/profile/list":           ("EFT.ProfileDescriptor", "named",
                                            "response is an ARRAY; keys taken from element [0]"),
    "/client/trading/api/getTraderAssort": ("EFT.TraderAssortment", "named", ""),
    "/client/settings":                    ("JsonType.ClientSettingsResponse", "named", ""),
    "/client/game/keepalive":              ("JsonType.KeepAliveResponse", "named", ""),
    "/client/game/profile/select":         ("JsonType.SelectProfileResponse", "named", ""),
    # NOT WeatherResponse. That type declares `Weathers` (WeatherNode[]) and
    # made this route look like it emitted an object where an array was
    # declared -- a false positive. The route's real DTO is
    # `LocationWeatherTime`, whose `Weather` is a SINGLE `WeatherNode`:
    # measured, its five members (weather, date, time, acceleration, season)
    # match BSG's own capture 131 body 5/5, and 131 sends `weather` as an
    # OBJECT, exactly as we do.
    "/client/weather":                     ("JsonType.LocationWeatherTime", "named", ""),
    "/client/trading/api/traderSettings":  ("TraderSettings", "weak", ""),
    "/client/quest/chains":                ("EFT.Quests.QuestChainsResponse", "named", ""),
    "/client/account/customization":       ("EFT.AvailableCustomizationsResponse", "named", ""),
    "/client/items":                       (None, "n/a",
                                            "payload is a dict of item templates keyed by id; there is no "
                                            "single top-level DTO -- diff a TEMPLATE with "
                                            "--dto EFT.InventoryLogic.<X>Template --path data.<id>"),
    "/client/match/local/end":             (None, "n/a",
                                            "client SENDS this (LocalRaidEnded(settings,results,lostInsured,"
                                            "transferItems)); no named response class"),

    # ---------------------------------------------------------------------
    # THE REST OF THE SURFACE.
    #
    # The 13 entries above were the whole map. The client's own backend_000.log
    # -- the authority, not this table -- shows it calls 70 distinct routes.
    # Everything below was ranked by --whichdto against a payload OUR backend
    # served (tools/oursample.py now samples all 70), then kept only where the
    # WIRE-key overlap was decisive. The score is quoted in the note, because
    # a mapping is a lead to confirm and not a measurement:
    #
    #   named   score >= 0.90 -- effectively every key accounted for
    #   weak    score 0.60-0.89 -- plausible; treat any diff as INCONCLUSIVE
    #
    # `weak` is not decoration. /client/quest/getMainQuestNotesList ranks
    # EFT.Quests.QuestNoteTemplate at 0.75, whose Links member is
    # IEnumerable<QuestNoteLink> (measured, tools/fldoff.py), and our payload
    # sends `links` as an OBJECT -- which reads as a fatal object-into-array.
    # It is not one. That payload is capture seq 074, VERBATIM BSG TRAFFIC, and
    # across every session in D:\Aowlspt\Logs the client has never once thrown
    # on this route (only 404s, from before it was served). So the DTO mapping
    # is wrong, exactly as /client/locations and /client/weather were. Marked
    # n/a rather than left to generate a confident false FATAL.
    # ---------------------------------------------------------------------
    "/client/profile/status":              ("EFT.ProfileStatusData", "named", "1.00"),
    "/client/seasonal-perks/list":         ("EFT.SeasonalPerks.SeasonalPerksData", "named", "1.00"),
    "/client/match/group/current":         ("EFT.MatchmakerGroupStatus`1", "named", "1.00"),
    "/client/tape/list":                   ("EFT.InventoryLogic.SubtitleDTO", "named", "1.00"),
    "/client/subtitle-track/list":         ("EFT.InventoryLogic.SubtitleDTO", "named", "1.00"),
    "/client/hideout/settings":            ("EFT.Hideout.HideoutSettings", "named", "1.00"),
    "/client/hideout/qte/list":            ("UI.Hideout.QteHandleData", "named", "1.00"),
    "/client/hideout/production/recipes":  ("EFT.Hideout.ProductionSchemesCollection", "named", "1.00"),
    "/client/hideout/customization/offer/list":
                                           ("EFT.Hideout.HideoutCustomizationOffersCollection", "named", "1.00"),
    "/client/hideout/areas":               ("EFT.AreaTemplateSerializer", "named", "0.91"),
    "/client/handbook/templates":          ("EFT.HandBook.Handbook", "named", "1.00"),
    "/client/game/bot/generate":           ("EFT.ProfileDescriptor", "named",
                                            "1.00; response is an ARRAY of bot profiles"),
    "/client/friends":                     ("ChatShared.ChatContacts", "named", "1.00"),
    "/client/builds/list":                 ("EFT.BuildsResponse", "named", "1.00"),
    "/client/server/list":                 ("EFT.ProfileStatus", "named", "1.00"),
    "/client/ragfair/find":                ("EFT.UI.Ragfair.OffersList", "named", "1.00"),
    "/client/game/mode":                   ("GameModeResponse", "named", "1.00"),
    "/client/items/prices":                ("EFT.SupplyData", "named",
                                            "1.00; real route is items/prices/<traderId>"),
    "/client/checkVersion":                ("EFT.CheckVersionData", "named", "1.00"),
    "/client/match/local/start":           ("JsonType.LocalSettings", "named", "1.00"),
    "/client/getMetricsConfig":            ("EFT.Utilities.ClientMetricsConfig", "named", "1.00"),
    "/client/match/join":                  ("EFT.ProfileStatusData", "named", "1.00"),
    "/client/mail/dialog/view":            ("ChatShared.ChatMessagesList", "named", "1.00"),
    "/client/mail/dialog/getAllAttachments":
                                           ("ChatShared.ChatMessagesList", "named", "1.00"),
    "/client/notifier/channel/create":     ("JsonType.NotifierParams", "weak", "0.80"),
    "/client/game/config":                 ("JsonType.LoginDataResponse", "weak", "0.67"),
    "/client/quest/list":                  ("EFT.Quests.QuestTemplate", "weak",
                                            "0.83; ties exactly with RepeatableQuestTemplate, which shares "
                                            "the same 25 keys -- the tie is not broken by key overlap"),

    # No single top-level DTO. Saying so is the result; forcing one is not.
    "/client/locale/en":                   (None, "n/a",
                                            "38,296 localisation strings keyed by id, not a DTO"),
    "/client/menu/locale/en":              (None, "n/a", "keyed localisation dict, not a DTO"),
    "/client/customization":               (None, "n/a",
                                            "728 customization templates keyed by id, like /client/items"),
    # ------------------------------------------------------------------
    # MAPPED FROM THE CLIENT OWN ERROR LOG -- the authoritative instrument.
    #
    # `--whichdto` cannot map any of these: their payloads carry 1-3 top-level
    # keys, and a one-generic-key payload ({"elements": [...]}, {"status":..})
    # has HUNDREDS of declarers among 18,629 types. Ranking by key overlap on
    # such a payload produces a 1.000 score that means nothing. That is the
    # confidence floor adopted here, and it is why these 28 stayed unmapped.
    #
    # The floor: a route is MAPPED only if EITHER
    #   (a) a client log line says `JSON parsing into <Type>` FOR THAT ROUTE
    #       -- the client naming its own deserialization target, or
    #   (b) the DTO is the UNIQUE declarer, across every type in the assembly,
    #       of the payload full key set, and at least one of those keys is
    #       route-specific rather than a generic word.
    # Anything else is n/a or INCONCLUSIVE. It is never forced.
    #
    # (a) is new and it is strictly better than key-set ranking, because it is
    # the client stating the type rather than us inferring it. It is mined by
    # tools/clientlog.py; `clientlog.py dtos` prints the route -> type table.
    # ------------------------------------------------------------------

    # THE ONE THIS WEEK TWO LIVE CRASHES LIVED ON.
    # `clientlog.py show 16`: 45 hits across 13 sessions, verbatim --
    #   JSON parsing into ChatShared.ChatRoomInformation[]
    #   Error converting value False to type 'ChatShared.ChatMessageSystemData'.
    #   Path 'data[0].message.systemData'
    # so the element type is measured, not inferred. It is independently
    # confirmed structurally: of 18,629 types exactly TWO declare
    # `attachmentsNew` -- ChatRoomInformation and UpdatableChatDialogue -- and
    # only ChatRoomInformation carries wire-lowercase names and no runtime-only
    # members (UpdatableChatDialogue holds UpdatableBindableList fields, so it
    # is the live model, not the wire DTO). Its `message` is
    # DialogueChatMessage, whose `systemData` is ChatMessageSystemData: exactly
    # the member and exactly the path the client threw on.
    #
    # NOTE THE FALSIFIER IS ABSENT, and that is stated rather than hidden: all
    # three raid1 captures for this route (136, 263, 458) have `data: []`, and
    # our own sample is `[]` too, because the capture account had no mail. So
    # there is NO key-set evidence either way here and `--whichdto` on this
    # route is INCONCLUSIVE by construction -- an empty capture body must not
    # be read as "BSG never sent this". The mapping rests on (a), not on keys.
    "/client/mail/dialog/list":            ("ChatShared.ChatRoomInformation", "named",
                                            "MEASURED from the client log (clientlog.py show 16): "
                                            "'JSON parsing into ChatShared.ChatRoomInformation[]'. "
                                            "Response is an ARRAY; keys taken from element [0]. "
                                            "Both live crash-class bugs this week were on this route."),

    # clientlog.py show 21: 'JSON parsing into EFT.Dialogs.TraderDialogsDTO'.
    # The route mapping is measured. The MEMBER audit is not: this type
    # declares ZERO fields and zero properties, so it is populated by a custom
    # converter and there is nothing to diff. Mapped anyway, because "which
    # type" and "which members" are different questions and only the second is
    # unanswerable here.
    "/client/dialogue":                    ("EFT.Dialogs.TraderDialogsDTO", "named",
                                            "client log; 0 declared members (converter-driven), so any "
                                            "member diff below is INCONCLUSIVE, not a pass"),

    # clientlog.py show 25: 'JSON parsing into
    # EFT.GlobalConfiguration+MainQuestSettings'. Independently, MainQuestSettings
    # is the UNIQUE declarer of `chapters` in the whole assembly. Two instruments,
    # same answer.
    #
    # AND A TRAP AVOIDED. Its one member is `Chapters : IEnumerable<string>`,
    # while we serve `chapters: [{"ChapterId": "..."}]` -- objects into a string
    # sequence, which reads as a certain FATAL. It is not one: raid1 capture
    # seq 073 is VERBATIM BSG TRAFFIC for this route and sends the IDENTICAL
    # array-of-objects. A defect BSG own server also commits is our audit
    # being wrong, not BSG. Member-level verdict: INCONCLUSIVE (the client must
    # read Chapters through a converter); route-level verdict: MAPPED.
    "/client/quest/getMainQuestsList":     ("MainQuestSettings", "named",
                                            "client log + unique declarer of `chapters`; the "
                                            "IEnumerable<string> vs array-of-objects mismatch is "
                                            "contradicted by BSG capture 073 -- NOT a defect"),

    # clientlog.py show 28: 'JSON parsing into EFT.Quests.RepeatableQuestsRange[]'.
    # The logged failure -- `Error converting value {null} to type System.Int32,
    # Path data[0].unavailableTime` -- is HISTORICAL: we now serve `[]`, and so
    # does BSG (captures 271 and 462 are both `[]`).
    "/client/repeatalbeQuests/activityPeriods":
                                           ("EFT.Quests.RepeatableQuestsRange", "named",
                                            "client log; response is an ARRAY; keys from element [0]"),

    # clientlog.py show 37: 'JSON parsing into EFT.AvailableCustomizationsResponse'
    # -- and the client says that type "requires a JSON array", so the response
    # is array-shaped. Same envelope type as /client/account/customization.
    #
    # THE ELEMENT TYPE IS NOT ESTABLISHED, and this is a check that would
    # otherwise not be able to fail: AvailableCustomizationsResponse declares
    # ZERO members, so diffing against it reports "nothing missing" for any
    # payload whatsoever. No type in the assembly declares {id, source, type}
    # together, so the element DTO was not found. Route MAPPED, elements
    # INCONCLUSIVE -- said out loud rather than banked as a pass.
    "/client/customization/storage":       ("EFT.AvailableCustomizationsResponse", "named",
                                            "client log; ARRAY-shaped. 0 declared members, so the "
                                            "member diff is INCONCLUSIVE, not a pass; no type declares "
                                            "the element key set {id,source,type}"),

    # ---- rule (b): UNIQUE declarer of the payload full key set ----
    # `launchTutorGame` is declared by exactly ONE type of 18,629.
    # Falsified against BSG: captures 148/257/454 all send {"launchTutorGame": <bool>}.
    "/client/tutor-game/check":            ("EFT.StartTutorialInfo", "named",
                                            "1.00, 1/1 keys, UNIQUE declarer of `launchTutorGame`; "
                                            "matches BSG captures 148/257/454"),
    # elements -> EndingElement[]; BSG capture 132 element keys match 5/5
    # (id, systemName, conditions, rewards, consequences).
    "/client/ending/list":                 ("EFT.FinalsResponse", "named",
                                            "1.00; element EFT.EndingElement matches BSG capture 132 5/5"),
    # elements -> AchievementTemplate[]; BSG capture 133 element keys 12/15
    # (the 3 BSG sends that the client does not declare are tolerated extras).
    "/client/achievement/list":            ("EFT.Achievements.AchievementsListDTO", "named",
                                            "1.00; element EFT.Achievements.AchievementTemplate "
                                            "matches BSG capture 133 12/15"),
    # elements -> Dictionary<MongoID,float>, i.e. an OBJECT, which is what we
    # serve. The sibling AchievementsListDTO declares elements as an ARRAY, so
    # these two are not interchangeable and the shape distinction is real.
    "/client/achievement/statistic":       ("EFT.Achievements.AchievementsGlobalProgressDTO", "named",
                                            "1.00; `elements` is Dictionary<MongoID,float> -- an OBJECT, "
                                            "as we serve it"),
    # season -> SeasonData; BSG captures 080/237/438 match 4/4.
    # THIS ONE IS A REAL GAP, and it is ours, not a mapping artefact: our
    # backend serves `data: {}` for this route where BSG serves
    # {"season": {...}}. Reported, not fixed here.
    "/client/season/active":               ("EFT.ActiveSeasonResponse", "named",
                                            "1.00; EFT.SeasonData matches BSG captures 080/237/438 4/4. "
                                            "WE SERVE `data: {}` -- an emulation gap, not a shape bug"),
    # battlePasses -> IReadOnlyList<BattlePassData>; BSG capture 081 element
    # keys match 6/6. `weak` and not `named` ON PURPOSE: `battlePasses` is also
    # declared by EFT.GlobalConfiguration, so this is not a unique declarer and
    # rule (b) is not satisfied outright.
    "/client/battle-pass/active":          ("BattlePassConfig", "weak",
                                            "0.83 on 1 key; NOT a unique declarer (GlobalConfiguration "
                                            "declares `battlePasses` too). Element BattlePassData does "
                                            "match BSG capture 081 6/6, but treat diffs as INCONCLUSIVE"),

    # ---- genuinely no single top-level DTO. This is a RESULT, not a gap. ----
    "/client/languages":                   (None, "n/a",
                                            "17 language names keyed by 2-letter code (BSG capture 033 "
                                            "is identical in shape); not a DTO"),
    "/client/insurance/items/list/cost":   (None, "n/a",
                                            "costs keyed by traderId, then by item template id; "
                                            "no top-level DTO"),
    "/v2/client/game/profiles/":           (None, "n/a",
                                            "profile descriptors keyed by GAME MODE (`regular`, `pve`); "
                                            "the DTO is the VALUE (EFT.ProfileDescriptor), not the "
                                            "top-level object -- diff with "
                                            "--dto EFT.ProfileDescriptor --path data.regular"),

    # ---- client-SENT, or a response with no key set at all. Nothing to diff.
    # An empty/bool/null `data` is not a DTO and saying "mapped" about it would
    # be a check that cannot fail.
    "/client/game/profile/items/moving":   (None, "n/a", "client SENDS this; the response is an "
                                            "operation result envelope, no named response class"),
    "/client/putLoadMetrics":              (None, "n/a", "telemetry sink; `data` is null"),
    "/client/putHWMetrics":                (None, "n/a", "telemetry sink; `data` is null"),
    "/client/putMetrics":                  (None, "n/a", "telemetry sink; `data` is null"),
    "/client/survey":                      (None, "n/a", "`data` is null when no survey is active"),
    "/client/raid/configuration":          (None, "n/a", "client SENDS the raid config; `data` is null"),
    "/client/match/group/exit_from_menu":  (None, "n/a", "`data` is null"),
    "/client/match/available":             (None, "n/a", "`data` is a bare bool"),
    "/client/match/group/invite/cancel-all": (None, "n/a", "`data` is a bare bool"),

    # ---- INCONCLUSIVE. Not mapped, and deliberately NOT forced. ----
    "/client/variable/group":              (None, "n/a",
                                            "INCONCLUSIVE, not n/a-by-nature: the payload is an array of "
                                            "{id, variables}, and NO type in 18,629 declares both keys. "
                                            "The DTO exists (BSG capture 075 sends the same shape); we "
                                            "did not find it."),
    "/client/prestige/list":               (None, "n/a",
                                            "INCONCLUSIVE: `elements` resolves to the OPEN generic "
                                            "EFT.BackendArrayDto`1, whose element is a type parameter. "
                                            "A closed instantiation is not nameable here, so the "
                                            "elements would go silently unaudited under it."),
    "/client/game/start":                  (None, "n/a",
                                            "INCONCLUSIVE: `{utc_time}` ties JsonType.KeepAliveResponse "
                                            "and JsonType.RegenerateTokenResponse, both 1 member. One "
                                            "generic key cannot break the tie."),
    "/client/game/version/validate":       (None, "n/a",
                                            "INCONCLUSIVE: `{isvalid}` has 7 declarers; EFT.CheckVersionData "
                                            "is plausible (it is /client/checkVersion DTO) but one key "
                                            "is not evidence."),
    "/client/game/logout":                 (None, "n/a",
                                            "INCONCLUSIVE: `{status}` is one of the most-declared names "
                                            "in the assembly; unmappable by key set."),

    "/client/quest/getMainQuestNotesList": (None, "n/a",
                                            "QuestNoteTemplate ranks 0.75 and CONTRADICTS a verbatim BSG "
                                            "capture; see the note above. Unmapped, not passed."),
}

# Generic type names Newtonsoft populates IN PLACE through a get-only
# property (ObjectCreationHandling.Auto). Arrays, strings, scalars and a bare
# IEnumerable<> are NOT here: a get-only one of those cannot be deserialized
# into at all, so it is not an inbound member.
POPULATABLE = {"Dictionary", "IDictionary", "List", "IList", "ICollection",
               "HashSet", "ISet", "Collection", "SortedDictionary"}

# Il2CppTypeEnum tags that are value types
VALUE_TAGS = set(list(range(0x02, 0x0e)) + [0x11, 0x16, 0x18, 0x19])


def selfcheck(r):
    t = r.find_one("System.String")
    got = {n: off for _dec, n, off, _st, _ty in r.all_fields(t)}
    if got.get("_stringLength") != 0x10 or got.get("_firstChar") != 0x14:
        sys.stderr.write(
            "SELF-CHECK FAILED: System.String _stringLength/_firstChar did not "
            "resolve to 0x10/0x14. No offset or field list from this resolver is "
            "trustworthy. Nothing else printed.\n")
        sys.exit(2)


def field_tag(r, tidx):
    tva = r.rq(r.TYPES_PTR + tidx * 8)
    if tva is None:
        return None
    bits = struct.unpack_from("<I", r.b, r.v2f(tva) + 8)[0]
    return (bits >> 16) & 0xFF


def _kind_of(r, tidx):
    ty = r.field_typename(tidx)
    tag = field_tag(r, tidx)
    if tag == 0x15:
        return ty, ("VALUE" if ty.startswith("Nullable<") else "REF")
    if tag in VALUE_TAGS:
        return ty, "VALUE"
    if tag is None:
        return ty, "?"
    return ty, "REF"


def _wire(at, tok, declared):
    """(wireName or None, status). Never raises."""
    if at is None:
        return None, "ok"
    try:
        return at.json_name(tok), "ok"
    except Exception as e:
        return None, "ATTR-UNPARSEABLE: %s" % e


def dto_fields(r, t, at=None, with_tidx=False):
    """(members, skipped) -- the members Newtonsoft would actually bind.

    ## Why this is not a field list

    Newtonsoft's default contract serializes PUBLIC FIELDS and PUBLIC
    PROPERTIES. Enumerating il2cpp FIELDS therefore gets the member model
    wrong in two directions at once:

      * an auto-property appears as `<X>k__BackingField` (handled before this
        by borrowing the property's attribute token), and
      * a HAND-BACKED property -- `private T _x; public T X => _x;` -- appears
        as the private field `_x`, which is NOT a serialized member at all.
        The real member is `X`. MEASURED: EFT.GlobalConfiguration declares
        `_restrictionInRaid`, `_associations`, `_overDamageFactor`, all
        private, all backing the public properties RestrictionsInRaid /
        Associations / OverDamageFactor. Diffing the FIELD names produced
        three false MISSING rows for keys the payload was already emitting.

    So members are enumerated as: every instance PROPERTY with a getter that
    is public (or carries [JsonProperty]); plus every instance FIELD that is
    public (or carries [JsonProperty]), excluding compiler-generated backing
    fields for properties already listed. Everything else is returned in
    `skipped` with a reason -- it is deliberately NOT a candidate hole,
    because Newtonsoft would never have populated it.

    members: [(name, wire, typename, kind, declaring, attrstatus, origin)]
    With with_tidx=True each member tuple carries an EIGHTH element: the
    member's Il2CppType index. dtotype's recursive walk needs the TYPE, not
    its printable name -- a name like `Dictionary<String,MainQuestSettings>`
    has to be re-resolved by string, and a short name that is not unique
    cannot be resolved at all, so nesting under it would go silently
    unaudited. The index is exact. Existing callers unpack seven and are
    untouched.
    skipped: [(name, declaring, reason)]     inherited first, in both.
    """
    r._ensure_fields()
    chain, cur, seen = [], t, set()
    while cur is not None and cur not in seen:
        seen.add(cur)
        chain.append(cur)
        cur = r.parent_type(cur)
    out, skipped = [], []
    for ct in reversed(chain):
        ns, nm = r.tname(ct)
        full = (ns + "." + nm) if ns else nm
        if full in ("System.Object", "System.ValueType"):
            continue
        props = at.type_properties(ct) if at is not None else []
        backing = set()
        for pname, ptok, gmi, smi in props:
            backing.add("<%s>k__BackingField" % pname)
            if gmi is None:                      # write-only: never emitted
                skipped.append((pname, full, "property has no getter"))
                continue
            wire, st = _wire(at, ptok, pname)
            if (at.method_flags(gmi) & 7) != at.MAS_PUBLIC and not wire:
                skipped.append((pname, full, "non-public getter, no [JsonProperty]"))
                continue
            rt = struct.unpack_from("<i", r.m, r.M_OFF + gmi * r.MS + 8)[0]
            ty, kind = _kind_of(r, rt) if rt >= 0 else ("?", "?")
            origin = "prop"
            if smi is None:
                # A get-only property is only an INBOUND member if Newtonsoft
                # can populate the existing instance in place, which it does
                # for ICollection-shaped types and does NOT do for a scalar,
                # a string, an array or a bare IEnumerable<>. MEASURED: this
                # is what separates GlobalConfiguration.OverDamageFactor
                # (get-only Dictionary<EBodyPart,float> -- a real member the
                # payload omits) from TraderSettings.FullName (get-only
                # string, a computed helper that nothing can deserialize into
                # and that appeared as a false MISSING).
                if not ty.split("<")[0] in POPULATABLE:
                    skipped.append((pname, full,
                                    "get-only %s: Newtonsoft cannot bind it" % ty))
                    continue
                origin = "prop/get-only-collection"
            out.append((pname, wire, ty, kind, full, st, origin)
                       + ((rt,) if with_tidx else ()))

        bb = r.TD_OFF + ct * r.TDS
        fs = struct.unpack_from("<i", r.m, bb + 32)[0]
        fc = struct.unpack_from("<H", r.m, bb + 68)[0]
        for i in range(fc):
            ni, ti, tok = struct.unpack_from("<iiI", r.m, r.FLD_OFF + (fs + i) * 12)
            if r.field_is_static(ti):
                continue
            fname = r.s(ni)
            if fname in backing:
                continue                          # the property is the member
            fattrs = r.field_attrs(ti)
            wire, st = _wire(at, tok, fname)
            if fattrs & 0x0080:                   # NotSerialized
                skipped.append((fname, full, "field is NOTSERIALIZED"))
                continue
            if (fattrs & 7) != 6 and not wire:    # not public, no [JsonProperty]
                skipped.append((fname, full, "non-public field, no [JsonProperty]"))
                continue
            ty, kind = _kind_of(r, ti)
            out.append((fname, wire, ty, kind, full, st, "field")
                       + ((ti,) if with_tidx else ()))
    return out, skipped


# ------------------------------------------------------- member self-check
#
# Ground truth: hand-backed properties MEASURED in this metadata, where the
# private field and the public property have DIFFERENT names, so a field-only
# enumeration is falsifiably wrong. Each row is
#   (type, must-be-a-member, must-NOT-be-a-member, origin)
MEMBER_GROUND = [
    # the three the field-only model reported as false MISSING on /client/globals
    ("EFT.GlobalConfiguration", "RestrictionsInRaid", "_restrictionInRaid", "prop"),
    ("EFT.GlobalConfiguration", "Associations", "_associations",
     "prop/get-only-collection"),
    ("EFT.GlobalConfiguration", "OverDamageFactor", "_overDamageFactor",
     "prop/get-only-collection"),
    # three more, found by running the new model against
    # /client/trading/api/traderSettings: private caches with no property at
    # all, which the field model listed as candidate holes.
    ("TraderSettings", "BuysItems", "_avatar", "prop"),
    ("TraderSettings", "SellItems", "_avatarGetter", "prop"),
    ("TraderSettings", "TransferableItems", "_avatarTask", "prop"),
]
# get-only members Newtonsoft CANNOT bind: must be absent from the member set.
MEMBER_GROUND_ABSENT = [("TraderSettings", "FullName"),
                        ("TraderSettings", "FirstName"),
                        ("TraderSettings", "Description")]
# renames that must survive the property model (the attribute is on the prop)
MEMBER_GROUND_WIRE = [("TraderSettings", "BuysItems", "items_buy"),
                      ("TraderSettings", "SellItems", "items_sell")]


def member_selfcheck(r, at):
    """Mandatory. Prints nothing on success; exits 4 on failure.

    Asserts properties of the FINISHED member set, not of the enumeration that
    produced it: a name that must be there, a name that must NOT, the origin
    that must have produced it, and -- across every ground type -- that no
    compiler-generated `<X>k__BackingField` survived as a member at all.
    """
    bad = []
    cache = {}

    def members(tn):
        if tn not in cache:
            cache[tn] = dto_fields(r, r.find_one(tn), at)[0]
        return cache[tn]

    for tn, want, unwanted, origin in MEMBER_GROUND:
        ms = {m[0]: m for m in members(tn)}
        if want not in ms:
            bad.append("%s: property %r is not a member" % (tn, want))
        elif ms[want][6] != origin:
            bad.append("%s.%s: origin %r, expected %r"
                       % (tn, want, ms[want][6], origin))
        if unwanted in ms:
            bad.append("%s: private field %r is still a member (it backs %r "
                       "or is not serialized at all)" % (tn, unwanted, want))
    for tn, unwanted in MEMBER_GROUND_ABSENT:
        if unwanted in {m[0] for m in members(tn)}:
            bad.append("%s: get-only non-collection %r is a member; Newtonsoft "
                       "cannot deserialize into it" % (tn, unwanted))
    for tn, want, wire in MEMBER_GROUND_WIRE:
        got = {m[0]: m[1] for m in members(tn)}.get(want)
        if got != wire:
            bad.append("%s.%s wire name %r, expected %r" % (tn, want, got, wire))
    for tn in {g[0] for g in MEMBER_GROUND}:
        for m in members(tn):
            if m[0].startswith("<") and m[0].endswith(">k__BackingField"):
                bad.append("%s: %s leaked into the member set" % (tn, m[0]))
    if bad:
        sys.stderr.write(
            "MEMBER SELF-CHECK FAILED -- the property/field member model does\n"
            "not reproduce known ground truth, so NO missing/ok verdict below\n"
            "is trustworthy. Nothing else printed.\n  "
            + ("\n  ".join(bad)) + "\n")
        sys.exit(4)


def emitted_keys(path, jpath):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        doc = json.load(fh)
    for part in [p for p in jpath.split(".") if p]:
        if isinstance(doc, list):
            doc = doc[int(part)]
        elif isinstance(doc, dict):
            doc = doc.get(part)
        else:
            return None
        if doc is None:
            return None
    if isinstance(doc, list):
        doc = doc[0] if doc else {}
    if not isinstance(doc, dict):
        return None
    return list(doc.keys())


# ---------------------------------------------------------------- PROVENANCE
#
# THE HEADLINE NUMBER IS MEANINGLESS WITHOUT THIS.
#
# dtogap's right-hand column is "the keys this payload carries". For months the
# default payload for /client/globals was
# mods/tarkov/data/capture/raid1/responses/large/084.json -- and that capture
# is REAL BSG TRAFFIC, not ours: manifest seq 084 carries `resp_xenc: aes` and
# a `PHPSESSID=sh8-...` cookie, neither of which our backend produces. So every
# "EXPECTED-BUT-MISSING" row printed for that route described a field the
# client declares AND BSG ITSELF NEVER SENT. Attributing that to us reported
# BSG's fidelity as though it were our emulation's, which is wrong in KIND, not
# in detail: those rows are client-TOLERATED absences, not holes.
#
# So a sample now carries a provenance and the report says, in its headline,
# which server it just measured. If provenance cannot be established the tool
# refuses to print a diff at all rather than attribute it to the wrong server.

PROV_OURS, PROV_BSG, PROV_UNKNOWN = "OURS", "BSG", "UNKNOWN"


def capture_manifest_entry(sample):
    """The manifest row for a capture response file, or None."""
    sample = os.path.abspath(sample)
    d = os.path.dirname(sample)
    for _ in range(4):
        man = os.path.join(d, "manifest.json")
        if os.path.exists(man):
            seq = os.path.basename(sample).split(".")[0].split("_")[0]
            try:
                for e in json.load(open(man, encoding="utf-8")):
                    if e.get("seq") == seq:
                        return e
            except Exception:
                return None
            return None
        d = os.path.dirname(d)
    return None


def provenance_of(sample, forced=None):
    """(PROV_*, evidence string). Never guesses silently."""
    if forced:
        return forced.upper(), "asserted on the command line (--provenance %s)" % forced
    e = capture_manifest_entry(sample)
    if e is not None:
        marks = []
        if e.get("resp_xenc"):
            marks.append("resp_xenc=%s" % e["resp_xenc"])
        if e.get("cookie"):
            marks.append("a session cookie (%s...)" % e["cookie"].split("=")[0])
        if marks:
            return PROV_BSG, ("capture manifest seq %s carries %s -- our backend "
                              "emits neither" % (e.get("seq"), " and ".join(marks)))
        return PROV_UNKNOWN, ("capture manifest seq %s has no BSG marker and no "
                              "ours marker" % e.get("seq"))
    if os.sep + "capture" + os.sep in os.path.abspath(sample):
        return PROV_UNKNOWN, "under a capture/ tree but no manifest row was found"
    return PROV_UNKNOWN, "no capture manifest describes this file"


_NL = chr(10)
PROV_REFUSAL = (
    "REFUSING to print a diff for %s: the provenance of the sample %s could not"
    + _NL + "be established (%s), and a key-set diff means the OPPOSITE thing"
    + _NL + "depending on which server produced it:" + _NL
    + "  --provenance ours  our backend served it -> missing rows are CANDIDATE HOLES" + _NL
    + "  --provenance bsg   a live BSG capture     -> missing rows are absences the" + _NL
    + "                                              CLIENT TOLERATES, not our bugs" + _NL
    + "Pass one. Unlabelled, the headline number would be attributed to the wrong" + _NL
    + "server, which is the failure this tool exists to avoid." + _NL)


# The BSG capture root.  Overridable, and for the same reason oursample.py
# overrides it: `responses/large/*.json` are not tracked by git, so a fresh
# worktree has the small bodies and none of the large ones, and the BSG half of
# any comparison would go silently INCONCLUSIVE there.
CAPTURE_ROOT = os.environ.get(
    "AOWL_CAPTURE",
    os.path.join(REPO, "mods", "tarkov", "data", "capture", "raid1"))


def find_capture(route):
    """The first captured BSG response for `route`, or None.

    A route whose real URL carries a trailing id (getTraderAssort/<traderId>)
    never matched here, because the manifest url is compared for EQUALITY.
    That is not "BSG never served it" -- it is "we looked it up wrong", and the
    two are indistinguishable in the output, so a PREFIX match is tried after
    the exact one.  Exact wins: a prefix hit must not shadow a real row.
    """
    base = CAPTURE_ROOT
    man = os.path.join(base, "manifest.json")
    if not os.path.exists(man):
        return None
    want = route.rstrip("/")
    with open(man, encoding="utf-8") as fh:
        rows = json.load(fh)

    def body(e):
        for sub in ("", "large"):
            p = os.path.join(base, "responses", sub, e["seq"] + ".json")
            if os.path.exists(p):
                return p
        return None

    for p in _capture_paths(rows, base, want, body):
        return p
    return None


def _capture_paths(rows, base, want, body):
    for exact in (True, False):
        for e in rows:
            u = e.get("url", "").split("?")[0].rstrip("/")
            hit = (u == want) if exact else u.startswith(want + "/")
            if not hit:
                continue
            p = body(e)
            if p:
                yield p


def find_captures(route):
    """EVERY captured BSG body for `route`, in manifest order.

    `find_capture` returns the FIRST, and for /client/game/profile/list that
    is seq 083 -- captured before a profile existed, so `data` is an EMPTY
    LIST. Anything using it as the falsifier for our payload therefore had
    NOTHING to compare against and silently reported five FATAL rows
    (`Inventory.equipment` and friends) that seq 208 shows BSG sending as
    strings, exactly as we do. An empty body must not be mistaken for "BSG
    never sent this".
    """
    base = CAPTURE_ROOT
    man = os.path.join(base, "manifest.json")
    if not os.path.exists(man):
        return []
    with open(man, encoding="utf-8") as fh:
        rows = json.load(fh)

    def body(e):
        for sub in ("", "large"):
            p = os.path.join(base, "responses", sub, e["seq"] + ".json")
            if os.path.exists(p):
                return p
        return None

    return list(_capture_paths(rows, base, route.rstrip("/"), body))


def report(r, route, dto, conf, note, sample, jpath, at=None, prov=None):
    print("=" * 74)
    if not dto:
        print("%s\n  INCONCLUSIVE: no DTO mapped. %s" % (route, note))
        return
    try:
        t = r.find_one(dto)
    except SystemExit as e:
        print("%s\n  INCONCLUSIVE: DTO %r -- %s" % (route, dto, e))
        return
    flds, skipped = dto_fields(r, t, at)
    if not sample:
        # NOT `find_capture`. That returns the FIRST captured body, and an
        # empty first body is the trap this module's own find_captures
        # docstring documents: seq 083 for /client/game/profile/list was
        # recorded before a profile existed, so `data` is `[]`, and the diff
        # then reports every declared member as absent. Take the first capture
        # that actually carries something at `jpath`; fall back to the first
        # body so the "EMPTY -- zero keys to diff" INCONCLUSIVE is still
        # printed when EVERY capture is empty (which is the true state of
        # /client/mail/dialog/list: 136, 263 and 458 are all `data: []`).
        for _p in find_captures(route):
            if emitted_keys(_p, jpath):
                sample = _p
                break
        else:
            sample = find_capture(route)
    if not sample:
        print("%s  DTO=%s [%s]" % (route, dto, conf))
        print("  INCONCLUSIVE: no served payload for this route (not in raid1 "
              "capture, and no --sample). Client declares %d serializable "
              "members:" % len(flds))
        for n, w, ty, kind, _d, st, _o in flds:
            nm = n if not w or w == n else "%s -> %s" % (n, w)
            print("    EXPECTED %-40s %-38s %s%s"
                  % (nm, ty, kind, "" if st == "ok" else "  " + st))
        return
    if not os.path.exists(sample):
        # This used to be `"%s" + _NL + "..." % (route, sample)`, where the `%`
        # binds to the LAST literal only -- so the one path that reports a
        # missing sample raised TypeError instead of reporting it.
        print("%s%s  INCONCLUSIVE: sample %r does not exist. (Under Git Bash a "
              "leading-slash path is rewritten; use a Windows-style path or "
              "MSYS_NO_PATHCONV=1.)" % (route, _NL, sample))
        return
    who, why = provenance_of(sample, prov)
    if who == PROV_UNKNOWN:
        print(PROV_REFUSAL % (route, os.path.relpath(sample, REPO), why))
        return
    emitted = emitted_keys(sample, jpath)
    if emitted == []:
        print("%s\n  INCONCLUSIVE: %s has an object at --path %r but it is EMPTY "
              "-- zero keys to diff against. This is not 'nothing is missing'."
              % (route, os.path.relpath(sample, REPO), jpath))
        return
    if emitted is None:
        print("%s\n  INCONCLUSIVE: %s has no object at --path %r."
              % (route, os.path.relpath(sample, REPO), jpath))
        return
    low = {e.lower(): e for e in emitted}
    seen, both, missing = set(), [], []
    inconcl = []
    for n, w, ty, kind, dec, st, orig in flds:
        cands = [w, n] if w else [n]
        k = next((low[c.lower()] for c in cands if c.lower() in low), None)
        if k:
            seen.add(k)
            both.append((n, w, k, ty, orig))
        elif st != "ok":
            inconcl.append((n, ty, kind, dec, st))
        else:
            missing.append((n, w, ty, kind, dec, orig))
    unknown = [e for e in emitted if e not in seen]
    print("%s  DTO=%s [%s]  sample=%s" % (route, dto, conf,
                                          os.path.relpath(sample, REPO)))
    if who == PROV_BSG:
        print("  MEASURING: **BSG's own server**, not us (%s)." % why)
        print("  So the question answered below is 'what does the client declare "
              "that even BSG omits?' -- a real question, but NOT 'what are our "
              "emulation holes'. Rows below are CLIENT-TOLERATED ABSENCES.")
    else:
        print("  MEASURING: OUR backend's served payload (%s)." % why)
    if note:
        print("  note: %s" % note)
    if not both and emitted and flds:
        print("  *** MAPPING LIKELY WRONG: zero overlap between %d declared client "
              "members and %d emitted keys. Treat everything below as INCONCLUSIVE "
              "-- a curated route->DTO guess that misses is indistinguishable from "
              "a totally unimplemented route." % (len(flds), len(emitted)))
    print("  EMITTED-AND-EXPECTED  %d" % len(both))
    for n, w, k, ty, orig in both:
        if w and w.lower() == k.lower():
            extra = "   [JsonProperty %r]" % w
        elif n == k:
            extra = ""
        else:
            extra = "   (case differs: emitted %r)" % k
        print("    ok       %-34s %s%s" % (n, ty, extra))
    if who == PROV_BSG:
        print("  DECLARED-BUT-ABSENT-FROM-BSG  %d   <-- the CLIENT TOLERATES "
              "these; they are NOT holes in our emulation, REF first" % len(missing))
    else:
        print("  EXPECTED-BUT-MISSING  %d   <-- candidate holes, REF first" % len(missing))
    for n, w, ty, kind, dec, orig in sorted(missing,
                                            key=lambda x: (x[3] != "REF", x[0])):
        nm = n if not w else "%s -> %s" % (n, w)
        print("    %-8s %-40s %-38s %-5s  (%s, %s)"
              % ("ABSENT" if who == PROV_BSG else "MISSING",
                 nm, ty, kind, dec, orig))
    if inconcl:
        print("  ATTR-UNPARSEABLE      %d   <-- INCONCLUSIVE: the wire name for "
              "these could not be decoded, so neither a match nor a gap is "
              "established" % len(inconcl))
        for n, ty, kind, dec, st in inconcl:
            print("    unknown  %-34s %-38s %-5s  %s" % (n, ty, kind, st))
    if skipped:
        print("  NOT-A-MEMBER          %d   (declared, but Newtonsoft would not "
              "bind it: private/NotSerialized with no [JsonProperty]. NOT holes.)"
              % len(skipped))
    print("  %-21s %d   (%s)"
          % ("PRESENT-BUT-UNKNOWN" if who == PROV_BSG else "EMITTED-BUT-UNKNOWN",
             len(unknown),
             "BSG sends it; no such client member"
             if who == PROV_BSG else "we send it; no such client member"))
    for e in unknown:
        print("    extra    %s" % e)


def which(r, at, route, sample, jpath):
    """Rank candidate DTOs for a payload by WIRE-key overlap.

    Only possible now that renames decode; before that the declared names of a
    correct DTO overlapped the payload barely better than a wrong one's. Prints
    a SCORE, never a verdict: a top hit is a lead to confirm, and a top score
    well under 1.0 is evidence the payload has no single DTO at all.
    """
    sample = sample or (find_capture(route) if route else None)
    if not sample:
        print("INCONCLUSIVE: no sample (pass --sample)")
        return
    if not os.path.exists(sample):
        # `report()` has always handled this; `which()` did not, and raised a
        # raw FileNotFoundError traceback -- which reads as "the tool is
        # broken" rather than "your path is wrong". Git Bash rewrites a
        # /c/... path, so this is the ordinary case, not the exotic one.
        print("INCONCLUSIVE: sample %r does not exist, so NOTHING was ranked. "
              "(Under Git Bash a /c/... path is rewritten; use a Windows-style "
              "path like C:/... or MSYS_NO_PATHCONV=1.)" % sample)
        return
    emitted = emitted_keys(sample, jpath)
    if not emitted:
        print("INCONCLUSIVE: no non-empty object at --path %r in %s"
              % (jpath, os.path.relpath(sample, REPO)))
        return
    want = set(k.lower() for k in emitted)
    rows = []
    r._ensure_fields()
    for t in range(r.NTYPES):
        try:
            names = set()
            for n, w, _ty, _k, _d, st, _o in dto_fields(r, t, at)[0]:
                names.add((w or n).lower())
        except Exception:
            continue
        if not names:
            continue
        hit = len(want & names)
        if hit < 2:
            continue
        rows.append((hit / float(len(want)), hit, len(names), t))
    rows.sort(reverse=True)
    print("payload %s --path %s : %d keys"
          % (os.path.relpath(sample, REPO), jpath, len(want)))
    for sc, hit, nf, t in rows[:10]:
        ns, nm = r.tname(t)
        print("  %.3f  %2d/%d keys matched  %-14s %s"
              % (sc, hit, len(want), "(%d fields)" % nf,
                 (ns + "." + nm) if ns else nm))
    if not rows:
        print("  nothing scored >=2 matching keys. Either the payload is a "
              "keyed dictionary rather than a DTO, or nothing deserializes it.")


def route_guard(route):
    """Refuse a mangled route argument instead of answering about it.

    Git Bash / MSYS rewrites any argument that LOOKS like a unix path into a
    Windows one before python ever sees it, so `dtogap.py /client/globals`
    arrives as `C:/Program Files/Git/client/globals`. dtogap then found no
    such key in ROUTES and printed a confident "route not in ROUTES" -- a
    plausible wrong answer about a route that is in fact mapped. Detect it and
    say so.
    """
    if route.startswith("/") and "/Git/" not in route:
        return
    mangled = ("/Git/" in route.replace("\\", "/")
               or (len(route) > 2 and route[1] == ":")
               or route.startswith("\\"))
    if not mangled:
        return
    tail = route.replace("\\", "/")
    i = tail.find("/Git/")
    guess = tail[i + 4:] if i >= 0 else None
    sys.stderr.write(
        "REFUSING: the route argument %r is an ABSOLUTE FILESYSTEM PATH, not a\n"
        "route. Git Bash (MSYS) rewrote a leading-slash argument into a Windows\n"
        "path before python saw it. This is NOT 'route not in ROUTES'.\n"
        "Re-run with path conversion off:\n"
        "    MSYS_NO_PATHCONV=1 python tools/dtogap.py %s\n"
        "or use PowerShell, where no rewriting happens.\n"
        % (route, guess or "/client/<route>"))
    sys.exit(5)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("route", nargs="?", help="e.g. /client/locations ; omit to list the map")
    ap.add_argument("--dto", help="override the curated DTO type name")
    ap.add_argument("--sample", help="JSON file holding a served response")
    ap.add_argument("--provenance", choices=["ours", "bsg"],
                    help="WHICH SERVER produced --sample. Required unless it can "
                         "be established from a capture manifest. Without it the "
                         "diff is attributed to the wrong server.")
    ap.add_argument("--path", default="data", help="json path inside the sample (default: data)")
    ap.add_argument("--all", action="store_true", help="run every mapped route")
    ap.add_argument("--whichdto", action="store_true",
                    help="do not diff: rank every type in the assembly by how "
                         "well its WIRE key set matches the sample, to find or "
                         "falsify a route->DTO mapping")
    a = ap.parse_args()

    if a.route:
        route_guard(a.route)

    if not a.route and not a.all:
        for k in sorted(ROUTES):
            d, c, n = ROUTES[k][:3]
            print("%-40s %-40s [%s] %s" % (k, d, c, n))
        return

    from il2cpp_resolve import Resolver
    r = Resolver(GAMEASM, METADEC)
    selfcheck(r)
    import il2cpp_attrs
    at = il2cpp_attrs.selfcheck(r)
    member_selfcheck(r, at)

    if a.whichdto:
        which(r, at, a.route, a.sample, a.path)
        return

    for route in (sorted(ROUTES) if a.all else [a.route]):
        ent = list(ROUTES.get(route, (None, "unmapped", "route not in ROUTES")))
        while len(ent) < 4:
            ent.append(None)
        d, c, n, p_ = ent
        report(r, route, a.dto or d, c, n, a.sample,
               a.path if a.path != "data" else (p_ or "data"), at, a.provenance)


if __name__ == "__main__":
    main()
