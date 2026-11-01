using System;
using System.Collections;
using System.Collections.Generic;
using BepInEx;
using BepInEx.Configuration;
using BepInEx.Logging;
using EFT.InventoryLogic;
using HarmonyLib;

namespace BottomUpSort
{
    // Postfixes Advanced Stash Sorting's layout planner: after it has packed items
    // against the top of the stash, mirror every placement vertically so the same
    // layout sits against the bottom instead (first category lowest, growing upward).
    [BepInPlugin(Guid, "Bottom-Up Stash Sort", "1.0.0")]
    [BepInDependency("com.slpf.advstashsorting", BepInDependency.DependencyFlags.HardDependency)]
    public class Plugin : BaseUnityPlugin
    {
        public const string Guid = "com.thatheathenjay.bottomupsort";
        internal static ConfigEntry<bool> Enabled;
        internal static ManualLogSource Log;

        private void Awake()
        {
            Log = Logger;
            Enabled = Config.Bind("General", "Fill from bottom", true,
                "Stash sort packs items against the bottom of the stash, first category at the bottom, growing upward. Off = normal top-down sort.");

            var planner = AccessTools.TypeByName("AdvancedStashSorting.Sorting.OrderedStashLayoutPlanner");
            var target = planner == null ? null : AccessTools.Method(planner, "Search");
            if (target == null)
            {
                Log.LogError("Could not find AdvancedStashSorting's OrderedStashLayoutPlanner.Search; bottom-up sort disabled.");
                return;
            }
            new Harmony(Guid).Patch(target, postfix: new HarmonyMethod(typeof(Plugin), nameof(Postfix)));
            Log.LogInfo("Hooked Advanced Stash Sorting layout planner.");
        }

        private static void Postfix(object __result, Grid grid)
        {
            try
            {
                if (!Enabled.Value || __result == null || grid == null) return;
                var result = Traverse.Create(__result);
                if (result.Property("Status").GetValue()?.ToString() != "Success") return;
                var plan = result.Property("Plan").GetValue();
                if (plan == null) return;
                if (!(Traverse.Create(plan).Property("Placements").GetValue() is IList placements) || placements.Count == 0) return;

                int w = grid.GridWidth, h = grid.GridHeight;
                var planned = new List<Item>(placements.Count);
                var locs = new List<LocationInGrid>(placements.Count);
                foreach (var p in placements)
                {
                    var t = Traverse.Create(p);
                    planned.Add(t.Property("Item").GetValue<Item>());
                    locs.Add(t.Property("Location").GetValue<LocationInGrid>());
                }

                // Cells held by items the planner did not move (pinned / locked). A mirrored
                // layout must not land on them; if it would, keep the planner's own layout.
                var occupied = new bool[w * h];
                var plannedSet = new HashSet<Item>(planned);
                foreach (KeyValuePair<Item, LocationInGrid> kv in grid.ItemCollection)
                {
                    if (plannedSet.Contains(kv.Key)) continue;
                    Mark(occupied, w, h, kv.Key, kv.Value);
                }

                var mirrored = new int[locs.Count];
                for (int i = 0; i < locs.Count; i++)
                {
                    var size = planned[i].CalculateRotatedSize(locs[i].r);
                    int ny = h - locs[i].y - size.Y;
                    if (ny < 0 || Overlaps(occupied, w, h, locs[i].x, ny, size.X, size.Y))
                    {
                        Log.LogDebug("Bottom-up layout would collide with a pinned item; using normal layout this time.");
                        return;
                    }
                    mirrored[i] = ny;
                }
                for (int i = 0; i < locs.Count; i++) locs[i].y = mirrored[i];
            }
            catch (Exception e)
            {
                Log.LogWarning($"Bottom-up sort skipped: {e.GetType().Name}: {e.Message}");
            }
        }

        private static void Mark(bool[] occ, int w, int h, Item item, LocationInGrid loc)
        {
            var size = item.CalculateRotatedSize(loc.r);
            for (int y = loc.y; y < Math.Min(h, loc.y + size.Y); y++)
                for (int x = loc.x; x < Math.Min(w, loc.x + size.X); x++)
                    if (x >= 0 && y >= 0) occ[y * w + x] = true;
        }

        private static bool Overlaps(bool[] occ, int w, int h, int x0, int y0, int sw, int sh)
        {
            if (x0 < 0 || y0 < 0 || x0 + sw > w || y0 + sh > h) return true;
            for (int y = y0; y < y0 + sh; y++)
                for (int x = x0; x < x0 + sw; x++)
                    if (occ[y * w + x]) return true;
            return false;
        }
    }
}
