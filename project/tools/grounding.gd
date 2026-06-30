extends RefCounted
## Grounding tool group (spec §7b) — the precision substitutes.
##
## These replace open-loop coordinate guessing with snapped / relative / probed
## operations: point at a screenshot pixel and hit geometry, snap to a grid,
## drop onto the surface below, measure exact distances, resolve overlaps.
## All spatial answers come from physics queries or the scene graph — never
## from pixels (design principle #2).

var ed

func _init(editor) -> void:
	ed = editor


# raycast_screen {camera, screen:[x,y]} -> {point, normal, hit_id}
func raycast_screen(args: Dictionary) -> Dictionary:
	var cam_name := str(args.get("camera", "persp"))
	var cam: Camera3D = ed.camera_by_name(cam_name)
	if not args.has("screen"):
		return ed._err("raycast_screen requires screen:[x,y]")
	var screen: Vector2 = _vec2(args["screen"])
	var hit := _ray_from_screen(cam, screen, [])
	if hit.is_empty():
		return ed._ok({ "point": null, "normal": null, "hit_id": null })
	return ed._ok({
		"point": ed._v3(hit["position"]),
		"normal": ed._v3(hit["normal"]),
		"hit_id": ed.id_for_collider(hit["collider"]),
	})


# select_by_ray {camera, screen:[x,y]} -> selects the object under that pixel
func select_by_ray(args: Dictionary) -> Dictionary:
	var res := raycast_screen(args)
	if not res.get("ok", false):
		return res
	var hit_id = res["result"]["hit_id"]
	if hit_id == null or str(hit_id) == "":
		return ed._ok({ "selection": ed.selection, "hit_id": null })
	return ed.actions.select({ "ids": [hit_id] })


# snap {ids, mode:"grid"|"surface"|"edge", grid?}
func snap(args: Dictionary) -> Dictionary:
	var ids: Array = ed.ids_arg(args)
	if ids.is_empty():
		return ed._err("snap requires ids")
	var mode := str(args.get("mode", "grid"))
	var grid := float(args.get("grid", 1.0))
	var out := []
	for id in ids:
		var sid := str(id)
		var node = ed.get_obj(sid)
		if node == null:
			continue
		match mode:
			"grid":
				var p: Vector3 = node.global_position
				node.global_position = Vector3(
					snappedf(p.x, grid), p.y, snappedf(p.z, grid))
			"surface":
				_drop_to_surface(sid, node)
			"edge":
				# Edge/vertex align approximated as grid-snap on a fine grid.
				var p2: Vector3 = node.global_position
				node.global_position = Vector3(
					snappedf(p2.x, grid), snappedf(p2.y, grid), snappedf(p2.z, grid))
			_:
				return ed._err("unknown snap mode: " + mode)
		out.append({ "id": sid, "position": ed._v3(node.global_position) })
	return ed._ok({ "snapped": out })


# gravity_drop {ids} — raycast down, rest each object on the first surface below
func gravity_drop(args: Dictionary) -> Dictionary:
	var ids: Array = ed.ids_arg(args)
	if ids.is_empty():
		return ed._err("gravity_drop requires ids")
	var out := []
	for id in ids:
		var sid := str(id)
		var node = ed.get_obj(sid)
		if node == null:
			continue
		var landed := _drop_to_surface(sid, node)
		out.append({ "id": sid, "position": ed._v3(node.global_position), "landed": landed })
	return ed._ok({ "dropped": out })


# overlap_query {id} -> intersecting object ids (AABB test)
func overlap_query(args: Dictionary) -> Dictionary:
	var id := str(args.get("id", ""))
	if not ed.has_obj(id):
		return ed._err("unknown id: " + id)
	return ed._ok({ "id": id, "overlaps": _overlapping_ids(id) })


# resolve_overlap {ids} — push each out along the minimal-penetration axis
func resolve_overlap(args: Dictionary) -> Dictionary:
	var ids: Array = ed.ids_arg(args)
	if ids.is_empty():
		return ed._err("resolve_overlap requires ids")
	var out := []
	for id in ids:
		var sid := str(id)
		if not ed.has_obj(sid):
			continue
		var moved := _push_out(sid)
		out.append({ "id": sid, "position": ed._v3(ed.get_obj(sid).global_position), "pushed": moved })
	return ed._ok({ "resolved": out })


# measure {from_id?|from_point?, to_id?|to_point?} or {ray:{origin,dir}}
func measure(args: Dictionary) -> Dictionary:
	if args.has("ray"):
		var r: Dictionary = args["ray"]
		var origin: Vector3 = ed.to_vec3(r.get("origin", null), Vector3.ZERO)
		var dir: Vector3 = ed.to_vec3(r.get("dir", null), Vector3.DOWN)
		dir = dir.normalized()
		var hit := _ray(origin, origin + dir * 1000.0, [])
		if hit.is_empty():
			return ed._ok({ "hit": false, "distance": null })
		return ed._ok({
			"hit": true, "distance": snappedf(origin.distance_to(hit["position"]), 0.001),
			"point": ed._v3(hit["position"]), "hit_id": ed.id_for_collider(hit["collider"]),
		})
	var a = _measure_point(args, "from")
	var b = _measure_point(args, "to")
	if a == null or b == null:
		return ed._err("measure needs from_id/from_point and to_id/to_point (or a ray)")
	var center_dist: float = (a as Vector3).distance_to(b)
	# Surface gap between AABBs when both endpoints are objects.
	var gap = null
	if args.has("from_id") and args.has("to_id"):
		gap = _aabb_gap(str(args["from_id"]), str(args["to_id"]))
	return ed._ok({
		"distance": snappedf(center_dist, 0.001),
		"gap": (snappedf(gap, 0.001) if gap != null else null),
		"from": ed._v3(a), "to": ed._v3(b),
	})


# add_reference {height_m, at?} — humanoid capsule for scale calibration
func add_reference(args: Dictionary) -> Dictionary:
	var h := float(args.get("height_m", 1.8))
	var node: Node3D = ed.spawn_asset("capsule", "reference")
	node.position = ed.resolve_position(args, Vector3(0, h * 0.5, 0))
	node.position.y = h * 0.5
	var id: String = ed.register(node, "reference", "capsule")
	ed.reference_id = id
	ed.reference_height_m = h
	return ed._ok({ "id": id, "height_m": h, "position": ed._v3(node.position) })


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------
func _ray_from_screen(cam: Camera3D, screen: Vector2, exclude: Array) -> Dictionary:
	var origin := cam.project_ray_origin(screen)
	var dir := cam.project_ray_normal(screen)
	return _ray(origin, origin + dir * 1000.0, exclude)


func _ray(from: Vector3, to: Vector3, exclude: Array) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collide_with_areas = false
	q.collide_with_bodies = true
	if not exclude.is_empty():
		q.exclude = exclude
	return ed.space_state().intersect_ray(q)


## Drop a node straight down so the bottom of its AABB rests on the first
## surface below. Returns true if a surface was found.
func _drop_to_surface(id: String, node: Node3D) -> bool:
	var aabb: AABB = ed.aabb_of(id)
	var bottom_y := aabb.position.y
	var center := node.global_position
	# Cast from a little above current position downward, excluding self.
	var from := Vector3(center.x, aabb.position.y + aabb.size.y + 0.05, center.z)
	var hit := _ray(from, from + Vector3.DOWN * 1000.0, [ed.body_rid(id)])
	if hit.is_empty():
		# Fallback: rest on ground plane y=0.
		var half_h := node.global_position.y - bottom_y
		node.global_position.y = half_h
		return false
	var surface_y: float = hit["position"].y
	var half_height := center.y - bottom_y    # center-to-bottom offset
	node.global_position.y = surface_y + half_height
	return true


func _overlapping_ids(id: String) -> Array:
	var a: AABB = ed.aabb_of(id)
	var out := []
	for other in ed.registry.keys():
		if other == id:
			continue
		if ed.registry[other]["type"] == "reference":
			pass  # references still count; keep them
		var b: AABB = ed.aabb_of(other)
		if a.intersects(b):
			out.append(other)
	return out


func _push_out(id: String) -> bool:
	var overlaps := _overlapping_ids(id)
	if overlaps.is_empty():
		return false
	var node: Node3D = ed.get_obj(id)
	for other in overlaps:
		var a: AABB = ed.aabb_of(id)
		var b: AABB = ed.aabb_of(other)
		var inter := a.intersection(b)
		if inter.size == Vector3.ZERO:
			continue
		# Smallest overlap extent → push along that axis, away from other.
		var s := inter.size
		var axis := 0
		if s.y < s.x and s.y <= s.z: axis = 1
		elif s.z < s.x and s.z < s.y: axis = 2
		var ca := a.position + a.size * 0.5
		var cb := b.position + b.size * 0.5
		var sign := 1.0 if ca[axis] >= cb[axis] else -1.0
		var delta := Vector3.ZERO
		delta[axis] = (s[axis] + 0.001) * sign
		node.global_position += delta
	return true


func _measure_point(args: Dictionary, which: String):
	if args.has(which + "_id"):
		var id := str(args[which + "_id"])
		if ed.has_obj(id):
			return ed.get_obj(id).global_position
		return null
	if args.has(which + "_point"):
		return ed.to_vec3(args[which + "_point"], Vector3.ZERO)
	return null


func _aabb_gap(id_a: String, id_b: String):
	if not (ed.has_obj(id_a) and ed.has_obj(id_b)):
		return null
	var a: AABB = ed.aabb_of(id_a)
	var b: AABB = ed.aabb_of(id_b)
	if a.intersects(b):
		return 0.0
	# Per-axis separation; gap is the Euclidean distance between the boxes.
	var dx := maxf(0.0, maxf(a.position.x - (b.position.x + b.size.x), b.position.x - (a.position.x + a.size.x)))
	var dy := maxf(0.0, maxf(a.position.y - (b.position.y + b.size.y), b.position.y - (a.position.y + a.size.y)))
	var dz := maxf(0.0, maxf(a.position.z - (b.position.z + b.size.z), b.position.z - (a.position.z + a.size.z)))
	return Vector3(dx, dy, dz).length()


func _vec2(v) -> Vector2:
	if typeof(v) == TYPE_ARRAY and v.size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	return Vector2.ZERO
