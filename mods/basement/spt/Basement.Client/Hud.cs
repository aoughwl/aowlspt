using System;
using System.Collections.Generic;
using BepInEx.Configuration;
using UnityEngine;

namespace Basement.Client
{
    /// <summary>
    /// Transient lines on screen: say subtitles, hud.note, heard.* and the
    /// link state. IMGUI, because it works in every scene and needs no prefab.
    /// Never the source of truth for anything.
    ///
    /// ------------------------------------------------------------------------
    /// PRESETS AND OVERRIDES (BepInEx section [Subtitles], F12)
    /// ------------------------------------------------------------------------
    /// A preset is a set of DEFAULTS, not a lock. `Preset` picks one of four
    /// looks; every individual entry below is an explicit override that WINS
    /// over the preset when it is set to anything but its "follow the preset"
    /// value (`FromPreset` for the enums, 0 for the numbers, empty for the
    /// colours, `Default` for the tri-state booleans). That three-state shape
    /// is deliberate: a plain `bool` override cannot express "I have not
    /// chosen", so switching preset would silently keep whatever the bool
    /// happened to be, and the preset would look broken.
    ///
    /// Every entry is read AT DRAW TIME. There is no cached style struct and no
    /// restart: change something in the F12 menu and the next frame draws it.
    /// The one exception is `_style`, an IMGUI GUIStyle that is rebuilt when
    /// the font size or colour it was built for no longer matches.
    ///
    /// Only AUDIBLE lines are subtitled: `Say.Enqueue` drops what the backend
    /// marked `audible:false` before it ever reaches here, so a subtitle is
    /// never the transcript of something the player could not hear.
    /// </summary>
    internal static class Hud
    {
        // ------------------------------------------------------------ config

        internal enum SubtitlePreset { Classic, Log, Minimal, Off }
        internal enum SubtitlePosition { FromPreset, TopLeft, TopCenter, BottomCenter, BottomLeft }
        internal enum TriState { Default, On, Off }

        internal static ConfigEntry<SubtitlePreset> Preset;
        internal static ConfigEntry<SubtitlePosition> Position;
        internal static ConfigEntry<int> FontSize;
        internal static ConfigEntry<string> TextColor;
        internal static ConfigEntry<string> NameColor;
        internal static ConfigEntry<TriState> Outline;
        internal static ConfigEntry<TriState> Background;
        internal static ConfigEntry<float> BackgroundAlpha;
        internal static ConfigEntry<int> MaxLines;
        internal static ConfigEntry<float> SecondsPerLine;
        internal static ConfigEntry<float> SecondsPerWord;
        internal static ConfigEntry<TriState> ShowSpeakerName;
        internal static ConfigEntry<TriState> ShowDistance;
        internal static ConfigEntry<TriState> ShowPartials;
        internal static ConfigEntry<TriState> ShowSystemWarnings;
        internal static ConfigEntry<float> Width;

        /// <summary>
        /// Binds [Subtitles]. Called from Plugin.Awake. CLASSIC IS THE DEFAULT:
        /// bottom-centre, outlined white on the speaker's colour, the way a
        /// subtitle has looked since before any of us were born. The old
        /// top-left stack is still there as `Log`, because it is the better
        /// shape when you are debugging and want six lines of history.
        /// </summary>
        internal static void Bind(ConfigFile cfg)
        {
            Preset = cfg.Bind("Subtitles", "Preset", SubtitlePreset.Classic,
                new ConfigDescription(
                    "Classic = bottom-centre, outlined, speaker name in colour, 2 lines. " +
                    "Log = the old top-left stack, 6 lines, no outline (best for debugging). " +
                    "Minimal = bottom-centre, one line, no names. Off = no subtitles at all " +
                    "(dialogue still plays; hud.note and warnings follow ShowSystemWarnings).",
                    null, new ConfigurationManagerAttributes { Order = 100 }));

            Position = cfg.Bind("Subtitles", "Position", SubtitlePosition.FromPreset,
                new ConfigDescription("FromPreset = whatever the preset says. Anything else overrides it.",
                    null, new ConfigurationManagerAttributes { Order = 90 }));
            FontSize = cfg.Bind("Subtitles", "FontSize", 0,
                new ConfigDescription("0 = from the preset (Classic 22, Log 15, Minimal 20). Otherwise the point size.",
                    new AcceptableValueRange<int>(0, 60), new ConfigurationManagerAttributes { Order = 89 }));
            Width = cfg.Bind("Subtitles", "WidthFraction", 0f,
                new ConfigDescription("0 = from the preset (Classic 0.6 of the screen, Log 0.5, Minimal 0.5).",
                    new AcceptableValueRange<float>(0f, 1f), new ConfigurationManagerAttributes { Order = 88 }));
            TextColor = cfg.Bind("Subtitles", "TextColor", "",
                new ConfigDescription("Empty = from the preset. Otherwise #RRGGBB or #RRGGBBAA.",
                    null, new ConfigurationManagerAttributes { Order = 80 }));
            NameColor = cfg.Bind("Subtitles", "NameColor", "",
                new ConfigDescription("Empty = from the preset. The speaker's name is drawn in this colour.",
                    null, new ConfigurationManagerAttributes { Order = 79 }));
            Outline = cfg.Bind("Subtitles", "Outline", TriState.Default,
                new ConfigDescription("A one-pixel black outline behind the glyphs. Default = from the preset (on for Classic and Minimal).",
                    null, new ConfigurationManagerAttributes { Order = 78 }));
            Background = cfg.Bind("Subtitles", "Background", TriState.Default,
                new ConfigDescription("A dark box behind the text. Default = from the preset (off everywhere; turn it on if outlines are not enough on snow).",
                    null, new ConfigurationManagerAttributes { Order = 77 }));
            BackgroundAlpha = cfg.Bind("Subtitles", "BackgroundAlpha", 0.55f,
                new ConfigDescription("How opaque that box is. Ignored when Background is off.",
                    new AcceptableValueRange<float>(0f, 1f), new ConfigurationManagerAttributes { Order = 76 }));
            MaxLines = cfg.Bind("Subtitles", "MaxLines", 0,
                new ConfigDescription("0 = from the preset (Classic 2, Log 6, Minimal 1). The oldest line goes when a new one arrives.",
                    new AcceptableValueRange<int>(0, 10), new ConfigurationManagerAttributes { Order = 70 }));
            SecondsPerLine = cfg.Bind("Subtitles", "SecondsPerLine", 0f,
                new ConfigDescription("0 = from the preset (Classic 4). The floor on how long a line stays.",
                    new AcceptableValueRange<float>(0f, 30f), new ConfigurationManagerAttributes { Order = 69 }));
            SecondsPerWord = cfg.Bind("Subtitles", "SecondsPerWord", 0f,
                new ConfigDescription("0 = from the preset (Classic 0.28). Added per word, so a long line is not gone before it is read. Capped at 6 s over the floor.",
                    new AcceptableValueRange<float>(0f, 2f), new ConfigurationManagerAttributes { Order = 68 }));
            ShowSpeakerName = cfg.Bind("Subtitles", "ShowSpeakerName", TriState.Default,
                new ConfigDescription("Default = from the preset (on for Classic and Log, off for Minimal).",
                    null, new ConfigurationManagerAttributes { Order = 60 }));
            ShowDistance = cfg.Bind("Subtitles", "ShowDistance", TriState.Default,
                new ConfigDescription("Append the speaker's distance, \"(27 m)\". Default = off. Useful while tuning hearSpeakM/hearYellM.",
                    null, new ConfigurationManagerAttributes { Order = 59 }));
            ShowPartials = cfg.Bind("Subtitles", "ShowPartials", TriState.Default,
                new ConfigDescription("The live transcript of YOUR OWN speech while the push-to-talk key is held. Default = on.",
                    null, new ConfigurationManagerAttributes { Order = 58 }));
            ShowSystemWarnings = cfg.Bind("Subtitles", "ShowSystemWarnings", TriState.Default,
                new ConfigDescription("Link failures, refused directives and the like -- separate from dialogue. Default = on. Turning this off does NOT silence the BepInEx log, so nothing is lost, only hidden.",
                    null, new ConfigurationManagerAttributes { Order = 57 }));
        }

        // --------------------------------------------- preset -> effective value

        private static SubtitlePreset P => Preset != null ? Preset.Value : SubtitlePreset.Classic;

        private static bool Tri(ConfigEntry<TriState> e, bool fromPreset)
        {
            if (e == null || e.Value == TriState.Default) return fromPreset;
            return e.Value == TriState.On;
        }

        private static SubtitlePosition EffPosition
        {
            get
            {
                if (Position != null && Position.Value != SubtitlePosition.FromPreset) return Position.Value;
                switch (P)
                {
                    case SubtitlePreset.Log: return SubtitlePosition.TopLeft;
                    case SubtitlePreset.Minimal: return SubtitlePosition.BottomCenter;
                    default: return SubtitlePosition.BottomCenter;
                }
            }
        }
        private static int EffFontSize
        {
            get
            {
                if (FontSize != null && FontSize.Value > 0) return FontSize.Value;
                switch (P) { case SubtitlePreset.Log: return 15; case SubtitlePreset.Minimal: return 20; default: return 22; }
            }
        }
        private static float EffWidth
        {
            get
            {
                if (Width != null && Width.Value > 0f) return Width.Value;
                return P == SubtitlePreset.Classic ? 0.6f : 0.5f;
            }
        }
        private static int EffMaxLines
        {
            get
            {
                if (MaxLines != null && MaxLines.Value > 0) return MaxLines.Value;
                switch (P) { case SubtitlePreset.Log: return 6; case SubtitlePreset.Minimal: return 1; default: return 2; }
            }
        }
        private static float EffSecondsPerLine => (SecondsPerLine != null && SecondsPerLine.Value > 0f) ? SecondsPerLine.Value : 4f;
        private static float EffSecondsPerWord => (SecondsPerWord != null && SecondsPerWord.Value > 0f) ? SecondsPerWord.Value : (P == SubtitlePreset.Log ? 0f : 0.28f);
        private static bool EffOutline => Tri(Outline, P == SubtitlePreset.Classic || P == SubtitlePreset.Minimal);
        private static bool EffBackground => Tri(Background, false);
        private static bool EffNames => Tri(ShowSpeakerName, P != SubtitlePreset.Minimal);
        private static bool EffDistance => Tri(ShowDistance, false);
        private static bool EffPartials => Tri(ShowPartials, true);
        private static bool EffWarnings => Tri(ShowSystemWarnings, true);

        private static Color EffTextColor => ParseColor(TextColor != null ? TextColor.Value : "", Color.white);
        private static Color EffNameColor => ParseColor(NameColor != null ? NameColor.Value : "", new Color(1f, 0.85f, 0.35f));

        /// <summary>#RRGGBB / #RRGGBBAA, or the fallback. A malformed string is the fallback AND a one-time warning -- never a silent black.</summary>
        private static Color ParseColor(string hex, Color dflt)
        {
            if (string.IsNullOrEmpty(hex)) return dflt;
            var h = hex.Trim();
            if (h.Length > 0 && h[0] != '#') h = "#" + h;
            Color c;
            if (ColorUtility.TryParseHtmlString(h, out c)) return c;
            if (Plugin.Once("badcolor:" + hex))
                Plugin.Log.LogWarning("basement subtitles: '" + hex + "' is not a colour I can read (want #RRGGBB or #RRGGBBAA). Using the preset's colour. Said once per value.");
            return dflt;
        }

        // ------------------------------------------------------------ the lines

        private enum LineKind { Dialogue, Note, Warning, Partial }

        private struct Line
        {
            public string Who;      // "" when there is no speaker
            public string Text;
            public float Until;
            public LineKind Kind;
            public Color Color;
        }

        private static readonly List<Line> Lines = new List<Line>();
        private static GUIStyle _style;
        private static int _styleSize = -1;
        private static Texture2D _box;

        public static void Note(string text, float seconds = 6f) => Add("", text, seconds, LineKind.Note, Color.white);
        public static void Warn(string text, float seconds = 8f) => Add("", text, seconds, LineKind.Warning, new Color(1f, 0.6f, 0.2f));

        /// <summary>A spoken line. Only ever called for a segment the backend marked audible.</summary>
        public static void Subtitle(string who, string text, float distanceM = -1f, string mode = "speak")
        {
            var t = text;
            if (EffDistance && distanceM >= 0f) t = t + "  (" + distanceM.ToString("0") + " m)";
            // The words are ALREADY shouted -- the backend rewrote the line
            // for a yell before it ever reached TTS -- so nothing is upper-cased
            // here. `mode` is kept for callers and for the distance suffix.
            Add(who ?? "", t, Duration(t), LineKind.Dialogue, EffTextColor);
        }

        /// <summary>The live transcript of the player's own speech while the key is held.</summary>
        public static void Partial(string text) => Add("", text, 2.5f, LineKind.Partial, new Color(0.6f, 0.9f, 0.6f));

        private static float Duration(string text)
        {
            int words = 1;
            for (int i = 0; i < text.Length; i++) if (text[i] == ' ') words++;
            float extra = Mathf.Min(6f, words * EffSecondsPerWord);
            return EffSecondsPerLine + extra;
        }

        private static void Add(string who, string text, float seconds, LineKind kind, Color c)
        {
            if (string.IsNullOrEmpty(text)) return;
            if (P == SubtitlePreset.Off && kind == LineKind.Dialogue) return;
            if (kind == LineKind.Warning && !EffWarnings) return;
            if (kind == LineKind.Partial && !EffPartials) return;
            // Hear.ShowPartial currently routes the live transcript through
            // Note() (that file belongs to another agent this session), so the
            // prefix it uses is what makes ShowPartials real today. Said here
            // rather than left as a mystery: when Hear.cs calls Partial()
            // directly, this sniff becomes dead and can go.
            if (kind == LineKind.Note && text.StartsWith("(hearing) ", StringComparison.Ordinal))
            {
                if (!EffPartials) return;
                kind = LineKind.Partial;
                c = new Color(0.6f, 0.9f, 0.6f);
            }
            lock (Lines)
            {
                // The same text again REFRESHES the existing line instead of
                // stacking a duplicate (MEASURED 2026-09-07: repeated warnings
                // piled up and overlapped into an unreadable block).
                for (int i = 0; i < Lines.Count; i++)
                    if (Lines[i].Text == text && Lines[i].Who == who)
                    { var l = Lines[i]; l.Until = Time.unscaledTime + seconds; Lines[i] = l; return; }
                Lines.Add(new Line { Who = who, Text = text, Until = Time.unscaledTime + seconds, Kind = kind, Color = c });
                int cap = Mathf.Max(EffMaxLines, 3);   // notes and warnings are not subtitles; never squeeze them to 1
                while (Lines.Count > cap) Lines.RemoveAt(0);
            }
        }

        // ------------------------------------------------------------ drawing

        public static void Draw()
        {
            int size = EffFontSize;
            if (_style == null || _styleSize != size)
            {
                _style = new GUIStyle(GUI.skin.label) { fontSize = size, fontStyle = FontStyle.Bold, wordWrap = true };
                _styleSize = size;
            }
            var pos = EffPosition;
            bool centred = pos == SubtitlePosition.TopCenter || pos == SubtitlePosition.BottomCenter;
            _style.alignment = centred ? TextAnchor.UpperCenter : TextAnchor.UpperLeft;

            float w = Screen.width * EffWidth;
            float x = centred ? (Screen.width - w) * 0.5f : 20f;

            List<Line> draw;
            lock (Lines)
            {
                Lines.RemoveAll(l => l.Until < Time.unscaledTime);
                int keep = EffMaxLines;
                draw = new List<Line>(Lines.Count);
                // The most recent `keep` DIALOGUE lines, plus every live note
                // and warning: a hard cap of 1 must not hide a link failure.
                int dialogue = 0;
                for (int i = Lines.Count - 1; i >= 0; i--)
                {
                    if (Lines[i].Kind == LineKind.Dialogue)
                    {
                        if (dialogue >= keep) continue;
                        dialogue++;
                    }
                    draw.Insert(0, Lines[i]);
                }
            }
            if (draw.Count == 0 && !(Hear.Holding && EffPartials)) return;

            // Height first, so a bottom-anchored block grows upward instead of
            // walking off the screen.
            var heights = new float[draw.Count];
            float total = 0f;
            for (int i = 0; i < draw.Count; i++)
            {
                heights[i] = _style.CalcHeight(new GUIContent(Compose(draw[i])), w);
                total += heights[i] + 4f;
            }
            float talkH = (Hear.Holding && EffPartials) ? 24f : 0f;
            float y = (pos == SubtitlePosition.BottomCenter || pos == SubtitlePosition.BottomLeft)
                ? Screen.height - 90f - total - talkH
                : 40f;

            if (EffBackground && total > 0f)
            {
                if (_box == null)
                {
                    _box = new Texture2D(1, 1);
                    _box.SetPixel(0, 0, Color.black);
                    _box.Apply();
                }
                var old = GUI.color;
                GUI.color = new Color(1f, 1f, 1f, BackgroundAlpha != null ? BackgroundAlpha.Value : 0.55f);
                GUI.DrawTexture(new Rect(x - 8f, y - 6f, w + 16f, total + 12f), _box);
                GUI.color = old;
            }

            for (int i = 0; i < draw.Count; i++)
            {
                var content = new GUIContent(Compose(draw[i]));
                var r = new Rect(x, y, w, heights[i]);
                if (EffOutline)
                {
                    var prev = _style.normal.textColor;
                    _style.normal.textColor = new Color(0f, 0f, 0f, 0.9f);
                    GUI.Label(new Rect(r.x + 1, r.y, r.width, r.height), content, _style);
                    GUI.Label(new Rect(r.x - 1, r.y, r.width, r.height), content, _style);
                    GUI.Label(new Rect(r.x, r.y + 1, r.width, r.height), content, _style);
                    GUI.Label(new Rect(r.x, r.y - 1, r.width, r.height), content, _style);
                    _style.normal.textColor = prev;
                }
                _style.normal.textColor = draw[i].Color;
                GUI.Label(r, content, _style);
                y += heights[i] + 4f;
            }

            if (Hear.Holding && EffPartials)
            {
                _style.normal.textColor = Color.green;
                GUI.Label(new Rect(x, y, w, 24), "[talking to " + (Hear.LatchedName ?? "nobody") + "]", _style);
            }
        }

        /// <summary>
        /// One drawn string. IMGUI has no per-run colour without rich text, so
        /// the speaker's name is coloured with a rich-text tag -- GUIStyle.
        /// richText is enabled for exactly that, and a name containing a
        /// bracket cannot break it because names come from the backend's
        /// people table, not from player input.
        /// </summary>
        private static string Compose(Line l)
        {
            if (l.Kind != LineKind.Dialogue || !EffNames || l.Who.Length == 0) return l.Text;
            _style.richText = true;
            var c = EffNameColor;
            return "<color=#" + ColorUtility.ToHtmlStringRGB(c) + ">" + l.Who + ":</color> " + l.Text;
        }
    }

    /// <summary>
    /// The attribute class BepInEx's ConfigurationManager reads BY REFLECTION
    /// off the field names -- it is not a shared type, so every plugin declares
    /// its own copy and that is the documented way to use it. Only the members
    /// this plugin sets are declared; ConfigurationManager ignores the rest.
    /// </summary>
#pragma warning disable 0649   // set by nothing here today; READ by ConfigurationManager
    internal sealed class ConfigurationManagerAttributes
    {
        public int? Order;
        public bool? Browsable;
        public bool? IsAdvanced;
        public string Category;
    }
#pragma warning restore 0649
}
