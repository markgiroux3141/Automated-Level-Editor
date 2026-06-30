# Agentic 3D Level Editor — Build Spec

**Audience:** a Claude Code agent building this from scratch.
**Goal:** a Godot-based "level editor" that an LLM agent drives entirely through files — it issues commands, then perceives the result through a structured scene dump plus annotated screenshots, and iterates in a closed loop. The editor supplies the spatial precision the LLM lacks; the LLM supplies high-level structure and verification against a goal.

Build this in **phases** (Section 10). Each phase ends in a runnable artifact. Do not attempt the whole thing in one pass. Produce a runnable box-on-screen + screenshot at the end of Phase 0.

---

## 1. Core design principles (read first — these drive every decision)

1. **Minimize open-loop coordinate generation; maximize relative and snapped operations.** Every command should let the driving agent express intent as a *relationship* ("on top of `table_2`", "+3 units along X from `door_1`", "snap to grid") rather than absolute floats. Absolute placement is allowed but is the fallback, not the default.
2. **Scene graph is the source of truth for numbers; screenshots are for gestalt only.** The agent reads positions/sizes from `state.json`, never from pixels. Screenshots answer "does this read correctly / is anything obviously wrong", not "where is this".
3. **Plan in 2D, then lift to 3D.** Top-down orthographic layout is the agent's strongest mode (map/grid reasoning). The toolset and the loop should make flat layout cheap and explicit before adding height/detail.
4. **Coarse-to-fine / whitebox first.** Block out with grey primitives, validate spatial flow, then detail. Never do precise placement on geometry that's about to move.
5. **Verify per batch, not per action.** After a batch of edits: re-render canonical views, re-dump state, run automated checks, diff against goal. Batching keeps the token loop cheap.

If a design choice is ambiguous, resolve it in favor of whichever option best serves principles 1 and 2.

---

## 2. Tech stack & environment

- **Engine:** Godot **4.7** stable (single self-contained binary; ~164 MB; no installer). Download the standard (non-.NET) build unless C# is specifically wanted — **GDScript** is the implementation language here.
- **Language:** GDScript.
- **Physics:** Jolt (the default 3D physics engine since 4.6) — used for settle/collision probes.
- **Navigation:** built-in `NavigationRegion3D` / `NavigationServer3D` for navmesh baking and reachability.
- **Run mode:** **windowed, NOT `--headless`.** This is critical — `--headless` uses a dummy renderer and will produce blank/garbage screenshots. A real GPU context is required for real PNGs. Running windowed also lets the human watch the agent build live, which is a primary debugging asset. (Headless-server rendering later would need xvfb / an EGL offscreen context; out of scope for v1.)
- **Launch:** `godot --path ./project` (the project's `main.gd` runs the loop).

### Units & coordinate convention (pin this everywhere)
- **1 world unit = 1 meter.**
- Godot convention: **Y-up, right-handed, −Z is "forward"** for an object's local basis.
- Rotations reported and accepted in **degrees** as Euler `[x, y, z]` unless a command says otherwise.
- All overlays, the state dump, and the command schema use this convention consistently.

---

## 3. Architecture & data flow

One persistent Godot process holds the scene (the single source of truth) and exposes itself to the agent purely through the filesystem. No network, no MCP, no sockets in v1.

```
              append commands              watch + execute
  AGENT  ───────────────────────►  commands.jsonl  ───────────►  GODOT PROCESS
 (Claude                                                         (holds scene,
  Code)   ◄───────── read ──────────  results.jsonl  ◄───────────  is truth)
          ◄───────── read ──────────  state.json
          ◄───────── view (image) ──  renders/*.png
```

Workspace layout (all relative to project root, create on startup if missing):

```
project/
  project.godot
  main.gd               # entry: the command-watch loop + tool dispatch
  tools/                # one .gd per tool group (perception, grounding, action, verify, meta)
  io/
    commands.jsonl      # agent writes; process consumes in seq order
    results.jsonl       # process writes; one line per executed command
    state.json          # full scene dump, overwritten after each batch
  renders/
    top.png             # orthographic top-down (primary)
    persp.png           # perspective / player-eye
    side.png            # orthographic side (elevation), optional until Phase 3
  checkpoints/          # serialized scene snapshots for undo
  build_log.jsonl       # agent's stated intentions per batch
  CLAUDE.md             # operating instructions for the driving agent (a deliverable)
  run.sh                # launches the editor
```

---

## 4. Command protocol (the I/O contract)

### Input: `commands.jsonl`
The agent appends one JSON object per line. The process maintains `last_seq` (persisted) and executes any line whose `seq > last_seq`, in ascending order. Each line:

```json
{"seq": 12, "cmd": "spawn", "args": {"asset": "box", "rel_to": "door_1", "offset": [3,0,0]}, "note": "cover near east door"}
```

- `seq` — strictly increasing integer. The process ignores lines it has already executed (guards against re-reads).
- `cmd` — tool name (Section 7).
- `args` — tool-specific object.
- `note` — optional human/agent rationale; copied into `build_log.jsonl`.

A batch is "all currently pending lines". The process executes them in order, then **automatically** re-dumps `state.json` and re-renders the canonical views once at the end of the batch (not per command). A `render` command may be issued mid-batch to force an intermediate frame.

**Robustness requirements:**
- Detect new lines by polling file mtime/size each frame in `_process`; tolerate partial writes (a line without a trailing newline is "not ready yet" — wait for it).
- Writes from the process (`results.jsonl`, `state.json`, PNGs) must be **atomic**: write to `*.tmp`, then rename over the target, so the agent never reads a half-written file.
- A malformed command line → write a `results` entry with `"ok": false` and an error string; never crash the process.

### Output: `results.jsonl`
One line appended per executed command:

```json
{"seq": 12, "ok": true, "result": {"id": "box_7", "position": [4.0,0.5,-7.0]}, "error": null}
```

After the batch's auto-render, append a batch sentinel:

```json
{"seq": 12, "batch_done": true, "renders": ["renders/top.png","renders/persp.png"], "state": "io/state.json", "tick": 88}
```

The agent polls `results.jsonl` for the `batch_done` sentinel matching its highest sent `seq`, then reads `state.json` and views the PNGs.

---

## 5. `state.json` schema (the agent's ground truth)

Overwritten atomically after each batch. The agent reads all spatial values from here.

```json
{
  "tick": 88,
  "units": "meters",
  "axes": "Y-up, -Z forward, right-handed",
  "selection": ["box_7"],
  "objects": [
    {
      "id": "box_7",
      "type": "crate",
      "asset": "box",
      "position": [4.0, 0.5, -7.0],
      "rotation_deg": [0, 90, 0],
      "scale": [1, 1, 1],
      "parent": "root",
      "aabb_world": {"min": [3.5,0,-7.5], "max": [4.5,1,-6.5]},
      "forward": [-1, 0, 0]
    }
  ],
  "cameras": {
    "top":   {"projection":"ortho","position":[0,40,0],"size":50},
    "persp": {"projection":"perspective","position":[12,6,12],"looking_at":[0,1,0],"fov":60}
  },
  "reference": {"id":"ref_human","height_m":1.8},
  "checks": {
    "floaters": [], "overlaps": [], "scale_warnings": [],
    "navmesh_baked": false, "reachability": null,
    "goal_checklist": []
  }
}
```

Keep this stable — the agent and `CLAUDE.md` depend on these field names.

---

## 6. Perception: the canonical renders

After each batch, produce at minimum `top.png` and `persp.png` (add `side.png` in Phase 3). Each render has both the 3D scene and a **2D annotation overlay** baked into the same image, so the agent sees labels in the screenshot it views.

Implementation approach for overlays: a `CanvasLayer` containing `Control` nodes (Labels, `Line2D`), positioned each frame via `Camera3D.unproject_position(world_pos)`. Because it's part of the viewport, it appears in `get_viewport().get_texture().get_image().save_png(...)` automatically. Also save a **clean** (un-annotated) variant per view (e.g. `top_clean.png`) for when the agent wants unobstructed pixels.

Overlay contents:
- **Object ID labels** anchored to each object's screen position.
- **Bounding boxes** (projected AABB) for selected objects.
- **Ground grid** with coordinate ticks (so the top view reads as a map).
- **Axis gizmo** (X/Y/Z) and a **north arrow** in a corner.
- **Scale bar** ("5 m") so the agent can gauge size without trusting raw pixels.
- **Forward arrows** on objects (from the `forward` vector) to disambiguate orientation.

**Top camera** = `Camera3D` with `PROJECTION_ORTHOGONAL`, placed high, looking straight down −Y; expose `size` so the agent can zoom. **Persp camera** = standard perspective at a 3/4 angle, with a `frame_selection` command and named bookmarks (Phase 3).

---

## 7. Tool / command catalog

Group these into `tools/*.gd`. Signatures are `args` shapes. All ID-returning commands put the new/affected id(s) in `result`.

### 7a. Action — spawning & transform (Phase 1–4)
| cmd | args | notes |
|---|---|---|
| `spawn` | `{asset, at?|rel_to?+offset?, rotation_deg?, scale?, type?}` | `rel_to` resolves against another object's transform/AABB. Prefer `rel_to` over `at`. |
| `select` / `deselect` | `{ids}` | updates `selection` in state |
| `select_by_ray` | `{camera, screen: [x,y]}` | pick the object under a screenshot pixel (see grounding) |
| `delete` | `{ids}` | |
| `move` | `{ids, to?: [x,y,z], by?: [dx,dy,dz], rel_to?+offset?}` | `by` = relative (preferred); `to` = absolute |
| `rotate` | `{ids, by_deg?: [..], to_deg?: [..], face_point?: [x,y,z]}` | `face_point` orients −Z toward a world point |
| `scale_obj` | `{ids, factor?: f, to?: [..], to_height_m?: f}` | `to_height_m` scales to a real-world height |
| `align` | `{ids, axis, edge}` | align tops/centers/etc. along an axis |
| `distribute` | `{ids, axis, spacing?}` | even spacing |
| `duplicate` | `{ids, by?: [..], count?}` | |
| `array` | `{id, count, step: [dx,dy,dz]}` | e.g. a row of 5 columns 3 m apart in one call |
| `group` / `parent` | `{ids, parent?}` | reparent / make a named group |

### 7b. Grounding — the precision substitutes (Phase 2)
| cmd | args | notes |
|---|---|---|
| `raycast_screen` | `{camera, screen: [x,y]}` | unproject pixel → world ray → first hit. Returns `{point, normal, hit_id}`. Use `camera.project_ray_origin` / `project_ray_normal` + `PhysicsDirectSpaceState3D.intersect_ray`. This is the main "place where I'm pointing in the screenshot" bridge. |
| `snap` | `{ids, mode: "grid"|"surface"|"edge", grid?}` | grid-snap, drop-onto-surface-below, or edge/vertex align |
| `gravity_drop` | `{ids}` | raycast down, rest object on first surface; kills floaters |
| `overlap_query` | `{id}` | returns intersecting object ids |
| `resolve_overlap` | `{ids}` | push-out along minimal axis until clear |
| `measure` | `{from_id?|from_point?, to_id?|to_point?}` or `{ray: {origin, dir}}` | exact distance / gap / ceiling height. The agent measures instead of guessing. |
| `add_reference` | `{height_m: 1.8}` | persistent humanoid capsule for scale calibration; reported in `state.reference` |

### 7c. Parametric generators (Phase 4) — collapse many placements into one intent
| cmd | args |
|---|---|
| `make_room` | `{origin, width, length, height, wall_thickness?}` |
| `make_corridor` | `{from_point, to_point, width, height}` |
| `make_stairs` | `{origin, steps, step_w, step_h, step_d, direction}` |
| `make_opening` | `{wall_id, center, width, height}` (door/window cut) |

### 7d. Perception & camera (Phase 1, polished Phase 3)
| cmd | args |
|---|---|
| `render` | `{views?: ["top","persp","side"]}` — force a frame mid-batch |
| `set_camera` | `{name, position?, looking_at?, size?, fov?}` |
| `bookmark_camera` / `goto_bookmark` | `{name}` |
| `frame_selection` | `{camera}` |
| `dump_state` | `{}` — force a state write |

### 7e. Verification (Phase 5)
| cmd | args | result into `state.checks` |
|---|---|---|
| `check_support` | `{}` | list of floating object ids |
| `check_overlaps` | `{}` | interpenetrating pairs |
| `check_scale` | `{}` | objects implausibly sized vs reference (e.g. doors not ~2 m) |
| `bake_navmesh` | `{}` | bake `NavigationRegion3D`; sets `navmesh_baked` |
| `check_reachable` | `{from_point, to_point}` | path exists & not truncated (`NavigationServer3D.map_get_path`) |
| `physics_settle` | `{ids?, steps?}` | run Jolt for N steps; report movement (finds holes/instability) |
| `set_goal_checklist` | `{items: [string]}` | store decomposed sub-goals |
| `check_goal` | `{index, passed, evidence?}` | agent marks a sub-goal verified |

### 7f. Meta / robustness (Phase 6)
| cmd | args |
|---|---|
| `checkpoint` | `{name}` — serialize scene to `checkpoints/` |
| `restore` | `{name}` — revert |
| `undo` / `redo` | `{}` — stack over auto-checkpoints per batch |
| `log_intent` | `{text}` — append to `build_log.jsonl` |
| `audit` | `{}` — run all checks + re-render (periodic full re-audit) |

---

## 8. Verification suite (why it matters)

These convert "is the level correct?" — a perception problem the LLM is weak at — into pass/fail tests it consumes well. Prioritize getting **navmesh reachability** and **support/overlap** checks working; they catch the highest-impact failures (unreachable areas, walls with no door, floating and interpenetrating geometry). All check results land in `state.checks` so the agent reads outcomes rather than eyeballing them.

---

## 9. The agent operating loop (author this into `CLAUDE.md`)

`CLAUDE.md` is a deliverable. It must document (a) the command schema and `state.json` shape, (b) the coordinate convention, and (c) this loop discipline so any future session drives the editor correctly without rederiving conventions:

> **Per cycle:** read the goal → read `state.json` and view `top.png` + `persp.png` → plan a batch of **relative/snapped** operations → append the batch to `commands.jsonl` ending in a render → wait for the `batch_done` sentinel → read new `state.json`, view renders → run the relevant checks → diff result against the goal checklist → fix or proceed.
>
> **Discipline:** plan layout in the top-down view first; whitebox before detailing; never read a position off a screenshot — read it from `state.json`; when unsure of a distance, `measure` instead of guessing; calibrate sizes against the reference capsule; log intent per batch so the plan survives a long session.

---

## 10. Build phases (each ends runnable)

**Phase 0 — Skeleton (do this first).** Create `project.godot`, `main.gd`, `run.sh`. On launch: open a window, build a ground plane + one grey box + the reference capsule, write `state.json`, render `top.png` and `persp.png` once. **Acceptance:** `bash run.sh` shows a box in a window and writes valid `state.json` + two PNGs to disk.

**Phase 1 — Command loop.** Implement the `commands.jsonl` watcher (seq ordering, atomic writes, partial-line tolerance), `results.jsonl`, auto-render + auto-dump per batch. Tools: `spawn`, `delete`, `select`, `move`, `render`, `dump_state`. **Acceptance:** appending a spawn+move batch produces the object in the render and in state, with a correct `batch_done` sentinel.

**Phase 2 — Grounding.** `raycast_screen`, `select_by_ray`, `snap` (grid+surface), `gravity_drop`, `overlap_query`+`resolve_overlap`, `measure`, `add_reference`. **Acceptance:** an object placed via a screen pixel lands on the surface under that pixel; `measure` between two objects matches their state positions.

**Phase 3 — Perception polish.** Annotation overlays (IDs, bboxes, grid+ticks, axis gizmo, north arrow, scale bar, forward arrows), clean variants, `side.png`, ortho top camera controls, camera bookmarks, `frame_selection`, diff highlight of changed objects. **Acceptance:** `top.png` reads as a labeled map; selected object shows its bbox and forward arrow.

**Phase 4 — Higher-level actions.** `rotate`/`scale_obj` (incl. `to_height_m`, `face_point`), `align`, `distribute`, `duplicate`, `array`, `group`/`parent`, and the parametric generators (`make_room`, `make_corridor`, `make_stairs`, `make_opening`). **Acceptance:** `make_room` produces an enclosed room with a doorway via `make_opening`, visible in both views.

**Phase 5 — Verification.** `check_support`, `check_overlaps`, `check_scale`, `bake_navmesh`, `check_reachable`, `physics_settle`, goal checklist commands; results written into `state.checks`. **Acceptance:** a deliberately floating box is flagged by `check_support`; `check_reachable` returns false across a gap and true once a corridor connects two rooms.

**Phase 6 — Meta/robustness + handoff.** `checkpoint`/`restore`/`undo`/`redo`, `log_intent`, `audit`, periodic re-audit. Author `CLAUDE.md` (Section 9) and finalize `run.sh`. **Acceptance:** a bad batch can be undone cleanly; `CLAUDE.md` lets a fresh session build a simple two-room level end to end.

---

## 11. Smoke test (end-to-end, run after Phase 5)

Drive the editor (by hand-writing batches to `commands.jsonl`) to build: two rooms connected by a corridor with a doorway in each shared wall, a few crates as cover in one room, and the reference capsule. Then `bake_navmesh` and `check_reachable` between the room centers. **Pass = ** reachability true, zero floaters, zero overlaps, no scale warnings, and both renders show a coherent two-room layout.

---

## 12. Known wrinkles & gotchas (do not rediscover these)

- **Never run `--headless` for the render path.** Dummy renderer → blank screenshots. Run windowed; a real GPU/display context is required.
- **Atomic file writes are mandatory.** Write `*.tmp` then rename, for `state.json`, `results.jsonl`, and every PNG, or the agent will read torn files.
- **Tolerate partial command lines.** The agent's append may be observed mid-write; only execute lines terminated by a newline and parseable as JSON.
- **Seq guards prevent double-execution.** Persist `last_seq`; re-reading the file must not re-run old commands.
- **Don't let the agent read coordinates from pixels.** Everything spatial comes from `state.json`. The overlays exist to aid gestalt judgment and pointing (via `raycast_screen`), not measurement.
- **Jolt is default (4.6+)** — fine for settle/probe; don't pull in a third-party physics lib.
- **GPU context note for later:** moving to a headless server would require xvfb / EGL offscreen rendering. Out of scope for v1 but keep the render path isolated so it can be swapped.

---

## 13. Deliverables checklist

- [ ] Runnable Godot 4.7 project (`project.godot`, `main.gd`, `tools/*.gd`, `run.sh`)
- [ ] File-based command loop with atomic I/O and seq guards
- [ ] Full tool catalog (Section 7) wired to dispatch
- [ ] Annotated canonical renders (top, persp, side) + clean variants
- [ ] Verification suite writing into `state.checks`
- [ ] Checkpoint/undo + build log
- [ ] `CLAUDE.md` documenting schema, conventions, and the operating loop
- [ ] Passing end-to-end smoke test (Section 11)
