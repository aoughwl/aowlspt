// A small, dependency-free JSON document model.
//
// Why not System.Text.Json or Newtonsoft: config lookup and patch-merge
// semantics are part of the ABI, not an implementation detail. A mod that reads
// `weapons.recoil` or writes a `dbPatch` must get the same answer in the
// simulator as it does from the nimony backend and client host, so the code that
// decides those semantics is written out explicitly and kept small enough to
// compare against the other implementations line by line. (It originally also
// had to compile for Unity's Mono, where neither library was reliably present —
// that host is gone, the reason above is not.)
//
// Scope is deliberately small: parse, serialize, get-by-path, set-by-path, and
// a recursive merge. It is not a general-purpose JSON library and does not try
// to be one.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace Aowlspt.Abi;

public enum JsonKind { Null, Bool, Number, String, Array, Object }

public sealed class JsonValue
{
    public JsonKind Kind { get; private set; }

    private bool _bool;
    private double _number;
    private string _string = string.Empty;
    private List<JsonValue>? _array;
    private Dictionary<string, JsonValue>? _object;

    public static JsonValue Null() => new() { Kind = JsonKind.Null };
    public static JsonValue Bool(bool v) => new() { Kind = JsonKind.Bool, _bool = v };
    public static JsonValue Number(double v) => new() { Kind = JsonKind.Number, _number = v };
    public static JsonValue String(string v) => new() { Kind = JsonKind.String, _string = v ?? "" };
    public static JsonValue Array() => new() { Kind = JsonKind.Array, _array = new List<JsonValue>() };
    public static JsonValue Object() => new() { Kind = JsonKind.Object, _object = new Dictionary<string, JsonValue>(StringComparer.Ordinal) };

    public bool AsBool => Kind == JsonKind.Bool && _bool;
    public double AsNumber => Kind == JsonKind.Number ? _number : 0;
    public string AsString => Kind == JsonKind.String ? _string : string.Empty;
    public IReadOnlyList<JsonValue> Items => (IReadOnlyList<JsonValue>?)_array ?? System.Array.Empty<JsonValue>();
    public IReadOnlyDictionary<string, JsonValue> Fields =>
        (IReadOnlyDictionary<string, JsonValue>?)_object ?? new Dictionary<string, JsonValue>();

    public void Add(JsonValue v) => (_array ??= new List<JsonValue>()).Add(v);
    public void Set(string key, JsonValue v) => (_object ??= new Dictionary<string, JsonValue>(StringComparer.Ordinal))[key] = v;
    public bool TryGet(string key, out JsonValue value)
    {
        value = Null();
        return _object is not null && _object.TryGetValue(key, out value!);
    }

    // -------------------------------------------------------------- paths

    /// <summary>
    /// Look up a dotted path. Array elements are addressed numerically:
    /// "templates.items.0.name". Returns null when any segment is missing,
    /// which the caller reports as AOWLSPT_ERR_NOT_FOUND.
    /// </summary>
    public JsonValue? GetPath(string path)
    {
        if (string.IsNullOrEmpty(path)) return this;
        var node = this;
        foreach (var seg in path.Split('.'))
        {
            if (seg.Length == 0) continue;
            if (node.Kind == JsonKind.Object)
            {
                if (node._object is null || !node._object.TryGetValue(seg, out var next)) return null;
                node = next;
            }
            else if (node.Kind == JsonKind.Array)
            {
                if (!int.TryParse(seg, NumberStyles.Integer, CultureInfo.InvariantCulture, out var i)) return null;
                if (node._array is null || i < 0 || i >= node._array.Count) return null;
                node = node._array[i];
            }
            else return null;
        }
        return node;
    }

    /// <summary>
    /// Write <paramref name="value"/> at a dotted path, creating intermediate
    /// objects as needed. An existing non-object on the way is replaced — a
    /// config that used to hold a scalar where a section now belongs should not
    /// make the write fail.
    /// </summary>
    public void SetPath(string path, JsonValue value)
    {
        if (string.IsNullOrEmpty(path)) throw new ArgumentException("empty path", nameof(path));
        var segs = path.Split('.');
        var node = this;
        for (var i = 0; i < segs.Length - 1; i++)
        {
            var seg = segs[i];
            if (node.Kind != JsonKind.Object)
            {
                node.Kind = JsonKind.Object;
                node._object = new Dictionary<string, JsonValue>(StringComparer.Ordinal);
            }
            node._object ??= new Dictionary<string, JsonValue>(StringComparer.Ordinal);
            if (!node._object.TryGetValue(seg, out var next) || next.Kind != JsonKind.Object)
            {
                next = Object();
                node._object[seg] = next;
            }
            node = next;
        }
        if (node.Kind != JsonKind.Object)
        {
            node.Kind = JsonKind.Object;
            node._object = new Dictionary<string, JsonValue>(StringComparer.Ordinal);
        }
        node._object ??= new Dictionary<string, JsonValue>(StringComparer.Ordinal);
        node._object[segs[segs.Length - 1]] = value;
    }

    /// <summary>
    /// Recursively merge <paramref name="patch"/> into this value. Objects merge
    /// field by field; everything else replaces. This is what makes db_patch
    /// safe for two mods editing sibling fields of the same item — a whole-object
    /// write would have one silently undo the other.
    /// </summary>
    public void Merge(JsonValue patch)
    {
        if (patch.Kind != JsonKind.Object || Kind != JsonKind.Object)
        {
            Kind = patch.Kind;
            _bool = patch._bool;
            _number = patch._number;
            _string = patch._string;
            _array = patch._array;
            _object = patch._object;
            return;
        }
        _object ??= new Dictionary<string, JsonValue>(StringComparer.Ordinal);
        foreach (var kv in patch.Fields)
        {
            if (_object.TryGetValue(kv.Key, out var mine) &&
                mine.Kind == JsonKind.Object && kv.Value.Kind == JsonKind.Object)
                mine.Merge(kv.Value);
            else
                _object[kv.Key] = kv.Value;
        }
    }

    // --------------------------------------------------------- serialize

    public override string ToString() => Write(this, false, 0);

    public string ToString(bool indented) => Write(this, indented, 0);

    private static string Write(JsonValue v, bool indented, int depth)
    {
        var sb = new StringBuilder();
        WriteTo(sb, v, indented, depth);
        return sb.ToString();
    }

    private static void WriteTo(StringBuilder sb, JsonValue v, bool indented, int depth)
    {
        switch (v.Kind)
        {
            case JsonKind.Null: sb.Append("null"); break;
            case JsonKind.Bool: sb.Append(v._bool ? "true" : "false"); break;
            case JsonKind.Number: sb.Append(FormatNumber(v._number)); break;
            case JsonKind.String: WriteString(sb, v._string); break;

            case JsonKind.Array:
                sb.Append('[');
                for (var i = 0; i < (v._array?.Count ?? 0); i++)
                {
                    if (i > 0) sb.Append(',');
                    if (indented) { sb.Append('\n'); sb.Append(' ', (depth + 1) * 2); }
                    WriteTo(sb, v._array![i], indented, depth + 1);
                }
                if (indented && (v._array?.Count ?? 0) > 0) { sb.Append('\n'); sb.Append(' ', depth * 2); }
                sb.Append(']');
                break;

            case JsonKind.Object:
                sb.Append('{');
                var first = true;
                foreach (var kv in v._object ?? new Dictionary<string, JsonValue>())
                {
                    if (!first) sb.Append(',');
                    first = false;
                    if (indented) { sb.Append('\n'); sb.Append(' ', (depth + 1) * 2); }
                    WriteString(sb, kv.Key);
                    sb.Append(':');
                    if (indented) sb.Append(' ');
                    WriteTo(sb, kv.Value, indented, depth + 1);
                }
                if (indented && !first) { sb.Append('\n'); sb.Append(' ', depth * 2); }
                sb.Append('}');
                break;
        }
    }

    private static string FormatNumber(double d)
    {
        // Integral values print without a trailing ".0" so round-tripping an id
        // or a count does not quietly turn it into a float in the output.
        if (Math.Abs(d % 1) < double.Epsilon && Math.Abs(d) < 1e15)
            return ((long)d).ToString(CultureInfo.InvariantCulture);
        return d.ToString("R", CultureInfo.InvariantCulture);
    }

    private static void WriteString(StringBuilder sb, string s)
    {
        sb.Append('"');
        foreach (var c in s)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                case '\b': sb.Append("\\b"); break;
                case '\f': sb.Append("\\f"); break;
                default:
                    if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    else sb.Append(c);
                    break;
            }
        }
        sb.Append('"');
    }

    // ------------------------------------------------------------- parse

    public static JsonValue Parse(string text)
    {
        var p = new Parser(text);
        var v = p.ParseValue();
        p.SkipWhitespace();
        if (!p.AtEnd) throw new FormatException($"trailing content at offset {p.Position}");
        return v;
    }

    public static bool TryParse(string text, out JsonValue value)
    {
        try { value = Parse(text); return true; }
        catch (FormatException) { value = Null(); return false; }
        catch (ArgumentException) { value = Null(); return false; }
    }

    private struct Parser
    {
        private readonly string _s;
        private int _i;

        public Parser(string s) { _s = s ?? ""; _i = 0; }

        public int Position => _i;
        public bool AtEnd => _i >= _s.Length;

        public void SkipWhitespace()
        {
            while (_i < _s.Length && (_s[_i] == ' ' || _s[_i] == '\t' || _s[_i] == '\n' || _s[_i] == '\r'))
                _i++;
        }

        public JsonValue ParseValue()
        {
            SkipWhitespace();
            if (AtEnd) throw new FormatException("unexpected end of input");
            switch (_s[_i])
            {
                case '{': return ParseObject();
                case '[': return ParseArray();
                case '"': return String(ParseString());
                case 't': Expect("true"); return Bool(true);
                case 'f': Expect("false"); return Bool(false);
                case 'n': Expect("null"); return Null();
                default: return Number(ParseNumber());
            }
        }

        private JsonValue ParseObject()
        {
            var o = Object();
            _i++; // '{'
            SkipWhitespace();
            if (!AtEnd && _s[_i] == '}') { _i++; return o; }
            while (true)
            {
                SkipWhitespace();
                if (AtEnd || _s[_i] != '"') throw new FormatException($"expected key at offset {_i}");
                var key = ParseString();
                SkipWhitespace();
                if (AtEnd || _s[_i] != ':') throw new FormatException($"expected ':' at offset {_i}");
                _i++;
                o.Set(key, ParseValue());
                SkipWhitespace();
                if (AtEnd) throw new FormatException("unterminated object");
                if (_s[_i] == ',') { _i++; continue; }
                if (_s[_i] == '}') { _i++; return o; }
                throw new FormatException($"expected ',' or '}}' at offset {_i}");
            }
        }

        private JsonValue ParseArray()
        {
            var a = Array();
            _i++; // '['
            SkipWhitespace();
            if (!AtEnd && _s[_i] == ']') { _i++; return a; }
            while (true)
            {
                a.Add(ParseValue());
                SkipWhitespace();
                if (AtEnd) throw new FormatException("unterminated array");
                if (_s[_i] == ',') { _i++; continue; }
                if (_s[_i] == ']') { _i++; return a; }
                throw new FormatException($"expected ',' or ']' at offset {_i}");
            }
        }

        private string ParseString()
        {
            _i++; // opening quote
            var sb = new StringBuilder();
            while (true)
            {
                if (AtEnd) throw new FormatException("unterminated string");
                var c = _s[_i++];
                if (c == '"') return sb.ToString();
                if (c != '\\') { sb.Append(c); continue; }
                if (AtEnd) throw new FormatException("unterminated escape");
                var e = _s[_i++];
                switch (e)
                {
                    case '"': sb.Append('"'); break;
                    case '\\': sb.Append('\\'); break;
                    case '/': sb.Append('/'); break;
                    case 'b': sb.Append('\b'); break;
                    case 'f': sb.Append('\f'); break;
                    case 'n': sb.Append('\n'); break;
                    case 'r': sb.Append('\r'); break;
                    case 't': sb.Append('\t'); break;
                    case 'u':
                        if (_i + 4 > _s.Length) throw new FormatException("truncated \\u escape");
                        sb.Append((char)ushort.Parse(_s.Substring(_i, 4), NumberStyles.HexNumber, CultureInfo.InvariantCulture));
                        _i += 4;
                        break;
                    default: throw new FormatException($"bad escape '\\{e}' at offset {_i - 1}");
                }
            }
        }

        private double ParseNumber()
        {
            var start = _i;
            if (!AtEnd && (_s[_i] == '-' || _s[_i] == '+')) _i++;
            while (!AtEnd && (char.IsDigit(_s[_i]) || _s[_i] == '.' || _s[_i] == 'e' || _s[_i] == 'E' ||
                              _s[_i] == '+' || _s[_i] == '-'))
                _i++;
            var text = _s.Substring(start, _i - start);
            if (!double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var d))
                throw new FormatException($"bad number '{text}' at offset {start}");
            return d;
        }

        private void Expect(string literal)
        {
            if (_i + literal.Length > _s.Length ||
                string.CompareOrdinal(_s, _i, literal, 0, literal.Length) != 0)
                throw new FormatException($"expected '{literal}' at offset {_i}");
            _i += literal.Length;
        }
    }
}
