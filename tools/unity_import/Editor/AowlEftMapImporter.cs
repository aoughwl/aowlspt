// AowlEftMapImporter.cs
// ---------------------------------------------------------------------------
// One-click importer that loads every ripped EFT map scene into a single Unity
// scene and lays them out side-by-side under one "AowlWorld" parent.
//
// Drop this file anywhere under an "Editor" folder in a Unity project that was
// produced by AssetRipper from Escape From Tarkov (Unity 2022.3.43f2).
// A top-level "Aowlspt" menu then appears in the Editor menu bar.
//
// Menu items
//   Aowlspt/Import All EFT Maps (additive) .... open every ripped location
//                                                scene additively, no layout.
//   Aowlspt/Import + Unify World (grid) ....... THE one-click item: open every
//                                                map, group each map under
//                                                AowlWorld/<Map>, auto-position
//                                                them into a non-overlapping
//                                                grid, centered at origin.
//   Aowlspt/Re-Layout AowlWorld (grid) ........ recompute the grid for whatever
//                                                children currently sit under
//                                                AowlWorld (run after you add,
//                                                remove, or hand-drag a map).
//   Aowlspt/Clear AowlWorld ................... delete the AowlWorld root.
//   Aowlspt/EFT Map Importer Window ........... a panel with per-map buttons so
//                                                you can import ONE map at a time
//                                                (City/Streets alone is huge).
//
// IMPORTANT, honest caveats (see docs/UNITY_MAP_IMPORT.md):
//   * BSG custom shaders and C# scripts do NOT survive an AssetRipper rip.
//     Materials import with their textures on a fallback/Standard shader;
//     MonoBehaviours become stubs. You get real geometry + textures in a real
//     scene; you do NOT get the game's rendering or logic.
//   * TRUE geographic adjacency between EFT maps is not encoded in the files and
//     is deliberately NOT invented here. The grid is a tidy default; every map
//     stays a clean, separate child of AowlWorld so you can drag one next to
//     another by hand to "stitch" them, then run Re-Layout is NOT needed (it
//     would undo your drag) -- instead just move whole map containers.
// ---------------------------------------------------------------------------

#if UNITY_EDITOR
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;

public static class AowlEftMapImporter
{
    // Where AssetRipper places the location scenes. If your export used a
    // different root, change this one string.
    const string LocationsRoot = "Assets/Content/Locations";

    const string WorldRootName = "AowlWorld";

    // Gap (metres) left between the bounding boxes of adjacent maps in the grid.
    const float MapMargin = 60f;

    // ----------------------------------------------------------------- menus

    [MenuItem("Aowlspt/Import All EFT Maps (additive)", false, 0)]
    public static void ImportAllAdditive()
    {
        var maps = DiscoverMaps();
        if (!Confirm(maps, "open ADDITIVELY (no layout)")) return;

        if (!EditorSceneManager.SaveCurrentModifiedScenesIfUserWantsTo()) return;

        int done = 0, total = maps.Values.Sum(l => l.Count);
        try
        {
            foreach (var kv in maps)
                foreach (var scenePath in kv.Value)
                {
                    EditorUtility.DisplayProgressBar("Import All EFT Maps",
                        scenePath, (float)done / Math.Max(1, total));
                    OpenAdditiveOnce(scenePath);
                    done++;
                }
        }
        finally { EditorUtility.ClearProgressBar(); }

        Debug.Log($"[Aowl] Opened {done} location scenes additively. " +
                  "They sit at their baked world coordinates (many overlap near " +
                  "origin). Use 'Import + Unify World (grid)' for a tidy layout.");
    }

    [MenuItem("Aowlspt/Import + Unify World (grid)", false, 1)]
    public static void ImportAndUnify()
    {
        var maps = DiscoverMaps();
        if (!Confirm(maps, "load and UNIFY into one AowlWorld (grid layout)")) return;

        if (!EditorSceneManager.SaveCurrentModifiedScenesIfUserWantsTo()) return;

        // Fresh single empty scene as the master container.
        var master = EditorSceneManager.NewScene(NewSceneSetup.EmptyScene,
                                                 NewSceneMode.Single);
        var world = new GameObject(WorldRootName);

        int mapIdx = 0;
        try
        {
            foreach (var kv in maps)
            {
                string mapName = kv.Key;
                EditorUtility.DisplayProgressBar("Import + Unify World",
                    $"Loading {mapName} ({kv.Value.Count} scenes)",
                    (float)mapIdx / Math.Max(1, maps.Count));

                var container = new GameObject(mapName);
                container.transform.SetParent(world.transform, false);

                var opened = new List<Scene>();
                foreach (var scenePath in kv.Value)
                {
                    var sc = EditorSceneManager.OpenScene(scenePath, OpenSceneMode.Additive);
                    if (sc.IsValid()) opened.Add(sc);
                }

                // Pull every root of every sub-scene into the master scene, under
                // this map's container, PRESERVING baked world coordinates so the
                // map stays internally intact.
                foreach (var sc in opened)
                    foreach (var root in sc.GetRootGameObjects())
                    {
                        SceneManager.MoveGameObjectToScene(root, master);
                        root.transform.SetParent(container.transform, true); // worldPositionStays
                    }

                // The additive scenes are now empty; drop them.
                foreach (var sc in opened)
                    if (sc.IsValid()) EditorSceneManager.CloseScene(sc, true);

                mapIdx++;
            }

            LayoutGrid(world.transform);
        }
        finally { EditorUtility.ClearProgressBar(); }

        EditorSceneManager.MarkSceneDirty(master);
        Debug.Log($"[Aowl] Unified {maps.Count} maps under '{WorldRootName}'. " +
                  "Each map is a separate child with a clean transform -- drag " +
                  "one next to another to stitch. Save the scene (Ctrl+S) to keep it.");
    }

    [MenuItem("Aowlspt/Re-Layout AowlWorld (grid)", false, 2)]
    public static void ReLayoutExisting()
    {
        var world = GameObject.Find(WorldRootName);
        if (world == null)
        {
            EditorUtility.DisplayDialog("Aowlspt",
                $"No '{WorldRootName}' object in the active scene.", "OK");
            return;
        }
        LayoutGrid(world.transform);
        EditorSceneManager.MarkSceneDirty(world.scene);
        Debug.Log($"[Aowl] Re-laid out {world.transform.childCount} maps into a grid.");
    }

    [MenuItem("Aowlspt/Clear AowlWorld", false, 3)]
    public static void ClearWorld()
    {
        var world = GameObject.Find(WorldRootName);
        if (world == null) return;
        UnityEngine.Object.DestroyImmediate(world);
        Debug.Log("[Aowl] Removed AowlWorld.");
    }

    // ----------------------------------------------------------- discovery

    // mapName -> ordered list of scene asset paths. mapName is the folder
    // directly under LocationsRoot, so every additive sub-scene of a map
    // (geometry, AI, lights, scripts, ...) is grouped together.
    public static SortedDictionary<string, List<string>> DiscoverMaps()
    {
        var result = new SortedDictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        if (!AssetDatabase.IsValidFolder(LocationsRoot))
        {
            Debug.LogError($"[Aowl] '{LocationsRoot}' not found. Is this an " +
                           "AssetRipper export of EFT? Edit LocationsRoot at the " +
                           "top of AowlEftMapImporter.cs if your export path differs.");
            return result;
        }

        foreach (var guid in AssetDatabase.FindAssets("t:SceneAsset", new[] { LocationsRoot }))
        {
            string path = AssetDatabase.GUIDToAssetPath(guid);           // Assets/Content/Locations/<Map>/<scene>.unity
            string rel = path.Substring(LocationsRoot.Length).TrimStart('/');
            int slash = rel.IndexOf('/');
            if (slash <= 0) continue;                                     // scene directly under Locations -> skip
            string mapName = rel.Substring(0, slash);
            if (!result.TryGetValue(mapName, out var list))
                result[mapName] = list = new List<string>();
            list.Add(path);
        }
        foreach (var list in result.Values) list.Sort(StringComparer.OrdinalIgnoreCase);
        return result;
    }

    static bool Confirm(SortedDictionary<string, List<string>> maps, string what)
    {
        if (maps.Count == 0)
        {
            EditorUtility.DisplayDialog("Aowlspt",
                $"No map scenes found under '{LocationsRoot}'.\n\nRun the AssetRipper " +
                "export first (tools/unity_import/rip_maps.ps1) and open THAT project.",
                "OK");
            return false;
        }
        int scenes = maps.Values.Sum(l => l.Count);
        return EditorUtility.DisplayDialog("Aowlspt",
            $"Found {maps.Count} maps / {scenes} scenes under {LocationsRoot}.\n\n" +
            $"About to {what}.\n\n" +
            "City/Streets alone is ~200 scenes and this can take minutes and a lot " +
            "of RAM. To do one map at a time, cancel and use the Importer Window.",
            "Go", "Cancel");
    }

    static void OpenAdditiveOnce(string scenePath)
    {
        for (int i = 0; i < EditorSceneManager.sceneCount; i++)
            if (EditorSceneManager.GetSceneAt(i).path == scenePath) return; // already open
        EditorSceneManager.OpenScene(scenePath, OpenSceneMode.Additive);
    }

    // ------------------------------------------------------------- layout

    // Shelf/row bin-packing of each map's XZ footprint. Each direct child of
    // `world` is one map; we translate the child so its footprint tiles the
    // ground plane without overlap, drop its lowest point onto y=0, then shift
    // the whole world so the packed rectangle is centered on the origin.
    static void LayoutGrid(Transform world)
    {
        var children = new List<Transform>();
        for (int i = 0; i < world.childCount; i++) children.Add(world.GetChild(i));
        if (children.Count == 0) return;

        // Measure every map in world space.
        var boxes = new List<(Transform t, Bounds b, bool hasGeo)>();
        double areaSum = 0;
        foreach (var t in children)
        {
            var (b, hasGeo) = WorldBounds(t);
            boxes.Add((t, b, hasGeo));
            if (hasGeo) areaSum += (double)b.size.x * b.size.z;
        }

        // Target a roughly square overall footprint. 1.3 gives slightly wide rows.
        float targetRowWidth = (float)Math.Sqrt(Math.Max(1.0, areaSum)) * 1.3f;

        // Largest depth first packs tighter and looks tidier.
        boxes.Sort((a, b) => b.b.size.z.CompareTo(a.b.size.z));

        float cursorX = 0f, cursorZ = 0f, rowDepth = 0f;
        float placedMaxX = 0f, placedMaxZ = 0f;

        foreach (var (t, b, hasGeo) in boxes)
        {
            // Give geometry-less maps (script/AI-only folders) a small stub tile
            // so they still get a slot instead of collapsing onto origin.
            float w = hasGeo && b.size.x > 0.01f ? b.size.x : 25f;
            float d = hasGeo && b.size.z > 0.01f ? b.size.z : 25f;

            if (cursorX > 0f && cursorX + w > targetRowWidth)
            {
                cursorX = 0f;
                cursorZ += rowDepth + MapMargin;
                rowDepth = 0f;
            }

            float wantCenterX = cursorX + w * 0.5f;
            float wantCenterZ = cursorZ + d * 0.5f;

            float dx = wantCenterX - b.center.x;
            float dz = wantCenterZ - b.center.z;
            float dy = hasGeo ? -b.min.y : 0f;          // ground onto y=0
            t.position += new Vector3(dx, dy, dz);

            cursorX += w + MapMargin;
            rowDepth = Mathf.Max(rowDepth, d);
            placedMaxX = Mathf.Max(placedMaxX, wantCenterX + w * 0.5f);
            placedMaxZ = Mathf.Max(placedMaxZ, wantCenterZ + d * 0.5f);
        }

        // Center the packed rectangle (which spans 0..placedMax in layout space)
        // on the origin by shifting the world root.
        world.position += new Vector3(-placedMaxX * 0.5f, 0f, -placedMaxZ * 0.5f);

        // Falsifiable sanity check (CLAUDE.md 9b): re-measure and warn on any
        // real overlap. A layout that silently overlapped would be the bug.
        WarnOnOverlap(children);
    }

    static (Bounds bounds, bool hasGeo) WorldBounds(Transform t)
    {
        var rends = t.GetComponentsInChildren<Renderer>(true);
        if (rends.Length == 0) return (new Bounds(t.position, Vector3.zero), false);
        var b = rends[0].bounds;
        for (int i = 1; i < rends.Length; i++) b.Encapsulate(rends[i].bounds);
        return (b, true);
    }

    static void WarnOnOverlap(List<Transform> children)
    {
        var rects = new List<(string name, Rect r)>();
        foreach (var t in children)
        {
            var (b, hasGeo) = WorldBounds(t);
            if (!hasGeo) continue;
            rects.Add((t.name, new Rect(b.min.x, b.min.z, b.size.x, b.size.z)));
        }
        int overlaps = 0;
        for (int i = 0; i < rects.Count; i++)
            for (int j = i + 1; j < rects.Count; j++)
            {
                // Shrink by margin so touching-within-margin is not flagged.
                var a = Inset(rects[i].r, MapMargin * 0.5f);
                var c = Inset(rects[j].r, MapMargin * 0.5f);
                if (a.Overlaps(c))
                {
                    overlaps++;
                    Debug.LogWarning($"[Aowl] Maps overlap after layout: " +
                                     $"'{rects[i].name}' and '{rects[j].name}'. " +
                                     "Drag one apart, or increase MapMargin.");
                }
            }
        if (overlaps == 0)
            Debug.Log($"[Aowl] Layout OK: {rects.Count} maps placed, none overlap.");
    }

    static Rect Inset(Rect r, float d) => new Rect(r.x + d, r.y + d, Mathf.Max(0, r.width - 2 * d), Mathf.Max(0, r.height - 2 * d));

    // ------------------------------------------------------ importer window

    public class ImporterWindow : EditorWindow
    {
        SortedDictionary<string, List<string>> _maps;
        Vector2 _scroll;

        [MenuItem("Aowlspt/EFT Map Importer Window", false, 20)]
        public static void Open()
        {
            var w = GetWindow<ImporterWindow>("EFT Map Importer");
            w._maps = DiscoverMaps();
            w.minSize = new Vector2(360, 300);
        }

        void OnGUI()
        {
            if (_maps == null) _maps = DiscoverMaps();

            EditorGUILayout.HelpBox(
                "Import one map (all its additive sub-scenes) into the active scene " +
                "under AowlWorld/<Map>. Do a few, then 'Re-Layout AowlWorld (grid)'.",
                MessageType.Info);

            using (new EditorGUILayout.HorizontalScope())
            {
                if (GUILayout.Button("Refresh")) _maps = DiscoverMaps();
                if (GUILayout.Button("Import ALL + Unify")) ImportAndUnify();
                if (GUILayout.Button("Re-Layout")) ReLayoutExisting();
            }

            _scroll = EditorGUILayout.BeginScrollView(_scroll);
            foreach (var kv in _maps)
            {
                using (new EditorGUILayout.HorizontalScope())
                {
                    EditorGUILayout.LabelField($"{kv.Key}  ({kv.Value.Count})");
                    if (GUILayout.Button("Import", GUILayout.Width(80)))
                        ImportSingle(kv.Key, kv.Value);
                }
            }
            EditorGUILayout.EndScrollView();
        }

        static void ImportSingle(string mapName, List<string> scenePaths)
        {
            var world = GameObject.Find(WorldRootName);
            if (world == null) world = new GameObject(WorldRootName);
            var master = SceneManager.GetActiveScene();

            var container = GameObject.Find($"{WorldRootName}/{mapName}");
            if (container == null)
            {
                container = new GameObject(mapName);
                container.transform.SetParent(world.transform, false);
            }

            var opened = new List<Scene>();
            try
            {
                for (int i = 0; i < scenePaths.Count; i++)
                {
                    EditorUtility.DisplayProgressBar($"Import {mapName}",
                        scenePaths[i], (float)i / scenePaths.Count);
                    var sc = EditorSceneManager.OpenScene(scenePaths[i], OpenSceneMode.Additive);
                    if (sc.IsValid()) opened.Add(sc);
                }
                foreach (var sc in opened)
                    foreach (var root in sc.GetRootGameObjects())
                    {
                        SceneManager.MoveGameObjectToScene(root, master);
                        root.transform.SetParent(container.transform, true);
                    }
                foreach (var sc in opened)
                    if (sc.IsValid()) EditorSceneManager.CloseScene(sc, true);
            }
            finally { EditorUtility.ClearProgressBar(); }

            EditorSceneManager.MarkSceneDirty(master);
            Debug.Log($"[Aowl] Imported map '{mapName}' ({scenePaths.Count} scenes). " +
                      "Run 'Re-Layout AowlWorld (grid)' when you have added the maps you want.");
        }
    }
}
#endif
