# Driving the Agentic 3D Level Editor

You are an LLM agent building a 3D level by issuing file-based commands to a
running Godot process. The editor supplies spatial precision; you supply
high-level structure and verification against a goal. **Read this whole file
before issuing commands.**

## How it works

One persistent **windowed** Godot process holds the scene (the single source of
truth) and talks to you only through files in this project:

```
  YOU  ──append──►  io/commands.jsonl   ──watch+exec──►  GODOT
  YOU  ◄──read────  io/results.jsonl    ◄──append──────  GODOT
  YOU  ◄──read────  io/state.json       ◄──dump─────────  GODOT
  YOU  ◄──view────  renders/*.png       ◄──render───────  GODOT
```

Launch it from the repo root: `bash run.sh` (windowed, watch live) or
`bash run.sh --minimized` (window off-screen; renders still produced).

## The command protocol

Append **one JSON object per line** to `io/commands.jsonl`:

```json
{"seq": 12, "cmd": "spawn", "args": {"asset": "box", "rel_to": "door_1", "offset": [3,0,0]}, "note": "cover near east door"}
```

- `seq` — strictly increasing integer. The process ignores any line whose
  `seq <= last executed`, so never reuse a seq.
- `cmd` / `args` — see the catalog below. `note` is optional (copied to
  `build_log.jsonl`).
- A **batch** = all pending lines at once. The process runs them in `seq`
  order, then **automatically** re-dumps `state.json` and re-renders the
  canonical views once at the end.

For each command the process appends a result line to `io/results.jsonl`:

```json
{"seq": 12, "ok": true, "result": {"id": "box_7", "position": [4.0,0.5,-7.0]}, "error": null}
```

After the batch's auto-render it appends a **sentinel**:

```json
{"seq": 12, "batch_done": true, "renders": ["renders/top.png","renders/persp.png","renders/side.png"], "state": "io/state.json", "tick": 88}
```

**Wait for the `batch_done` whose `seq` equals your highest sent `seq`**, then
read `state.json` and view the PNGs.

## Coordinate convention (pinned — do not redrive)

- **1 world unit = 1 meter.** Y-up, **−Z is forward**, right-handed.
- Rotations are degrees, Euler `[x, y, z]`.
- Top view: +X is screen-right, +Z is screen-down, **−Z (forward) is "north"**.

## `state.json` — your ground truth

Read every spatial value from here, **never from pixels**. Key fields:
`tick`, `units`, `axes`, `selection`, `objects[]` (each has `id`, `type`,
`asset`, `position`, `rotation_deg`, `scale`, `parent`, `aabb_world` {min,max},
`forward`), `cameras` (top/persp/side), `reference` {id, height_m}, and
`checks` {floaters, overlaps, scale_warnings, navmesh_baked, reachability,
goal_checklist}.

## The renders

After each batch: `top.png` (orthographic map — primary), `persp.png` (3/4
view), `side.png` (elevation), plus un-annotated `*_clean.png` variants.
Annotated views show object-id labels, the selection's bounding box, a ground
grid with coordinate ticks, an axis gizmo, a north arrow, a scale bar, forward
arrows, and **yellow highlights on objects that changed since the last render**.
Use renders for gestalt ("does this read right?") and for pointing
(`raycast_screen`), **not** for measurement.

## The operating loop (follow this discipline)

**Per cycle:** read the goal → read `state.json` and view `top.png` +
`persp.png` → plan a batch of **relative/snapped** operations → append the
batch to `commands.jsonl` (optionally ending in a `render`) → wait for the
`batch_done` sentinel → read the new `state.json`, view renders → run the
relevant `check_*` commands → diff against the goal checklist → fix or proceed.

**Discipline:**
- **Express intent relatively.** Prefer `rel_to`+`offset`, `by`, `snap`,
  `align`, `array` over absolute coordinates. Absolute `at`/`to` is the
  fallback, not the default.
- **Plan in 2D first** (top view), **whitebox before detailing**, never do
  precise placement on geometry that's about to move.
- **Measure, don't guess** (`measure`); calibrate sizes against the reference
  capsule (`state.reference`).
- **Verify per batch, not per action.** Re-dump, re-render, run checks, diff.
- `log_intent` per batch so a long session's plan survives.
- After moving/adding geometry, **`bake_navmesh` before `check_reachable`**.

## Command catalog (`cmd` → `args`)

**Action:** `spawn` {asset, at?|rel_to?+offset?, rotation_deg?, scale?, type?} ·
`select`/`deselect` {ids} · `delete` {ids} · `move` {ids, to?|by?|rel_to?+offset?} ·
`rotate` {ids, by_deg?|to_deg?|face_point?} · `scale_obj` {ids, factor?|to?|to_height_m?} ·
`align` {ids, axis, edge} · `distribute` {ids, axis, spacing?} ·
`duplicate` {ids, by?, count?} · `array` {id, count, step:[dx,dy,dz]} (count = total) ·
`group`/`parent` {ids, parent?}

**Grounding:** `raycast_screen` {camera, screen:[x,y]} → {point, normal, hit_id} ·
`select_by_ray` {camera, screen} · `snap` {ids, mode:"grid"|"surface"|"edge", grid?} ·
`gravity_drop` {ids} · `overlap_query` {id} · `resolve_overlap` {ids} ·
`measure` {from_id?|from_point?, to_id?|to_point?} | {ray:{origin,dir}} ·
`add_reference` {height_m, at?}

**Generators:** `make_room` {origin(center), width, length, height, wall_thickness?}
→ returns walls{north,south,east,west}, floor · `make_corridor` {from_point, to_point, width, height} ·
`make_stairs` {origin, steps, step_w, step_h, step_d, direction} ·
`make_opening` {wall_id, center, width, height} (cuts a door; replaces the wall with segments)

**Camera/perception:** `render` {views?} · `set_camera` {name, position?, looking_at?, size?, fov?} ·
`bookmark_camera`/`goto_bookmark` {name} · `frame_selection` {camera} · `dump_state` {}

**Verification (results land in `state.checks`):** `check_support` {} (floaters) ·
`check_overlaps` {} · `check_scale` {} · `bake_navmesh` {} · `check_reachable` {from_point, to_point} ·
`physics_settle` {ids?} · `set_goal_checklist` {items:[string]} · `check_goal` {index, passed, evidence?}

**Meta:** `checkpoint` {name} · `restore` {name} · `undo` {} · `redo` {} (auto-checkpoint per
mutating batch) · `log_intent` {text} · `audit` {} (all checks + re-render)

## Gotchas

- One `batch_done` per batch — match it to your highest `seq` before reading.
- IDs are auto-assigned (`crate_7`, `wall_3`, `room_1`, …) and returned in
  `result`; read them there, don't assume.
- `make_opening` deletes the original wall and returns the new segment ids.
- A malformed line gets `ok:false` and is skipped; the process never crashes.
