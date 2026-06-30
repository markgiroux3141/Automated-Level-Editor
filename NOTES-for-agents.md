# Notes for agents & maintainers — hard-won lessons

Engineering gotchas discovered while building this editor. Read before
modifying `main.gd`, `tools/verify.gd`, or the generators — several of these
cost hours and are non-obvious. Symptoms → cause → fix.

---

## Godot project / process

**"Couldn't detect whether to run the editor, the project manager or a
specific project. Aborting."** — appears as a *windowed popup*, not a console
crash, and the process hangs until dismissed. Cause: no main scene. An autoload
alone does NOT make a project runnable. Fix: `project.godot` sets
`run/main_scene="res://main.tscn"`, and `main.tscn` is a 1-node scene whose
script is `main.gd`.

**Grey/blank live window even though `renders/*.png` look fine.** Cause: all
capture cameras live in off-screen `SubViewport`s, so the main window viewport
had no `current` Camera3D. Fix: `main._build_viewports` adds a `LiveCamera`
(`current = true`) under `world_root` purely so a human can watch.

**Running unattended without stealing the foreground: use `--minimized`, which
moves the window OFF-SCREEN (`-4000,-4000`) in normal mode.** Do NOT use
`Window.MODE_MINIMIZED` — minimizing throttles the render/physics loop, so
`await frame_post_draw` / `physics_frame` never resume and the command loop
hangs forever (looks like the process is alive but never writes results).
`--headless` is also out: the dummy renderer produces blank screenshots. A real
GPU window (even off-screen) is required.

**Benign shutdown noise:** `ERROR: BUG: Unreferenced static string to 0: ...`
and `ShaderCompilation` on quit are Godot 4.7 engine internals, not our bug.
Filter them out when grepping logs (`grep -v "Unreferenced static string"`).

---

## GDScript

**`:= ` type-inference parse error: "Cannot infer the type of X".** Happens
whenever the right-hand side is a call on an untyped var. The tool modules hold
`var ed` (the main Node, untyped), so every `ed.foo()` returns Variant. Fix: use
an explicit annotation (`var n: Node3D = ed.foo()`) or plain `var n = ...`.
This will bite again any time you add a tool method that assigns from `ed.*`.

---

## Physics queries

`PhysicsDirectSpaceState3D.intersect_ray` only sees bodies present in **prior**
frames. A body spawned (or rotated) in the *same* batch may not be hittable
until the next physics tick. Dropping onto the long-lived ground plane works
regardless; same-batch object-to-object probes can miss. The navmesh bake works
around this by awaiting a physics frame before parsing (below).

---

## Runtime navigation mesh — THE hard one

This ate the most time. `NavigationRegion3D.bake_navigation_mesh()` is
**unreliable for re-baking at runtime**. Observed failure modes, all with the
*same* geometry:

- Re-baking the same `NavigationMesh` resource in place → the map keeps serving
  the **previous** navmesh (e.g. a `check_reachable` after cutting a doorway
  still reports the sealed-room result; the path ends at the old wall).
- Assigning a *fresh* empty resource then baking into it → the map goes
  **empty** (`path_points: 0`, no path at all).
- Freeing + recreating the region node in one frame → registers **empty**.
- Polygon counts came out **non-deterministic** with
  `PARSED_GEOMETRY_MESH_INSTANCES` (it reads geometry back from the GPU at
  runtime — Godot itself warns against this).

**What actually works** (see `main._do_bake`, a coroutine):

1. Keep ONE **persistent** `NavigationRegion3D`, created at startup and left
   registered with the map for the whole session.
2. Set the navigation map's `cell_size`/`cell_height` to MATCH the navmesh's
   (`NavigationServer3D.map_set_cell_size`) — mismatch silently prevents the
   region from merging into the map.
3. `await get_tree().physics_frame` BEFORE parsing, so freshly-set collider
   transforms (e.g. a corridor's rotated pieces) are committed.
4. Bake **procedurally** into a fresh navmesh, then assign the already-FILLED
   mesh to the region in one step:
   ```gdscript
   var nm := make_navmesh()                                  # STATIC_COLLIDERS, CPU-deterministic
   var src := NavigationMeshSourceGeometryData3D.new()
   NavigationServer3D.parse_source_geometry_data(nm, src, world_root)
   NavigationServer3D.bake_from_source_geometry_data(nm, src)
   nav_region.navigation_mesh = nm                           # never transitions through empty
   ```
5. `await` a few physics frames, then
   `NavigationServer3D.map_force_update(map)` before any `check_reachable`.

Use `PARSED_GEOMETRY_STATIC_COLLIDERS` (CPU-side, deterministic), not
`MESH_INSTANCES`.

---

## Generators & geometry

**Floor seams and navmesh continuity.** Abutting coplanar floor slabs (sharing
an edge, no gap) merge fine in the bake. **Overlapping** coplanar floors create
degenerate double-surfaces that *split* the navmesh at the seam — so
`make_corridor` floors ABUT the room floors, they don't overlap. If you change
this, re-verify reachability across every doorway, not just within rooms.

**`make_corridor` walls are inset** by the wall thickness at each end so they
don't clip the door jambs (`check_overlaps` will flag the corner penetration
otherwise).

**`make_opening` deletes the original wall** and returns new left/right/lintel
segment ids. The lintel legitimately floats above the doorway — `check_support`
treats an object as supported if it touches adjacent geometry (the jambs), not
only if something is directly below it. Keep that rule if you touch the support
check, or lintels become false-positive floaters.

**`check_overlaps` ignores floor-vs-floor pairs** (overlap there is benign /
sometimes intentional). Don't "fix" it to flag them.

---

## Command loop & I/O

- Detect new commands by reading from a byte cursor and only processing lines
  terminated by `\n` — tolerate a half-written final line (partial append).
- Writes are atomic (`*.tmp` then rename) for `state.json`, `results.jsonl`,
  and every PNG, so the agent never reads a torn file.
- `last_seq` is persisted (`io/last_seq.txt`); a restart re-reads the whole
  command file but the seq guard prevents re-executing old lines.
- Exactly one `batch_done` sentinel per batch — match it to your highest sent
  `seq` before reading results.
- A malformed line gets `ok:false` + an error string and is skipped; the
  process must never crash on bad input.

---

## Verifying changes (how this was tested)

Launch off-screen in the background, append a `seq`-numbered batch to
`io/commands.jsonl`, poll `io/results.jsonl` for the `batch_done` sentinel, read
`state.json` + view renders, then `Stop-Process -Name
Godot_v4.7-stable_win64_console`. For a compile check only:
`./engine/Godot_v4.7-stable_win64_console.exe --path ./project --once --minimized`
(builds, renders once, dumps, quits).
