extends RefCounted
## Verification tool group (spec §7e, §8) — converts "is the level correct?"
## (a perception problem the LLM is weak at) into pass/fail tests it consumes
## well. All results are written into ed.checks, which dump_state mirrors into
## state.checks so the agent reads outcomes instead of eyeballing pixels.

var ed

const NAV_GROUP := "navsource"          # static geometry parsed for the navmesh
const FLOAT_EPS := 0.06                 # gap above support that counts as floating
const OVERLAP_EPS := 0.02               # min penetration on all axes to flag

func _init(editor) -> void:
	ed = editor


# check_support {} -> floating object ids
func check_support(_args: Dictionary) -> Dictionary:
	var floaters := []
	for id in ed.registry.keys():
		if not _is_physical(id):
			continue
		var box: AABB = ed.aabb_of(id)
		if box.size == Vector3.ZERO:
			continue
		var bottom_y: float = box.position.y
		var center := box.position + box.size * 0.5
		var from := Vector3(center.x, bottom_y + 0.02, center.z)
		var hit: Dictionary = ed.space_state().intersect_ray(_down_query(from, [ed.body_rid(id)]))
		var gap: float
		if hit.is_empty():
			gap = bottom_y       # nothing below → distance to y=0 reference
		else:
			gap = bottom_y - hit["position"].y
		# Floating only if nothing supports it from below AND it isn't held by
		# adjacent geometry (e.g. a door lintel resting on its jambs).
		if gap > FLOAT_EPS and not _touches_solid(id):
			floaters.append({ "id": id, "gap": snappedf(gap, 0.001) })
	ed.checks["floaters"] = floaters
	return ed._ok({ "floaters": floaters })


## True if this object's (slightly grown) AABB touches another physical object.
func _touches_solid(id: String) -> bool:
	var a: AABB = ed.aabb_of(id).grow(0.05)
	for other in ed.registry.keys():
		if other == id or not _is_physical(other):
			continue
		if a.intersects(ed.aabb_of(other)):
			return true
	return false


# check_overlaps {} -> interpenetrating pairs
func check_overlaps(_args: Dictionary) -> Dictionary:
	var ids := _physical_ids()
	var pairs := []
	for i in ids.size():
		for j in range(i + 1, ids.size()):
			# Overlapping floor slabs are intentional (navmesh continuity).
			if ed.registry[ids[i]]["type"] == "floor" and ed.registry[ids[j]]["type"] == "floor":
				continue
			var a: AABB = ed.aabb_of(ids[i])
			var b: AABB = ed.aabb_of(ids[j])
			var inter := a.intersection(b)
			if inter.size.x > OVERLAP_EPS and inter.size.y > OVERLAP_EPS and inter.size.z > OVERLAP_EPS:
				pairs.append({ "a": ids[i], "b": ids[j], "penetration": ed._v3(inter.size) })
	ed.checks["overlaps"] = pairs
	return ed._ok({ "overlaps": pairs })


# check_scale {} -> objects implausibly sized vs the reference
func check_scale(_args: Dictionary) -> Dictionary:
	var ref_h: float = ed.reference_height_m
	var warns := []
	for id in ed.registry.keys():
		if not _is_physical(id):
			continue
		var box: AABB = ed.aabb_of(id)
		var s := box.size
		if s == Vector3.ZERO:
			continue
		var reason := ""
		var biggest: float = maxf(s.x, maxf(s.y, s.z))
		var smallest: float = minf(s.x, minf(s.y, s.z))
		if smallest < 0.05:
			reason = "degenerate (%.3f m thin)" % smallest
		elif biggest > 40.0:
			reason = "huge (%.1f m)" % biggest
		elif s.y > ref_h * 4.0:
			reason = "very tall (%.1f m vs ref %.1f m)" % [s.y, ref_h]
		if reason != "":
			warns.append({ "id": id, "size": ed._v3(s), "reason": reason })
	ed.checks["scale_warnings"] = warns
	return ed._ok({ "scale_warnings": warns })


# bake_navmesh is handled by main._do_bake (a coroutine — reliable runtime
# (re)baking must straddle physics frames). See main.gd.


# check_reachable {from_point, to_point}
func check_reachable(args: Dictionary) -> Dictionary:
	var from: Vector3 = ed.to_vec3(args.get("from_point", null), Vector3.ZERO)
	var to: Vector3 = ed.to_vec3(args.get("to_point", null), Vector3.ZERO)
	var map: RID = ed.world_root.get_world_3d().navigation_map
	var path: PackedVector3Array = NavigationServer3D.map_get_path(map, from, to, true)
	var reachable := false
	var truncated := false
	var end_point = null
	if path.size() >= 2:
		var end := path[path.size() - 1]
		end_point = ed._v3(end)
		var horiz := Vector2(end.x - to.x, end.z - to.z).length()
		reachable = horiz < 1.0
		truncated = not reachable
	var result := {
		"from": ed._v3(from), "to": ed._v3(to),
		"reachable": reachable, "truncated": truncated,
		"path_points": path.size(), "end_point": end_point,
	}
	ed.checks["reachability"] = result
	return ed._ok(result)


# physics_settle {ids?, steps?} — stability probe: how far each object floats
# above its support (real rigidbody sim is out of scope; static geometry would
# not move). Large values flag holes / unstable placement.
func physics_settle(args: Dictionary) -> Dictionary:
	var ids: Array = ed.ids_arg(args)
	if ids.is_empty():
		ids = _physical_ids()
	var report := []
	var max_move := 0.0
	for id in ids:
		var sid := str(id)
		if not ed.has_obj(sid):
			continue
		var box: AABB = ed.aabb_of(sid)
		var center := box.position + box.size * 0.5
		var from := Vector3(center.x, box.position.y + 0.02, center.z)
		var hit: Dictionary = ed.space_state().intersect_ray(_down_query(from, [ed.body_rid(sid)]))
		var drop: float = (box.position.y - hit["position"].y) if not hit.is_empty() else box.position.y
		drop = maxf(drop, 0.0)
		max_move = maxf(max_move, drop)
		report.append({ "id": sid, "would_settle": snappedf(drop, 0.001) })
	return ed._ok({ "settled": report, "max_movement": snappedf(max_move, 0.001) })


# set_goal_checklist {items: [string]}
func set_goal_checklist(args: Dictionary) -> Dictionary:
	var items = args.get("items", [])
	var list := []
	for it in items:
		list.append({ "text": str(it), "passed": null, "evidence": "" })
	ed.checks["goal_checklist"] = list
	return ed._ok({ "goal_checklist": list })


# check_goal {index, passed, evidence?}
func check_goal(args: Dictionary) -> Dictionary:
	var idx := int(args.get("index", -1))
	var list: Array = ed.checks["goal_checklist"]
	if idx < 0 or idx >= list.size():
		return ed._err("goal index out of range: %d" % idx)
	list[idx]["passed"] = bool(args.get("passed", false))
	list[idx]["evidence"] = str(args.get("evidence", ""))
	return ed._ok({ "index": idx, "item": list[idx] })


# ---------------------------------------------------------------------------
func _is_physical(id: String) -> bool:
	var t: String = ed.registry[id]["type"]
	return t in ["crate", "wall", "floor", "step", "reference"]

func _physical_ids() -> Array:
	var out := []
	for id in ed.registry.keys():
		if _is_physical(id):
			out.append(id)
	return out

func _down_query(from: Vector3, exclude: Array) -> PhysicsRayQueryParameters3D:
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 1000.0)
	q.exclude = exclude
	return q
