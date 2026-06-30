extends RefCounted
## Perception/camera tool group (spec §7d) — control the canonical cameras.
## set_camera, bookmark_camera / goto_bookmark, frame_selection.
## (render / dump_state are handled directly by main.)

var ed

func _init(editor) -> void:
	ed = editor


# set_camera {name, position?, looking_at?, size?, fov?}
func set_camera(args: Dictionary) -> Dictionary:
	var name := str(args.get("name", ""))
	var cam: Camera3D = ed.camera_by_name(name)
	if cam == null:
		return ed._err("unknown camera: " + name)
	var pos: Vector3 = cam.global_position
	if args.has("position"):
		pos = ed.to_vec3(args["position"], pos)
	if args.has("looking_at"):
		cam.look_at_from_position(pos, ed.to_vec3(args["looking_at"], Vector3.ZERO), Vector3.UP)
	else:
		cam.global_position = pos
	if args.has("size"):
		cam.size = float(args["size"])
	if args.has("fov"):
		cam.fov = float(args["fov"])
	return ed._ok(_cam_state(name, cam))


# bookmark_camera {name} — store the perspective camera under a name
func bookmark_camera(args: Dictionary) -> Dictionary:
	var name := str(args.get("name", ""))
	if name == "":
		return ed._err("bookmark_camera requires name")
	var cam: Camera3D = ed.persp_camera
	ed.bookmarks[name] = { "transform": cam.global_transform, "fov": cam.fov }
	return ed._ok({ "bookmark": name })


# goto_bookmark {name}
func goto_bookmark(args: Dictionary) -> Dictionary:
	var name := str(args.get("name", ""))
	if not ed.bookmarks.has(name):
		return ed._err("unknown bookmark: " + name)
	var bm: Dictionary = ed.bookmarks[name]
	ed.persp_camera.global_transform = bm["transform"]
	ed.persp_camera.fov = bm["fov"]
	return ed._ok(_cam_state("persp", ed.persp_camera))


# frame_selection {camera} — fit the camera to the current selection (or all)
func frame_selection(args: Dictionary) -> Dictionary:
	var name := str(args.get("camera", "persp"))
	var ids: Array = ed.selection.duplicate()
	if ids.is_empty():
		ids = ed.registry.keys()
	var box: AABB = ed.combined_aabb(ids)
	if box == AABB():
		return ed._err("nothing to frame")
	var center := box.position + box.size * 0.5
	var radius := maxf(box.size.length() * 0.5, 1.0)
	var cam: Camera3D = ed.camera_by_name(name)
	match name:
		"top":
			cam.global_position = Vector3(center.x, 40, center.z)
			cam.look_at_from_position(cam.global_position, center, Vector3(0, 0, -1))
			cam.size = maxf(box.size.x, box.size.z) * 1.4 + 2.0
		"side":
			cam.global_position = Vector3(center.x + 40, center.y, center.z)
			cam.look_at_from_position(cam.global_position, center, Vector3.UP)
			cam.size = maxf(box.size.y, box.size.z) * 1.4 + 2.0
		_:
			var dist := radius / tan(deg_to_rad(cam.fov * 0.5)) + radius
			var dir := Vector3(1, 0.8, 1).normalized()
			cam.look_at_from_position(center + dir * dist, center, Vector3.UP)
	return ed._ok(_cam_state(name, cam))


func _cam_state(name: String, cam: Camera3D) -> Dictionary:
	var d := { "name": name, "position": ed._v3(cam.global_position) }
	if cam.projection == Camera3D.PROJECTION_ORTHOGONAL:
		d["size"] = cam.size
	else:
		d["fov"] = cam.fov
	return d
