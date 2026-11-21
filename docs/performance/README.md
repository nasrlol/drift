# Performance

Everything we know about where drift spends its time, and what to do about it.

- **Tracking issue:** #115, with every item as a checklist.
- **Full report:** [audit-2026-11-21.md](audit-2026-11-21.md): method, baseline, costs, memory, plan.
- **Raw numbers:** [data/](data/), as CSV and text.
- **All issues:** [label `performance`](https://github.com/nasrlol/drift/issues?q=is%3Aissue+label%3Aperformance).

## The short version

At rest the game holds 60 fps. It lags because of debug-build tree drawing in the street view, route planning in the
frame loop, expensive route lines, the integrated GPU being the default, and other cars without culling.

| | Measured | Budget |
|---|--:|--:|
| Frame at rest, 780M / RTX 4060 | 5.2-5.7 / 1.4-1.6 ms | - |
| Street view p50, profile / debug | 4.1 / 17.9 ms | 16.6 ms |
| Planning routes, worst frame | 44 ms | 16.6 ms |
| `ship_step` | 13 us | 1 us |
| First frame | 623 ms | 100 ms |

## How to pick up an item

1. Pull main and pick an open issue below. Check its "Depends on" line.
2. Claim it in `todo.txt`, branch as `yourname/short-topic`, one issue per pull request.
3. Measure before and after in the profile build and put both in the pull request.
4. Not faster? Revert it and say so in the issue.
5. Expected test output must stay byte identical.

## Open questions (answers come from nasr)

- #86 may route planning run on a worker thread with a start / poll API?
- #87 does the 100 ms startup budget include creating the window?
- #88 is dev-2026-11-nightly:9a69916 the pinned Odin dev-2026-11a?
- #89 should the game ask Windows for the discrete GPU by default?
- #90 should the game turn vsync on instead of the fixed 60 fps cap?
- #91 do we keep the unused live partner code (trip_start and its chain)?

## Work items

**Bugs**

- #92 bug: heap corruption (0xC0000374) on exit after opening the street view (M, Lars (trees.odin))

**Phase 0: measure**

- #93 perf: add spall zones per system behind DRIFT_PROFILE (S, Dario)

**Phase 1: quick wins**

- #94 perf: use the discrete GPU on hybrid laptops (S, Dario)
- #95 perf: road_try_land scans every road point (ship_step 13x over budget) (S, Lars)
- #96 perf: draw_path_strip is the largest CPU cost on the plan and nav screens (M, Lars)
- #97 perf: draw the A* scan animation as one mesh (S, nasr)
- #98 perf: cache the ground layer colors and unchanged shader uniforms (S, Andrei, nasr)
- #99 perf: present frames in step with the display (S, nasr)

**Phase 2: spikes and algorithms**

- #100 perf: run route planning outside the frame (L, Lars)
- #101 perf: trees_draw rebuilds all tree matrices twice per frame (M, Lars)
- #102 perf: other cars need culling, LOD and instancing (M, Dario, Andrei)
- #103 perf: street camera runs up to 30 collision queries per frame (M, Lars)
- #104 perf: reroutes grow plan_mem until the next plan (S, Lars)
- #105 perf: cut startup work (M, nasr, Dario)
- #106 perf: network threads need a total deadline and a DNS timeout (M, Andrei)
- #107 perf: stop recomputing static plan and map UI every frame (M, Andrei, Lars, nasr)
- #108 perf: move file writes and signing off the frame thread (M, Andrei, Dario)
- #109 perf: rasterize fonts before the first use (S, nasr)

**Phase 3: deeper work**

- #110 perf: map lines with 3 detail levels and 10 km cells (L, nasr)
- #111 perf: build tile meshes on a worker thread (L, Lars, nasr)
- #112 perf: synthesize music on its own thread (M, Andrei)
- #113 perf: add a quality setting for MSAA and shadows (M, Lars, nasr)
- #114 chore: remove dead code found in the performance audit (S, file owners)
