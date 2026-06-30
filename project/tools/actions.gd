extends RefCounted
## Action tool group (spec §7a) — spawning & transform.
##
## Each handler takes the command's `args` Dictionary and returns the standard
## result envelope { ok, result, error }. Spatial intent is expressed
## relatively wherever possible (rel_to/offset, by) per design principle #1;
## absolute placement (at/to) is the fallback.
##
## Phase 1 implements: spawn, delete, select, deselect, move.
## rotate/scale/align/etc. arrive in Phase 4 (added here as the catalog grows).

var ed   # the main editor Node (primitive API)

func _init(editor) -> void:
	ed = editor


# spawn {asset, at?|rel_to?+offset?, rotation_deg?, scale?, type?}
func spawn(args: Dictionary) -> Dictionary:
	var asset := str(args.get("asset", "box"))
	var type := str(args.get("type", ""))
	var node: Node3D = ed.spawn_asset(asset, type)
	if node == null:
		return ed._err("could not create asset '%s'" % asset)

	node.position = ed.resolve_position(args, Vector3.ZERO)
	if args.has("rotation_deg"):
		node.rotation_degrees = ed.to_vec3(args["rotation_deg"], Vector3.ZERO)
	if args.has("scale"):
		node.scale = ed.to_vec3(args["scale"], Vector3.ONE)

	var resolved_type := type if type != "" else ("crate" if asset == "box" else asset)
	var id: String = ed.register(node, resolved_type, asset)
	return ed._ok({ "id": id, "position": ed._v3(node.position) })


# delete {ids}
func delete(args: Dictionary) -> Dictionary:
	var ids: Array = ed.ids_arg(args)
	var removed := []
	var missing := []
	for id in ids:
		if ed.remove_obj(str(id)):
			removed.append(id)
		else:
			missing.append(id)
	if not missing.is_empty():
		return { "ok": removed.size() > 0, "result": { "deleted": removed }, "error": "unknown ids: %s" % str(missing) }
	return ed._ok({ "deleted": removed })


# select {ids}
func select(args: Dictionary) -> Dictionary:
	var ids: Array = ed.ids_arg(args)
	var missing := []
	for id in ids:
		var sid := str(id)
		if not ed.has_obj(sid):
			missing.append(sid)
		elif not ed.selection.has(sid):
			ed.selection.append(sid)
	if not missing.is_empty():
		return { "ok": false, "result": { "selection": ed.selection }, "error": "unknown ids: %s" % str(missing) }
	return ed._ok({ "selection": ed.selection })


# deselect {ids}
func deselect(args: Dictionary) -> Dictionary:
	for id in ed.ids_arg(args):
		ed.selection.erase(str(id))
	return ed._ok({ "selection": ed.selection })


# move {ids, to?: [x,y,z], by?: [dx,dy,dz], rel_to?+offset?}
func move(args: Dictionary) -> Dictionary:
	var ids: Array = ed.ids_arg(args)
	if ids.is_empty():
		return ed._err("move requires ids")
	var moved := []
	var missing := []
	for id in ids:
		var sid := str(id)
		var node = ed.get_obj(sid)
		if node == null:
			missing.append(sid)
			continue
		if args.has("by"):
			node.global_position += ed.to_vec3(args["by"], Vector3.ZERO)
		elif args.has("rel_to") and ed.has_obj(str(args["rel_to"])):
			node.global_position = ed.get_obj(str(args["rel_to"])).global_position + ed.to_vec3(args.get("offset", null), Vector3.ZERO)
		elif args.has("to"):
			node.global_position = ed.to_vec3(args["to"], node.global_position)
		else:
			return ed._err("move requires one of: by, to, rel_to")
		moved.append({ "id": sid, "position": ed._v3(node.global_position) })
	if not missing.is_empty():
		return { "ok": moved.size() > 0, "result": { "moved": moved }, "error": "unknown ids: %s" % str(missing) }
	return ed._ok({ "moved": moved })


# rotate {ids, by_deg?, to_deg?, face_point?}
func rotate(args: Dictionary) -> Dictionary:
	var ids: Array = ed.ids_arg(args)
	var out := []
	for id in ids:
		var node = ed.get_obj(str(id))
		if node == null:
			continue
		if args.has("face_point"):
			var target: Vector3 = ed.to_vec3(args["face_point"], Vector3.ZERO)
			if not node.global_position.is_equal_approx(target):
				node.look_at(target, Vector3.UP)
		elif args.has("by_deg"):
			node.rotation_degrees += ed.to_vec3(args["by_deg"], Vector3.ZERO)
		elif args.has("to_deg"):
			node.rotation_degrees = ed.to_vec3(args["to_deg"], Vector3.ZERO)
		else:
			return ed._err("rotate requires by_deg, to_deg, or face_point")
		out.append({ "id": str(id), "rotation_deg": ed._v3(node.global_rotation_degrees) })
	return ed._ok({ "rotated": out })


# scale_obj {ids, factor?, to?, to_height_m?}
func scale_obj(args: Dictionary) -> Dictionary:
	var ids: Array = ed.ids_arg(args)
	var out := []
	for id in ids:
		var sid := str(id)
		var node = ed.get_obj(sid)
		if node == null:
			continue
		if args.has("to_height_m"):
			var h: float = ed.aabb_of(sid).size.y
			if h > 0.0001:
				node.scale *= float(args["to_height_m"]) / h
		elif args.has("factor"):
			node.scale *= float(args["factor"])
		elif args.has("to"):
			node.scale = ed.to_vec3(args["to"], node.scale)
		else:
			return ed._err("scale_obj requires factor, to, or to_height_m")
		out.append({ "id": sid, "scale": ed._v3(node.scale) })
	return ed._ok({ "scaled": out })


# align {ids, axis:"x"|"y"|"z", edge:"min"|"max"|"center"} — align to ids[0]
func align(args: Dictionary) -> Dictionary:
	var ids: Array = ed.ids_arg(args)
	if ids.size() < 2:
		return ed._err("align requires >= 2 ids")
	var axis := _axis_index(str(args.get("axis", "x")))
	var edge := str(args.get("edge", "center"))
	var ref_val := _edge_coord(str(ids[0]), axis, edge)
	var out := []
	for i in range(1, ids.size()):
		var sid := str(ids[i])
		var node = ed.get_obj(sid)
		if node == null:
			continue
		var cur := _edge_coord(sid, axis, edge)
		var p: Vector3 = node.global_position
		p[axis] += ref_val - cur
		node.global_position = p
		out.append({ "id": sid, "position": ed._v3(p) })
	return ed._ok({ "aligned": out, "axis": str(args.get("axis", "x")), "edge": edge })


# distribute {ids, axis, spacing?} — even spacing of centers along an axis
func distribute(args: Dictionary) -> Dictionary:
	var ids: Array = ed.ids_arg(args)
	if ids.size() < 2:
		return ed._err("distribute requires >= 2 ids")
	var axis := _axis_index(str(args.get("axis", "x")))
	var items := []
	for id in ids:
		var node = ed.get_obj(str(id))
		if node:
			items.append({ "id": str(id), "node": node, "c": node.global_position[axis] })
	items.sort_custom(func(a, b): return a["c"] < b["c"])
	var n := items.size()
	var base: float = items[0]["c"]
	var step: float
	if args.has("spacing"):
		step = float(args["spacing"])
	else:
		step = (items[n - 1]["c"] - base) / float(n - 1) if n > 1 else 0.0
	var out := []
	for i in n:
		var node: Node3D = items[i]["node"]
		var p: Vector3 = node.global_position
		p[axis] = base + step * i
		node.global_position = p
		out.append({ "id": items[i]["id"], "position": ed._v3(p) })
	return ed._ok({ "distributed": out })


# duplicate {ids, by?, count?}
func duplicate(args: Dictionary) -> Dictionary:
	var ids: Array = ed.ids_arg(args)
	var count := int(args.get("count", 1))
	var by: Vector3 = ed.to_vec3(args.get("by", null), Vector3.ZERO)
	var new_ids := []
	for id in ids:
		for i in count:
			var nid: String = ed.clone_obj(str(id), by * (i + 1))
			if nid != "":
				new_ids.append(nid)
	return ed._ok({ "created": new_ids })


# array {id, count, step:[dx,dy,dz]} — count total instances along step
func array(args: Dictionary) -> Dictionary:
	var id := str(args.get("id", ""))
	if not ed.has_obj(id):
		return ed._err("unknown id: " + id)
	var count := int(args.get("count", 1))
	var step: Vector3 = ed.to_vec3(args.get("step", null), Vector3.ZERO)
	var new_ids := []
	for i in range(1, count):     # instance 0 is the original
		var nid: String = ed.clone_obj(id, step * i)
		if nid != "":
			new_ids.append(nid)
	return ed._ok({ "original": id, "created": new_ids, "count": count })


# group / parent {ids, parent?}
func group(args: Dictionary) -> Dictionary:
	var ids: Array = ed.ids_arg(args)
	if ids.is_empty():
		return ed._err("group requires ids")
	if args.has("parent") and ed.has_obj(str(args["parent"])):
		var parent_node = ed.get_obj(str(args["parent"]))
		for id in ids:
			var node = ed.get_obj(str(id))
			if node:
				node.reparent(parent_node, true)
		return ed._ok({ "parent": str(args["parent"]), "children": ids })
	var gid: String = ed.make_group(ids, "group")
	return ed._ok({ "group": gid, "children": ids })


# ---------------------------------------------------------------------------
func _axis_index(axis: String) -> int:
	match axis:
		"x": return 0
		"y": return 1
		"z": return 2
		_: return 0

func _edge_coord(id: String, axis: int, edge: String) -> float:
	var box: AABB = ed.aabb_of(id)
	var lo: float = box.position[axis]
	var hi: float = lo + box.size[axis]
	match edge:
		"min": return lo
		"max": return hi
		_: return (lo + hi) * 0.5
