using Mono.Cecil;
// usage: membercheck <dll> type [TypeName]        -> list members of a type (substring match on FullName if not exact)
//        membercheck <dll> grep <substr>          -> types whose FullName contains substr
//        membercheck <dll> member <Type> <Member> -> PRESENT/MISSING with signature
var dll = args[0]; var verb = args[1];
var res = new DefaultAssemblyResolver(); res.AddSearchDirectory(Path.GetDirectoryName(dll));
var asm = AssemblyDefinition.ReadAssembly(dll, new ReaderParameters { AssemblyResolver = res });
IEnumerable<TypeDefinition> all() { foreach (var m in asm.Modules) foreach (var t in m.Types) { yield return t; foreach (var n in Nested(t)) yield return n; } }
IEnumerable<TypeDefinition> Nested(TypeDefinition t) { foreach (var n in t.NestedTypes) { yield return n; foreach (var x in Nested(n)) yield return x; } }
TypeDefinition find(string name) => all().FirstOrDefault(t => t.FullName == name) ?? all().FirstOrDefault(t => t.Name == name);
string sig(MethodDefinition m) => $"{(m.IsStatic ? "static " : "")}{m.ReturnType.Name} {m.Name}({string.Join(", ", m.Parameters.Select(p => p.ParameterType.Name + " " + p.Name))})";
if (verb == "grep") { foreach (var t in all()) if (t.FullName.Contains(args[2], StringComparison.OrdinalIgnoreCase)) Console.WriteLine(t.FullName + (t.BaseType != null ? " : " + t.BaseType.Name : "")); }
else if (verb == "type") { var t = find(args[2]); if (t == null) { Console.WriteLine("TYPE MISSING " + args[2]); return 1; }
  Console.WriteLine($"TYPE {t.FullName} : {t.BaseType?.FullName}");
  var filt = args.Length > 3 ? args[3] : null;
  foreach (var f in t.Fields) if (filt == null || f.Name.Contains(filt, StringComparison.OrdinalIgnoreCase)) Console.WriteLine($"  F {(f.IsStatic?"static ":"")}{f.FieldType.Name} {f.Name}");
  foreach (var p in t.Properties) if (filt == null || p.Name.Contains(filt, StringComparison.OrdinalIgnoreCase)) Console.WriteLine($"  P {p.PropertyType.Name} {p.Name} {{{(p.GetMethod!=null?"get;":"")}{(p.SetMethod!=null?"set;":"")}}}");
  foreach (var e in t.Events) if (filt == null || e.Name.Contains(filt, StringComparison.OrdinalIgnoreCase)) Console.WriteLine($"  E {e.EventType.Name} {e.Name}");
  foreach (var m in t.Methods) if (filt == null || m.Name.Contains(filt, StringComparison.OrdinalIgnoreCase)) Console.WriteLine($"  M {sig(m)}"); }
else if (verb == "member") { var t = find(args[2]); if (t == null) { Console.WriteLine("TYPE MISSING " + args[2]); return 1; }
  var n = args[3]; var hits = new List<string>();
  foreach (var f in t.Fields) if (f.Name == n) hits.Add("F " + f.FieldType.FullName + " " + f.Name);
  foreach (var p in t.Properties) if (p.Name == n) hits.Add("P " + p.PropertyType.FullName + " " + p.Name);
  foreach (var e in t.Events) if (e.Name == n) hits.Add("E " + e.EventType.FullName + " " + e.Name);
  foreach (var m in t.Methods) if (m.Name == n) hits.Add("M " + sig(m));
  // walk base types too
  var b = t.BaseType; while (b != null && hits.Count == 0) { TypeDefinition bd = null; try { bd = b.Resolve(); } catch {} if (bd == null) break;
    foreach (var f in bd.Fields) if (f.Name == n) hits.Add("F(base " + bd.Name + ") " + f.FieldType.FullName + " " + f.Name);
    foreach (var p in bd.Properties) if (p.Name == n) hits.Add("P(base " + bd.Name + ") " + p.PropertyType.FullName + " " + p.Name);
    foreach (var m in bd.Methods) if (m.Name == n) hits.Add("M(base " + bd.Name + ") " + sig(m));
    b = bd.BaseType; }
  if (hits.Count == 0) { Console.WriteLine($"MISSING {t.FullName}.{n}"); return 1; }
  foreach (var h in hits) Console.WriteLine($"PRESENT {t.FullName}.{n}: {h}"); }
else if (verb == "callers") { var target = args[2]; // substring of the callee's full name
  foreach (var t in all()) foreach (var m in t.Methods) { if (!m.HasBody) continue;
    foreach (var ins in m.Body.Instructions) { if (ins.Operand is MethodReference mr && mr.FullName.Contains(target)) { Console.WriteLine($"{t.FullName}::{sig(m)}  ->  {mr.FullName}"); break; } } } }
else if (verb == "enum") { var t = find(args[2]); if (t == null) { Console.WriteLine("TYPE MISSING " + args[2]); return 1; }
  foreach (var f in t.Fields) if (f.HasConstant) Console.WriteLine($"  {f.Name} = {f.Constant}"); }
else if (verb == "calls") { var want = args[2]; // "Type::Method" substring
  foreach (var t in all()) foreach (var m in t.Methods) { if (!m.HasBody) continue; if (!($"{t.FullName}::{m.Name}").Contains(want)) continue;
    Console.WriteLine($"BODY {t.FullName}::{sig(m)}");
    foreach (var ins in m.Body.Instructions) { if (ins.Operand is MethodReference mr) Console.WriteLine("   call " + mr.FullName); else if (ins.Operand is FieldReference fr) Console.WriteLine("   fld  " + fr.FullName); } } }
return 0;
