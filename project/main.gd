extends Node
## Agentic 3D Level Editor — process entry point & command loop.
##
## One persistent windowed Godot process holds the live scene (the single
## source of truth) and talks to the driving agent purely through files:
##
##   agent  --append-->  io/commands.jsonl  --watch+exec-->  THIS PROCESS
##   agent  <--read----  io/results.jsonl   <--append------  THIS PROCESS
##   agent  <--read----  io/state.json      <--dump---------  THIS PROCESS
##   agent  <--view----  renders/*.png      <--render-------  THIS PROCESS
##
## Conventions (pinned everywhere — spec §2):
##   1 world unit = 1 meter. Y-up, -Z forward, right-handed.
##   Rotations in degrees as Euler [x, y, z].
##
## main.gd owns everything tree-coupled (world geometry, viewports, render
## awaits, the _process watch loop) and exposes a small primitive API
## (spawn/register/move/get_obj/render_all/dump_state) that the tool modules
## in tools/*.gd call into. Command handlers live in those modules.

# --- Workspace paths (res:// = project root) ---
const DIR_IO := "res://io"
const DIR_RENDERS := "res://renders"
const DIR_CHECKPOINTS := "res://checkpoints"

const PATH_STATE := DIR_IO + "/state.json"
const PATH_COMMANDS := DIR_IO + "/commands.jsonl"
const PATH_RESULTS := DIR_IO + "/results.jsonl"
const PATH_LAST_SEQ := DIR_IO + "/last_seq.txt"
const PATH_BUILD_LOG := "res://build_log.jsonl"

# --- Render sizes ---
const TOP_VIEW_SIZE := Vector2i(1024, 1024)
const PERSP_VIEW_SIZE := Vector2i(1280, 720)

# --- Live world ---
var world_root: Node3D
var registry := {}                # id -> { node, type, asset }
var selection: Array[String] = []
var _id_counters := {}
var tick := 0

# --- Cameras / viewports ---
var top_viewport: SubViewport
var persp_viewport: SubViewport
var side_viewport: SubViewport
var top_camera: Camera3D
var persp_camera: Camera3D
var side_camera: Camera3D
var _views := {}                  # name -> { vp, cam, overlay }
var bookmarks := {}               # name -> { transform, fov }
var changed_ids: Array = []       # ids changed since the previous render (diff highlight)
var _last_render_xforms := {}     # id -> Transform3D, snapshot for diffing

# --- Reference capsule ---
var reference_id := ""
var reference_height_m := 1.8

# --- Verification state (mirrored into state.checks each dump) ---
var checks := {
	"floaters": [], "overlaps": [], "scale_warnings": [],
	"navmesh_baked": false, "reachability": null, "goal_checklist": [],
}
var nav_region: NavigationRegion3D = null

# --- Undo/redo (auto-checkpoint per mutating batch) ---
var undo_stack: Array = []
var redo_stack: Array = []
const MAX_UNDO := 50

# --- Command loop state ---
var last_seq := 0
var _io_cursor := 0               # bytes of commands.jsonl consumed (complete lines)
var _busy := false
var _results_lines: PackedStringArray = []
var _build_log_lines: PackedStringArray = []

# --- Tool modules ---
var actions       # tools/actions.gd
var grounding     # tools/grounding.gd
var camera_tools  # tools/camera_tools.gd
var generators    # tools/generators.gd
var verify        # tools/verify.gd
var meta          # tools/meta.gd


func _ready() -> void:
	_ensure_dirs()
	_load_persisted()
	_build_world()
	_setup_navigation()
	_build_viewports()
	actions = preload("res://tools/actions.gd").new(self)
	grounding = preload("res://tools/grounding.gd").new(self)
	camera_tools = preload("res://tools/camera_tools.gd").new(self)
	generators = preload("res://tools/generators.gd").new(self)
	verify = preload("res://tools/verify.gd").new(self)
	meta = preload("res://tools/meta.gd").new(self)

	await get_tree().process_frame
	await get_tree().process_frame
	await render_all()
	dump_state()
	print("[main] ready (tick=%d, last_seq=%d). Watching %s" % [tick, last_seq, PATH_COMMANDS])

	# Unattended/automated runs: move the window off-screen instead of
	# minimizing. Minimizing throttles the render/physics loop so awaits on
	# frame_post_draw / physics_frame never resume; an off-screen NORMAL window
	# keeps rendering (the SubViewport PNGs are unaffected) while staying out of
	# the way and not holding the foreground.
	if "--minimized" in OS.get_cmdline_args():
		get_window().position = Vector2i(-4000, -4000)

	if "--once" in OS.get_cmdline_args():
		get_tree().quit()


# ---------------------------------------------------------------------------
# Command watch loop
# ---------------------------------------------------------------------------
func _process(_dt: float) -> void:
	if _busy:
		return
	var lines := _read_new_complete_lines()
	if lines.is_empty():
		return
	_busy = true
	_run_batch(lines)   # coroutine; clears _busy when done


func _run_batch(lines: PackedStringArray) -> void:
	# Parse every complete line, then execute in ascending seq order.
	var parsed := []
	for raw in lines:
		var s := raw.strip_edges()
		if s.is_empty():
			continue
		var json := JSON.new()
		if json.parse(s) != OK or typeof(json.data) != TYPE_DICTIONARY:
			parsed.append({ "ok": false, "seq": -1, "error": "malformed JSON: " + s })
			continue
		parsed.append({ "ok": true, "data": json.data })

	# Stable sort by seq (malformed entries keep seq -1, run first/harmlessly).
	parsed.sort_custom(func(a, b): return _seq_of(a) < _seq_of(b))

	# Auto-checkpoint: snapshot the pre-batch scene so the whole batch can be
	# undone as a unit. Only commit it if the batch actually mutates the scene
	# and isn't itself an undo/redo.
	var pre_snapshot := snapshot_scene()
	var batch_mutates := false
	var batch_has_undo := false
	for entry in parsed:
		if entry.get("ok", false):
			var c := str(entry["data"].get("cmd", ""))
			if c in ["undo", "redo"]:
				batch_has_undo = true
			elif _is_mutating(c):
				batch_mutates = true

	var executed_any := false
	var max_seq := last_seq
	for entry in parsed:
		if not entry["ok"]:
			_append_result({ "seq": null, "ok": false, "result": null, "error": entry["error"] })
			continue
		var d: Dictionary = entry["data"]
		var seq := int(d.get("seq", -1))
		if seq <= last_seq:
			continue   # seq guard: never re-execute
		var cmd := str(d.get("cmd", ""))
		var args: Dictionary = d.get("args", {}) if typeof(d.get("args")) == TYPE_DICTIONARY else {}
		var note := str(d.get("note", ""))

		# bake_navmesh is a coroutine (it must straddle physics frames while it
		# frees the old region, registers a new one, and bakes); everything else
		# dispatches synchronously.
		var res: Dictionary
		if cmd == "bake_navmesh":
			res = await _do_bake()
		else:
			res = _dispatch(cmd, args)
		_append_result({
			"seq": seq, "ok": res.get("ok", false),
			"result": res.get("result", null), "error": res.get("error", null),
		})
		if note != "":
			_append_build_log({ "seq": seq, "cmd": cmd, "note": note })

		last_seq = seq
		max_seq = max(max_seq, seq)
		executed_any = true

		# A render command forces an intermediate frame mid-batch.
		if res.get("ok", false) and cmd == "render":
			await render_all(res.get("result", {}).get("views", ["top", "persp", "side"]))

	if batch_mutates and not batch_has_undo:
		undo_stack.append(pre_snapshot)
		if undo_stack.size() > MAX_UNDO:
			undo_stack.pop_front()
		redo_stack.clear()

	if executed_any:
		await render_all()
		dump_state()
		_append_result({
			"seq": max_seq, "batch_done": true,
			"renders": ["renders/top.png", "renders/persp.png", "renders/side.png"],
			"state": "io/state.json", "tick": tick,
		})
		_persist_last_seq()

	_flush_results()
	_flush_build_log()
	_busy = false


func _seq_of(entry: Dictionary) -> int:
	if not entry.get("ok", false):
		return -1
	return int(entry["data"].get("seq", -1))


# ---------------------------------------------------------------------------
# Command dispatch
# ---------------------------------------------------------------------------
func _dispatch(cmd: String, args: Dictionary) -> Dictionary:
	match cmd:
		"spawn":      return actions.spawn(args)
		"delete":     return actions.delete(args)
		"select":     return actions.select(args)
		"deselect":   return actions.deselect(args)
		"move":       return actions.move(args)
		"rotate":     return actions.rotate(args)
		"scale_obj":  return actions.scale_obj(args)
		"align":      return actions.align(args)
		"distribute": return actions.distribute(args)
		"duplicate":  return actions.duplicate(args)
		"array":      return actions.array(args)
		"group", "parent": return actions.group(args)
		"make_room":     return generators.make_room(args)
		"make_corridor": return generators.make_corridor(args)
		"make_stairs":   return generators.make_stairs(args)
		"make_opening":  return generators.make_opening(args)
		"check_support":      return verify.check_support(args)
		"check_overlaps":     return verify.check_overlaps(args)
		"check_scale":        return verify.check_scale(args)
		"check_reachable":    return verify.check_reachable(args)
		"physics_settle":     return verify.physics_settle(args)
		"set_goal_checklist": return verify.set_goal_checklist(args)
		"check_goal":         return verify.check_goal(args)
		"checkpoint":  return meta.checkpoint(args)
		"restore":     return meta.restore(args)
		"undo":        return meta.undo(args)
		"redo":        return meta.redo(args)
		"log_intent":  return meta.log_intent(args)
		"audit":       return meta.audit(args)
		"raycast_screen":  return grounding.raycast_screen(args)
		"select_by_ray":   return grounding.select_by_ray(args)
		"snap":            return grounding.snap(args)
		"gravity_drop":    return grounding.gravity_drop(args)
		"overlap_query":   return grounding.overlap_query(args)
		"resolve_overlap": return grounding.resolve_overlap(args)
		"measure":         return grounding.measure(args)
		"add_reference":   return grounding.add_reference(args)
		"set_camera":        return camera_tools.set_camera(args)
		"bookmark_camera":   return camera_tools.bookmark_camera(args)
		"goto_bookmark":     return camera_tools.goto_bookmark(args)
		"frame_selection":   return camera_tools.frame_selection(args)
		"render":     return _ok({ "views": args.get("views", ["top", "persp", "side"]) })
		"dump_state":
			dump_state()
			return _ok({ "tick": tick })
		_:
			return _err("unknown command: '%s'" % cmd)


# ---------------------------------------------------------------------------
# Editor primitive API  (called by tool modules)
# ---------------------------------------------------------------------------
func get_obj(id: String) -> Node3D:
	if not registry.has(id):
		return null
	return registry[id]["node"]

## Capture camera for a named view ("top"/"persp") and its pixel size — the
## screen coords the agent supplies match those PNG dimensions.
func camera_by_name(name: String) -> Camera3D:
	match name:
		"top": return top_camera
		"persp", "perspective": return persp_camera
		_: return persp_camera

func viewport_size_for(name: String) -> Vector2:
	return Vector2(TOP_VIEW_SIZE if name == "top" else PERSP_VIEW_SIZE)

func space_state() -> PhysicsDirectSpaceState3D:
	return world_root.get_world_3d().direct_space_state

## Public world-space AABB lookup by id (Vector AABB).
func aabb_of(id: String) -> AABB:
	if not registry.has(id):
		return AABB()
	return _world_aabb(registry[id]["node"])

## ---------------------------------------------------------------------------
## Scene serialization (checkpoint / restore / undo)
## ---------------------------------------------------------------------------
## A full, self-contained description of the editable scene: enough to rebuild
## every object (mesh kind + size + colour + transform + parent).
func snapshot_scene() -> Dictionary:
	var objs := []
	for id in registry.keys():
		var entry: Dictionary = registry[id]
		var node: Node3D = entry["node"]
		objs.append({
			"id": id, "type": entry["type"], "asset": entry["asset"],
			"pos": _v3(node.position), "rot": _v3(node.rotation_degrees), "scale": _v3(node.scale),
			"parent": _parent_id_of(node),
			"shape": _capture_shape(node),
		})
	return {
		"objects": objs,
		"id_counters": _id_counters.duplicate(),
		"selection": selection.duplicate(),
		"reference_id": reference_id, "reference_height_m": reference_height_m,
	}


func _capture_shape(node: Node3D) -> Dictionary:
	var mi := node as MeshInstance3D
	if mi == null:
		for c in node.get_children():
			if c is MeshInstance3D:
				mi = c
				break
	if mi == null or mi.mesh == null:
		return { "kind": "group" }
	var col := Color(0.6, 0.6, 0.62)
	if mi.material_override is StandardMaterial3D:
		col = (mi.material_override as StandardMaterial3D).albedo_color
	if mi.mesh is BoxMesh:
		var s: Vector3 = (mi.mesh as BoxMesh).size
		return { "kind": "box", "size": _v3(s), "color": [col.r, col.g, col.b] }
	if mi.mesh is CapsuleMesh:
		var cm := mi.mesh as CapsuleMesh
		return { "kind": "capsule", "height": cm.height, "radius": cm.radius, "color": [col.r, col.g, col.b] }
	return { "kind": "group" }


## Replace the entire editable scene with a snapshot.
func apply_snapshot(snap: Dictionary) -> void:
	for id in registry.keys():
		registry[id]["node"].queue_free()
	registry.clear()
	selection = []
	# First pass: recreate every node flat under world_root.
	for o in snap["objects"]:
		var node := _rebuild_node(o["shape"])
		node.name = o["id"]
		registry[o["id"]] = { "node": node, "type": o["type"], "asset": o["asset"] }
		world_root.add_child(node)
		node.position = to_vec3(o["pos"])
		node.rotation_degrees = to_vec3(o["rot"])
		node.scale = to_vec3(o["scale"], Vector3.ONE)
	# Second pass: restore group parenting (keep world transforms).
	for o in snap["objects"]:
		if o["parent"] != "root" and registry.has(o["parent"]):
			get_obj(o["id"]).reparent(get_obj(o["parent"]), true)
	_id_counters = (snap.get("id_counters", {}) as Dictionary).duplicate()
	selection = []
	for s in snap.get("selection", []):
		if registry.has(str(s)):
			selection.append(str(s))
	reference_id = snap.get("reference_id", reference_id)
	reference_height_m = snap.get("reference_height_m", reference_height_m)


func _rebuild_node(shape: Dictionary) -> Node3D:
	match shape.get("kind", "group"):
		"box":
			var c: Array = shape.get("color", [0.6, 0.6, 0.62])
			return _new_box(Color(c[0], c[1], c[2]), to_vec3(shape["size"], Vector3.ONE))
		"capsule":
			var cc: Array = shape.get("color", [0.85, 0.55, 0.2])
			return _new_capsule(float(shape["height"]), float(shape["radius"]), Color(cc[0], cc[1], cc[2]))
		_:
			return Node3D.new()


## Combined world-space AABB of a set of object ids (empty AABB if none).
func combined_aabb(ids: Array) -> AABB:
	var box := AABB()
	var started := false
	for id in ids:
		if not registry.has(str(id)):
			continue
		var b := _world_aabb(registry[str(id)]["node"])
		if not started:
			box = b
			started = true
		else:
			box = box.merge(b)
	return box

## RID of an object's physics body, for ray exclusion.
func body_rid(id: String) -> RID:
	var node := get_obj(id)
	if node is CollisionObject3D:
		return (node as CollisionObject3D).get_rid()
	return RID()

## Find the registry id that owns a collider RID (reverse lookup for raycasts).
func id_for_collider(obj: Object) -> String:
	if obj == null:
		return ""
	for id in registry.keys():
		if registry[id]["node"] == obj:
			return id
	return ""

func has_obj(id: String) -> bool:
	return registry.has(id)

func ids_arg(args: Dictionary) -> Array:
	# Accept "ids": [..] or single "id".
	if args.has("ids"):
		return args["ids"] if typeof(args["ids"]) == TYPE_ARRAY else [args["ids"]]
	if args.has("id"):
		return [args["id"]]
	return []

## Resolve a position from rel_to+offset, or "at", else a fallback.
func resolve_position(args: Dictionary, fallback := Vector3.ZERO) -> Vector3:
	if args.has("rel_to") and has_obj(str(args["rel_to"])):
		var base := get_obj(str(args["rel_to"])).global_position
		return base + to_vec3(args.get("offset", null), Vector3.ZERO)
	if args.has("at"):
		return to_vec3(args["at"], fallback)
	return fallback

func spawn_asset(asset: String, type := "") -> Node3D:
	if type == "":
		type = "crate" if asset == "box" else asset
	var node := _make_mesh_for_asset(asset)
	return node

func register(node: Node3D, type: String, asset: String) -> String:
	var id := _next_id(type)
	node.name = id
	registry[id] = { "node": node, "type": type, "asset": asset }
	world_root.add_child(node)
	return id

## Spawn an explicitly-sized box body (used by the parametric generators).
func add_box(size: Vector3, pos: Vector3, type := "wall", asset := "box", color := Color(0.55, 0.55, 0.58)) -> String:
	var node := _new_box(color, size)
	node.position = pos
	return register(node, type, asset)

## Clone an existing object (preserving mesh size, scale, rotation), offset.
func clone_obj(id: String, offset := Vector3.ZERO) -> String:
	if not registry.has(id):
		return ""
	var entry: Dictionary = registry[id]
	var dup := (entry["node"] as Node3D).duplicate()
	var new_id := _next_id(entry["type"])
	dup.name = new_id
	registry[new_id] = { "node": dup, "type": entry["type"], "asset": entry["asset"] }
	world_root.add_child(dup)
	dup.global_position = (entry["node"] as Node3D).global_position + offset
	return new_id

## Create an empty group node and reparent the given ids under it (keeping
## their world transforms). Returns the group's id.
func make_group(child_ids: Array, prefix := "group") -> String:
	var group := Node3D.new()
	var gid := _next_id(prefix)
	group.name = gid
	registry[gid] = { "node": group, "type": prefix, "asset": "" }
	world_root.add_child(group)
	for cid in child_ids:
		var node := get_obj(str(cid))
		if node:
			node.reparent(group, true)
	return gid

func remove_obj(id: String) -> bool:
	if not registry.has(id):
		return false
	registry[id]["node"].queue_free()
	registry.erase(id)
	selection.erase(id)
	return true

func _make_mesh_for_asset(asset: String) -> Node3D:
	match asset:
		"box", "crate":
			return _new_box(Color(0.6, 0.6, 0.62))
		"capsule":
			return _new_capsule(1.8, 0.3, Color(0.85, 0.55, 0.2))
		_:
			# Unknown asset → grey unit box (whitebox default).
			return _new_box(Color(0.55, 0.55, 0.58))


# ---------------------------------------------------------------------------
# World construction
# ---------------------------------------------------------------------------
func _build_world() -> void:
	world_root = Node3D.new()
	world_root.name = "World"
	add_child(world_root)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.62, 0.67, 0.74)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.5, 0.5, 0.55)
	e.ambient_light_energy = 0.6
	env.environment = e
	world_root.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-55, -45, 0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	world_root.add_child(sun)

	_make_ground(50.0)
	# One grey whitebox crate at origin.
	var crate := register(_new_box(Color(0.6, 0.6, 0.62)), "crate", "box")
	get_obj(crate).position = Vector3(0, 0.5, 0)
	_make_reference(reference_height_m)


## Create the navigation region up-front (with an empty navmesh) so it has
## been registered with the world's navigation map for many frames before the
## first bake. Creating it lazily inside the first bake left the map empty
## until a second bake. Also pins the map cell size to match the navmesh.
const NAV_GROUP := "navsource"

## A freshly-configured NavigationMesh. bake_navmesh assigns a NEW one each
## time: re-baking the same resource in place updates its polygons but the
## navigation server dedupes by resource and never re-pushes it to the map.
func make_navmesh() -> NavigationMesh:
	var nm := NavigationMesh.new()
	nm.agent_radius = 0.25
	nm.agent_height = reference_height_m
	nm.agent_max_climb = 0.5
	nm.cell_size = 0.1
	nm.cell_height = 0.1
	# Parse static colliders (CPU-side, deterministic). MESH_INSTANCES parsing
	# reads geometry back from the GPU at runtime, which Godot warns against and
	# which produced non-deterministic polygon counts here. The trade-off —
	# collider transforms only commit on the next physics tick — is handled by
	# awaiting a physics frame before each bake (see main._run_batch).
	nm.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nm.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN
	nm.geometry_source_group_name = NAV_GROUP
	return nm

## Re-bake the navigation region. Runs as a coroutine because reliable runtime
## (re)baking requires straddling physics frames: free the old region and let
## it unregister, register a fresh region, let pending collider transforms
## commit, bake, then let the server sync the map. Doing this all in one frame
## leaves the map serving the previous (or empty) navmesh.
func _do_bake() -> Dictionary:
	for id in registry.keys():
		if registry[id]["type"] in ["crate", "wall", "floor", "step", "reference"]:
			get_obj(id).add_to_group(NAV_GROUP)
	await get_tree().physics_frame          # commit collider transforms

	# Procedural (re)bake — the canonical runtime path. Parse the source
	# geometry and bake into a FRESH navmesh on the calling thread, then assign
	# the already-filled mesh to the persistent region in one step. This avoids
	# both failure modes seen with NavigationRegion3D.bake_navigation_mesh at
	# runtime: re-baking the same resource leaves the map stale, and assigning
	# an empty resource then baking leaves the map empty.
	var nm := make_navmesh()
	var src := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(nm, src, world_root)
	NavigationServer3D.bake_from_source_geometry_data(nm, src)
	nav_region.navigation_mesh = nm
	# Let the server merge the updated region into the map before any query.
	for _i in 3:
		await get_tree().physics_frame
	NavigationServer3D.map_force_update(world_root.get_world_3d().navigation_map)
	checks["navmesh_baked"] = true
	return _ok({ "navmesh_baked": true, "polygons": nm.get_polygon_count() })


func _setup_navigation() -> void:
	# Persistent navigation region, created once and registered with the map for
	# the whole session. The map cell size MUST match the navmesh's or the
	# region won't merge into the map and pathfinding silently returns nothing.
	nav_region = NavigationRegion3D.new()
	nav_region.name = "NavRegion"
	nav_region.navigation_mesh = make_navmesh()
	world_root.add_child(nav_region)
	var map: RID = world_root.get_world_3d().navigation_map
	NavigationServer3D.map_set_cell_size(map, 0.1)
	NavigationServer3D.map_set_cell_height(map, 0.1)


func _make_ground(size: float) -> void:
	var body := StaticBody3D.new()
	body.name = "Ground"
	var mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(size, size)
	mesh.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.32, 0.34, 0.36)
	mesh.material_override = mat
	body.add_child(mesh)
	var col := CollisionShape3D.new()
	col.shape = WorldBoundaryShape3D.new()
	body.add_child(col)
	world_root.add_child(body)


func _make_reference(height_m: float) -> void:
	var node := _new_capsule(height_m, 0.3, Color(0.85, 0.55, 0.2))
	node.position = Vector3(2.0, height_m * 0.5, 0.0)
	reference_id = register(node, "reference", "capsule")


## Objects are StaticBody3D (mesh + collider) so raycast/snap/drop can hit them.
func _new_box(color: Color, size := Vector3.ONE) -> StaticBody3D:
	var body := StaticBody3D.new()
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = _solid_mat(color)
	body.add_child(mi)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	body.add_child(col)
	return body


func _new_capsule(height_m: float, radius: float, color: Color) -> StaticBody3D:
	var body := StaticBody3D.new()
	var mi := MeshInstance3D.new()
	var cm := CapsuleMesh.new()
	cm.radius = radius
	cm.height = height_m
	mi.mesh = cm
	mi.material_override = _solid_mat(color)
	body.add_child(mi)
	var col := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = radius
	shape.height = height_m
	col.shape = shape
	body.add_child(col)
	return body


func _solid_mat(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	return mat


func _next_id(prefix: String) -> String:
	var n := int(_id_counters.get(prefix, 0)) + 1
	_id_counters[prefix] = n
	return "%s_%d" % [prefix, n]


# ---------------------------------------------------------------------------
# Cameras / viewports
# ---------------------------------------------------------------------------
func _build_viewports() -> void:
	# Live camera for the on-screen window so a human can watch the agent
	# build. The capture cameras live in off-screen SubViewports below;
	# without this the main window would render an empty background.
	var live_cam := Camera3D.new()
	live_cam.name = "LiveCamera"
	live_cam.fov = 60.0
	live_cam.look_at_from_position(Vector3(16, 12, 16), Vector3(0, 1, 0), Vector3.UP)
	live_cam.far = 500.0
	live_cam.current = true
	world_root.add_child(live_cam)

	# Top-down orthographic — the agent's primary "map" view (grid enabled).
	top_camera = Camera3D.new()
	top_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	top_camera.size = 50.0
	top_camera.position = Vector3(0, 40, 0)
	# Look straight down -Y; up is -Z so +X is screen-right, +Z is screen-down.
	top_camera.look_at_from_position(Vector3(0, 40, 0), Vector3.ZERO, Vector3(0, 0, -1))
	top_camera.far = 200.0
	top_viewport = _add_view("top", TOP_VIEW_SIZE, top_camera, true)

	# Perspective 3/4 view.
	persp_camera = Camera3D.new()
	persp_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	persp_camera.fov = 60.0
	persp_camera.look_at_from_position(Vector3(12, 8, 12), Vector3(0, 1, 0), Vector3.UP)
	persp_camera.far = 500.0
	persp_viewport = _add_view("persp", PERSP_VIEW_SIZE, persp_camera, false)

	# Side orthographic elevation (looking along -X): Y up, Z across.
	side_camera = Camera3D.new()
	side_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	side_camera.size = 50.0
	side_camera.look_at_from_position(Vector3(50, 0, 0), Vector3.ZERO, Vector3.UP)
	side_camera.far = 200.0
	side_viewport = _add_view("side", TOP_VIEW_SIZE, side_camera, false)


## Build a SubViewport with a capture camera and an annotation overlay Control.
func _add_view(name: String, size: Vector2i, cam: Camera3D, with_grid: bool) -> SubViewport:
	var vp := SubViewport.new()
	vp.size = size
	vp.own_world_3d = false
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(vp)
	vp.add_child(cam)
	var overlay = preload("res://tools/overlay.gd").new()
	vp.add_child(overlay)
	overlay.setup(self, cam, name, with_grid)
	_views[name] = { "vp": vp, "cam": cam, "overlay": overlay }
	return vp


# ---------------------------------------------------------------------------
# Perception: render canonical views to PNG
# ---------------------------------------------------------------------------
## Render each requested view twice: a clean (un-annotated) PNG and an
## annotated PNG with the overlay baked in. Diff-highlights objects whose
## transform changed since the previous render.
func render_all(views := ["top", "persp", "side"]) -> void:
	_compute_changed_ids()
	for name in views:
		if not _views.has(name):
			continue
		var v: Dictionary = _views[name]
		var vp: SubViewport = v["vp"]
		var overlay = v["overlay"]
		# Clean pass.
		overlay.visible = false
		vp.render_target_update_mode = SubViewport.UPDATE_ONCE
		await RenderingServer.frame_post_draw
		_save_png(vp, "%s/%s_clean.png" % [DIR_RENDERS, name])
		# Annotated pass.
		overlay.visible = true
		overlay.queue_redraw()
		vp.render_target_update_mode = SubViewport.UPDATE_ONCE
		await RenderingServer.frame_post_draw
		_save_png(vp, "%s/%s.png" % [DIR_RENDERS, name])
	_snapshot_xforms()


func _compute_changed_ids() -> void:
	changed_ids = []
	for id in registry.keys():
		var xf: Transform3D = registry[id]["node"].global_transform
		if not _last_render_xforms.has(id) or not _last_render_xforms[id].is_equal_approx(xf):
			changed_ids.append(id)


func _snapshot_xforms() -> void:
	_last_render_xforms.clear()
	for id in registry.keys():
		_last_render_xforms[id] = registry[id]["node"].global_transform


func _save_png(vp: SubViewport, res_path: String) -> void:
	var img := vp.get_texture().get_image()
	var abs_path := ProjectSettings.globalize_path(res_path)
	var tmp := abs_path + ".tmp"
	if img.save_png(tmp) != OK:
		push_error("save_png failed: " + res_path)
		return
	DirAccess.rename_absolute(tmp, abs_path)


# ---------------------------------------------------------------------------
# State dump (spec §5)
# ---------------------------------------------------------------------------
func dump_state() -> void:
	tick += 1
	var objects := []
	for id in registry.keys():
		objects.append(_serialize_object(id))
	var state := {
		"tick": tick,
		"units": "meters",
		"axes": "Y-up, -Z forward, right-handed",
		"selection": selection,
		"objects": objects,
		"cameras": {
			"top": { "projection": "ortho", "position": _v3(top_camera.global_position), "size": top_camera.size },
			"persp": { "projection": "perspective", "position": _v3(persp_camera.global_position), "fov": persp_camera.fov },
			"side": { "projection": "ortho", "position": _v3(side_camera.global_position), "size": side_camera.size },
		},
		"reference": { "id": reference_id, "height_m": reference_height_m },
		"checks": checks,
	}
	_write_json_atomic(PATH_STATE, state)


func _serialize_object(id: String) -> Dictionary:
	var entry: Dictionary = registry[id]
	var node: Node3D = entry["node"]
	var xf := node.global_transform
	var aabb := _world_aabb(node)
	return {
		"id": id, "type": entry["type"], "asset": entry["asset"],
		"position": _v3(xf.origin),
		"rotation_deg": _v3(node.global_rotation_degrees),
		"scale": _v3(node.scale),
		"parent": _parent_id_of(node),
		"aabb_world": { "min": _v3(aabb.position), "max": _v3(aabb.position + aabb.size) },
		"forward": _v3(-xf.basis.z.normalized()),
	}


func _parent_id_of(node: Node3D) -> String:
	var p := node.get_parent()
	if p == world_root or p == null:
		return "root"
	for id in registry.keys():
		if registry[id]["node"] == p:
			return id
	return "root"


func _world_aabb(node: Node3D) -> AABB:
	var mi := node as MeshInstance3D
	if mi == null:
		for c in node.get_children():
			if c is MeshInstance3D:
				mi = c
				break
	if mi == null or mi.mesh == null:
		return AABB(node.global_position, Vector3.ZERO)
	return mi.global_transform * mi.get_aabb()


# ---------------------------------------------------------------------------
# Command-loop file I/O
# ---------------------------------------------------------------------------
func _read_new_complete_lines() -> PackedStringArray:
	var abs_path := ProjectSettings.globalize_path(PATH_COMMANDS)
	if not FileAccess.file_exists(abs_path):
		return PackedStringArray()
	var f := FileAccess.open(abs_path, FileAccess.READ)
	if f == null:
		return PackedStringArray()
	var length := f.get_length()
	if length <= _io_cursor:
		f.close()
		return PackedStringArray()
	f.seek(_io_cursor)
	var buf := f.get_buffer(length - _io_cursor)
	f.close()
	var text := buf.get_string_from_utf8()
	var last_nl := text.rfind("\n")
	if last_nl == -1:
		return PackedStringArray()   # only a partial line so far — wait
	var complete := text.substr(0, last_nl + 1)
	_io_cursor += complete.to_utf8_buffer().size()
	return complete.split("\n", false)


func _append_result(d: Dictionary) -> void:
	_results_lines.append(JSON.stringify(d))

func _flush_results() -> void:
	_write_lines_atomic(PATH_RESULTS, _results_lines)

func _append_build_log(d: Dictionary) -> void:
	_build_log_lines.append(JSON.stringify(d))

func _flush_build_log() -> void:
	if not _build_log_lines.is_empty():
		_write_lines_atomic(PATH_BUILD_LOG, _build_log_lines)

func _persist_last_seq() -> void:
	var f := FileAccess.open(ProjectSettings.globalize_path(PATH_LAST_SEQ), FileAccess.WRITE)
	if f:
		f.store_string(str(last_seq))
		f.close()


# ---------------------------------------------------------------------------
# Startup / persistence
# ---------------------------------------------------------------------------
func _ensure_dirs() -> void:
	for d in [DIR_IO, DIR_RENDERS, DIR_CHECKPOINTS]:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(d))

func _load_persisted() -> void:
	# Restore last_seq so a restart never re-runs old commands.
	var seq_path := ProjectSettings.globalize_path(PATH_LAST_SEQ)
	if FileAccess.file_exists(seq_path):
		last_seq = int(FileAccess.get_file_as_string(seq_path).strip_edges())
	# Preserve prior results/build-log history across restarts.
	var res_path := ProjectSettings.globalize_path(PATH_RESULTS)
	if FileAccess.file_exists(res_path):
		for ln in FileAccess.get_file_as_string(res_path).split("\n", false):
			_results_lines.append(ln)
	var log_path := ProjectSettings.globalize_path(PATH_BUILD_LOG)
	if FileAccess.file_exists(log_path):
		for ln in FileAccess.get_file_as_string(log_path).split("\n", false):
			_build_log_lines.append(ln)
	# Ensure a commands file exists so the agent can append immediately.
	var cmd_path := ProjectSettings.globalize_path(PATH_COMMANDS)
	if not FileAccess.file_exists(cmd_path):
		var f := FileAccess.open(cmd_path, FileAccess.WRITE)
		if f: f.close()


# ---------------------------------------------------------------------------
# Result helpers & low-level writers
# ---------------------------------------------------------------------------
const MUTATING_CMDS := [
	"spawn", "delete", "move", "rotate", "scale_obj", "align", "distribute",
	"duplicate", "array", "group", "parent", "snap", "gravity_drop",
	"resolve_overlap", "add_reference", "make_room", "make_corridor",
	"make_stairs", "make_opening", "restore",
]
func _is_mutating(cmd: String) -> bool:
	return cmd in MUTATING_CMDS

func _ok(result = null) -> Dictionary:
	return { "ok": true, "result": result, "error": null }

func _err(msg: String) -> Dictionary:
	return { "ok": false, "result": null, "error": msg }

func to_vec3(v, fallback := Vector3.ZERO) -> Vector3:
	if typeof(v) == TYPE_ARRAY and v.size() >= 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return fallback

func _v3(v: Vector3) -> Array:
	return [snappedf(v.x, 0.001), snappedf(v.y, 0.001), snappedf(v.z, 0.001)]

func _write_json_atomic(res_path: String, data) -> void:
	_write_text_atomic(res_path, JSON.stringify(data, "  "))

func _write_lines_atomic(res_path: String, lines: PackedStringArray) -> void:
	var text := "\n".join(lines)
	if not lines.is_empty():
		text += "\n"
	_write_text_atomic(res_path, text)

func _write_text_atomic(res_path: String, text: String) -> void:
	var abs_path := ProjectSettings.globalize_path(res_path)
	var tmp := abs_path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("cannot write " + tmp)
		return
	f.store_string(text)
	f.close()
	DirAccess.rename_absolute(tmp, abs_path)
