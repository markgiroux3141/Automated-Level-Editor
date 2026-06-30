extends RefCounted
## Parametric generator tool group (spec §7c) — collapse many placements into
## one intent. make_room, make_corridor, make_stairs, make_opening.
##
## All produce StaticBody3D boxes (floor/wall/step) grouped under a single
## group node so the agent can move/delete the whole structure as a unit.

var ed

func _init(editor) -> void:
	ed = editor


# make_room {origin, width, length, height, wall_thickness?}
# origin = center of the room floor (y=0). width=X extent, length=Z extent.
func make_room(args: Dictionary) -> Dictionary:
	var origin: Vector3 = ed.to_vec3(args.get("origin", null), Vector3.ZERO)
	var w := float(args.get("width", 6.0))
	var l := float(args.get("length", 6.0))
	var h := float(args.get("height", 3.0))
	var t := float(args.get("wall_thickness", 0.2))
	var parts := []

	# Floor (thin slab just below y=0 so its top sits at the ground plane).
	parts.append(ed.add_box(Vector3(w, t, l), origin + Vector3(0, -t * 0.5, 0), "floor", "box", Color(0.4, 0.42, 0.45)))
	# Walls (centered at half height). North/South span X; East/West span Z.
	var hy := origin.y + h * 0.5
	parts.append(ed.add_box(Vector3(w + t, h, t), Vector3(origin.x, hy, origin.z - l * 0.5), "wall"))  # north (-Z)
	parts.append(ed.add_box(Vector3(w + t, h, t), Vector3(origin.x, hy, origin.z + l * 0.5), "wall"))  # south (+Z)
	parts.append(ed.add_box(Vector3(t, h, l - t), Vector3(origin.x + w * 0.5, hy, origin.z), "wall"))  # east (+X)
	parts.append(ed.add_box(Vector3(t, h, l - t), Vector3(origin.x - w * 0.5, hy, origin.z), "wall"))  # west (-X)

	var gid: String = ed.make_group(parts, "room")
	return ed._ok({ "room": gid, "parts": parts,
		"walls": { "north": parts[1], "south": parts[2], "east": parts[3], "west": parts[4] },
		"floor": parts[0] })


# make_corridor {from_point, to_point, width, height}
func make_corridor(args: Dictionary) -> Dictionary:
	var a: Vector3 = ed.to_vec3(args.get("from_point", null), Vector3.ZERO)
	var b: Vector3 = ed.to_vec3(args.get("to_point", null), Vector3.ZERO)
	var width := float(args.get("width", 2.0))
	var h := float(args.get("height", 3.0))
	var t := float(args.get("wall_thickness", 0.2))
	a.y = 0.0
	b.y = 0.0
	var mid := (a + b) * 0.5
	var length: float = a.distance_to(b)
	var dir := (b - a).normalized() if length > 0.001 else Vector3(0, 0, -1)
	var angle := atan2(dir.x, dir.z)    # yaw so local -Z aligns with dir
	var parts := []

	# Floor abuts the adjoining room floors (shared edge, coplanar at y=0) so
	# Recast merges the seam into one walkable region. (Overlapping floors
	# create degenerate double-surfaces that split the navmesh at the door.)
	var floor_id: String = ed.add_box(Vector3(width, t, length), mid + Vector3(0, -t * 0.5, 0), "floor", "box", Color(0.4, 0.42, 0.45))
	ed.get_obj(floor_id).rotation.y = angle
	parts.append(floor_id)
	# Side walls inset by the wall thickness so they don't clip the door jambs.
	var perp := Vector3(dir.z, 0, -dir.x)   # right-hand perpendicular
	var wall_len: float = maxf(0.1, length - t * 2.0)
	for s in [1.0, -1.0]:
		var wid: String = ed.add_box(Vector3(t, h, wall_len), mid + perp * (width * 0.5 * s) + Vector3(0, h * 0.5, 0), "wall")
		ed.get_obj(wid).rotation.y = angle
		parts.append(wid)
	var gid: String = ed.make_group(parts, "corridor")
	return ed._ok({ "corridor": gid, "parts": parts, "floor": floor_id, "length": snappedf(length, 0.001) })


# make_stairs {origin, steps, step_w, step_h, step_d, direction}
func make_stairs(args: Dictionary) -> Dictionary:
	var origin: Vector3 = ed.to_vec3(args.get("origin", null), Vector3.ZERO)
	var steps := int(args.get("steps", 5))
	var sw := float(args.get("step_w", 2.0))
	var sh := float(args.get("step_h", 0.2))
	var sd := float(args.get("step_d", 0.3))
	var dir := _direction_vec(args.get("direction", "north"))
	var parts := []
	for i in steps:
		var pos := origin + dir * (sd * (i + 0.5)) + Vector3(0, sh * (i + 0.5), 0)
		# Step depth runs along dir, width across it.
		var across := Vector3(absf(dir.z), 0, absf(dir.x))
		var size := Vector3(
			sw * across.x + sd * absf(dir.x),
			sh,
			sw * across.z + sd * absf(dir.z))
		parts.append(ed.add_box(size, pos, "step", "box", Color(0.5, 0.5, 0.55)))
	var gid: String = ed.make_group(parts, "stairs")
	return ed._ok({ "stairs": gid, "parts": parts, "rise": snappedf(sh * steps, 0.001) })


# make_opening {wall_id, center, width, height} — cut a door/window in a wall
# by replacing the wall box with segments around the opening (door = to floor).
func make_opening(args: Dictionary) -> Dictionary:
	var wall_id := str(args.get("wall_id", ""))
	if not ed.has_obj(wall_id):
		return ed._err("unknown wall_id: " + wall_id)
	var box: AABB = ed.aabb_of(wall_id)
	var ow := float(args.get("width", 1.0))
	var oh := float(args.get("height", 2.1))
	var center: Vector3 = ed.to_vec3(args.get("center", null), box.position + box.size * 0.5)

	# Long horizontal axis of the wall (X or Z).
	var span_axis := 0 if box.size.x >= box.size.z else 2
	var thick_axis := 2 if span_axis == 0 else 0
	var wall_lo: float = box.position[span_axis]
	var wall_hi: float = wall_lo + box.size[span_axis]
	var wall_top: float = box.position.y + box.size.y
	var wall_bottom: float = box.position.y
	var thickness: float = box.size[thick_axis]
	var thick_center: float = box.position[thick_axis] + thickness * 0.5
	var op_lo: float = center[span_axis] - ow * 0.5
	var op_hi: float = center[span_axis] + ow * 0.5
	op_lo = maxf(op_lo, wall_lo)
	op_hi = minf(op_hi, wall_hi)

	var typ: String = ed.registry[wall_id]["type"]
	var parts := []

	# Side segment builder along the span axis.
	var make_seg := func(lo: float, hi: float, y_lo: float, y_hi: float) -> String:
		if hi - lo <= 0.001 or y_hi - y_lo <= 0.001:
			return ""
		var size := Vector3.ZERO
		size[span_axis] = hi - lo
		size[thick_axis] = thickness
		size.y = y_hi - y_lo
		var pos := Vector3.ZERO
		pos[span_axis] = (lo + hi) * 0.5
		pos[thick_axis] = thick_center
		pos.y = (y_lo + y_hi) * 0.5
		return ed.add_box(size, pos, typ, "box")

	var left: String = make_seg.call(wall_lo, op_lo, wall_bottom, wall_top)
	var right: String = make_seg.call(op_hi, wall_hi, wall_bottom, wall_top)
	var op_top: float = minf(wall_bottom + oh, wall_top)
	var lintel: String = make_seg.call(op_lo, op_hi, op_top, wall_top)
	for p in [left, right, lintel]:
		if p != "":
			parts.append(p)

	ed.remove_obj(wall_id)
	return ed._ok({ "removed": wall_id, "parts": parts, "opening_center": ed._v3(center) })


func _direction_vec(d) -> Vector3:
	if typeof(d) == TYPE_ARRAY:
		return ed.to_vec3(d, Vector3(0, 0, -1)).normalized()
	match str(d):
		"north": return Vector3(0, 0, -1)
		"south": return Vector3(0, 0, 1)
		"east": return Vector3(1, 0, 0)
		"west": return Vector3(-1, 0, 0)
		_: return Vector3(0, 0, -1)
