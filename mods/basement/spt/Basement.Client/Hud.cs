using System.Collections.Generic;
using UnityEngine;

namespace Basement.Client
{
    /// <summary>
    /// Transient lines on screen: say subtitles, hud.note, heard.* and the
    /// link state. IMGUI, because it works in every scene and needs no prefab.
    /// Never the source of truth for anything.
    /// </summary>
    internal static class Hud
    {
        private struct Line { public string Text; public float Until; public Color Color; }
        private static readonly List<Line> Lines = new List<Line>();
        private static GUIStyle _style;

        public static void Note(string text, float seconds = 6f) => Add(text, seconds, Color.white);
        public static void Warn(string text, float seconds = 8f) => Add(text, seconds, new Color(1f, 0.6f, 0.2f));
        public static void Subtitle(string who, string text, float seconds = 6f) => Add(who + ": " + text, seconds, Color.yellow);

        private static void Add(string text, float seconds, Color c)
        {
            lock (Lines)
            {
                Lines.Add(new Line { Text = text, Until = Time.unscaledTime + seconds, Color = c });
                while (Lines.Count > 6) Lines.RemoveAt(0);
            }
        }

        public static void Draw()
        {
            if (_style == null)
                _style = new GUIStyle(GUI.skin.label) { fontSize = 15, fontStyle = FontStyle.Bold, wordWrap = true };
            float y = 40f;
            lock (Lines)
            {
                Lines.RemoveAll(l => l.Until < Time.unscaledTime);
                foreach (var l in Lines)
                {
                    _style.normal.textColor = l.Color;
                    GUI.Label(new Rect(20, y, Screen.width * 0.5f, 48), l.Text, _style);
                    y += 24f;
                }
            }
            if (Hear.Holding)
            {
                _style.normal.textColor = Color.green;
                GUI.Label(new Rect(20, y, 400, 24), "[talking to " + (Hear.LatchedName ?? "nobody") + "]", _style);
            }
        }
    }
}
