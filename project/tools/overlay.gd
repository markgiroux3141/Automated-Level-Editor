extends Control
## Annotation overlay (spec §6) — drawn into a SubViewport so it bakes into the
## captured PNG. One instance per canonical view, each bound to that view's
## camera. Provides the gestalt aids the agent reads: object-id labels,
## projected bounding boxes for the selection, a ground grid with coordinate
## ticks, an axis gizmo + north arrow, a scale bar, and forward arrows.
##
## Spatial truth still comes from state.json — these are for "does this read
## correctly / where do I point", never for measurement (design principle #2).

var ed
var cam: Camera3D
var view_name: String       # "top" | "persp" | "side"
var draw_grid := true

const GRID_HALF := 25       # ground grid spans [-25, 25] m
const GRID_STEP := 5        # major grid every 5 m
const LABEL_SIZE := 16
const TICK_SIZE := 13


func setup(editor, camera: Camera3D, name: String, with_grid := true) -> void:
	ed = editor
	cam = camera
	view_name = name
	draw_grid = with_grid
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	if cam == null:
		return
	var font := ThemeDB.fallback_font
	if draw_grid:
		_draw_ground_grid(font)
	_draw_objects(font)
	_draw_axis_gizmo(font)
	_draw_north_arrow(font)
	_draw_scale_bar(font)


# ---------------------------------------------------------------------------
# Ground grid + coordinate ticks
# ---------------------------------------------------------------------------
func _draw_ground_grid(font: Font) -> void:
	var col := Color(1, 1, 1, 0.18)
	var axis_col := Color(1, 1, 1, 0.4)
	var x := -GRID_HALF
	while x <= GRID_HALF:
		var c := axis_col if x == 0 else col
		_line3(Vector3(x, 0, -GRID_HALF), Vector3(x, 0, GRID_HALF), c, 1.0)
		x += GRID_STEP
	var z := -GRID_HALF
	while z <= GRID_HALF:
		var c2 := axis_col if z == 0 else col
		_line3(Vector3(-GRID_HALF, 0, z), Vector3(GRID_HALF, 0, z), c2, 1.0)
		z += GRID_STEP
	# Coordinate ticks along the X and Z axes (top/side read as a map).
	var t := -GRID_HALF
	while t <= GRID_HALF:
		if t != 0:
			_label3(font, Vector3(t, 0, 0), "%d" % t, TICK_SIZE, Color(1, 1, 1, 0.5))
			_label3(font, Vector3(0, 0, t), "%d" % t, TICK_SIZE, Color(1, 1, 1, 0.5))
		t += GRID_STEP * 2


# ---------------------------------------------------------------------------
# Objects: labels, dots, selection bbox, forward arrows
# ---------------------------------------------------------------------------
func _draw_objects(font: Font) -> void:
	for id in ed.registry.keys():
		var node: Node3D = ed.registry[id]["node"]
		var wpos: Vector3 = node.global_position
		if cam.is_position_behind(wpos):
			continue
		var sp := cam.unproject_position(wpos)
		var changed: bool = id in ed.changed_ids
		var selected: bool = id in ed.selection
		var col := Color.WHITE
		if selected:
			col = Color(0.4, 1.0, 0.4)
		elif changed:
			col = Color(1.0, 0.85, 0.2)
		draw_circle(sp, 3.0, col)
		draw_string(font, sp + Vector2(6, -6), id, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_SIZE, col)
		_draw_forward(node, wpos)
		if selected:
			_draw_aabb(id, col)


func _draw_forward(node: Node3D, wpos: Vector3) -> void:
	var fwd: Vector3 = -node.global_transform.basis.z.normalized()
	var tip := wpos + fwd * 1.0
	if cam.is_position_behind(wpos) or cam.is_position_behind(tip):
		return
	var a := cam.unproject_position(wpos)
	var b := cam.unproject_position(tip)
	draw_line(a, b, Color(0.2, 0.7, 1.0), 2.0)
	# Arrowhead.
	var dir := (b - a)
	if dir.length() > 1.0:
		dir = dir.normalized()
		var left := dir.rotated(2.5) * 7.0
		var right := dir.rotated(-2.5) * 7.0
		draw_line(b, b + left, Color(0.2, 0.7, 1.0), 2.0)
		draw_line(b, b + right, Color(0.2, 0.7, 1.0), 2.0)


func _draw_aabb(id: String, col: Color) -> void:
	var box: AABB = ed.aabb_of(id)
	if box.size == Vector3.ZERO:
		return
	var corners := []
	for i in 8:
		var c := box.get_endpoint(i)
		if cam.is_position_behind(c):
			return
		corners.append(cam.unproject_position(c))
	# 12 edges of the box (endpoint index bit pattern: x=bit0, y=bit1, z=bit2).
	var edges := [[0,1],[0,2],[0,4],[3,1],[3,2],[3,7],[5,1],[5,4],[5,7],[6,2],[6,4],[6,7]]
	for e in edges:
		draw_line(corners[e[0]], corners[e[1]], col, 1.5)


# ---------------------------------------------------------------------------
# Corner gizmos
# ---------------------------------------------------------------------------
func _draw_axis_gizmo(font: Font) -> void:
	# Project world axes as they appear from this camera, anchored at a corner.
	var anchor := Vector2(60, size.y - 60)
	var ref := cam.global_position - cam.global_transform.basis.z * 10.0
	var basis_screen := func(axis: Vector3) -> Vector2:
		var p0 := cam.unproject_position(ref)
		var p1 := cam.unproject_position(ref + axis)
		var d := p1 - p0
		return (d.normalized() * 28.0) if d.length() > 0.01 else Vector2.ZERO
	var ax: Vector2 = basis_screen.call(Vector3.RIGHT)
	var ay: Vector2 = basis_screen.call(Vector3.UP)
	var az: Vector2 = basis_screen.call(Vector3.BACK)
	draw_line(anchor, anchor + ax, Color(1, 0.3, 0.3), 2.0)
	draw_line(anchor, anchor + ay, Color(0.3, 1, 0.3), 2.0)
	draw_line(anchor, anchor + az, Color(0.4, 0.5, 1), 2.0)
	draw_string(font, anchor + ax + Vector2(2, 0), "X", HORIZONTAL_ALIGNMENT_LEFT, -1, TICK_SIZE, Color(1, 0.3, 0.3))
	draw_string(font, anchor + ay + Vector2(2, 0), "Y", HORIZONTAL_ALIGNMENT_LEFT, -1, TICK_SIZE, Color(0.3, 1, 0.3))
	draw_string(font, anchor + az + Vector2(2, 0), "Z", HORIZONTAL_ALIGNMENT_LEFT, -1, TICK_SIZE, Color(0.4, 0.5, 1))


func _draw_north_arrow(font: Font) -> void:
	# North = world -Z (forward). Anchored top-right.
	var anchor := Vector2(size.x - 50, 50)
	var p0 := cam.unproject_position(Vector3(0, 0, 0))
	var p1 := cam.unproject_position(Vector3(0, 0, -1))
	var d := (p1 - p0)
	var dir := d.normalized() if d.length() > 0.01 else Vector2(0, -1)
	draw_line(anchor, anchor + dir * 26.0, Color(1, 1, 1, 0.8), 2.0)
	draw_string(font, anchor + dir * 26.0 + Vector2(-4, -4), "N", HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_SIZE, Color.WHITE)


func _draw_scale_bar(font: Font) -> void:
	# Pixels-per-meter measured by projecting a 5 m segment at the ground center.
	var meters := 5.0
	var a := cam.unproject_position(Vector3(-meters * 0.5, 0, 0))
	var b := cam.unproject_position(Vector3(meters * 0.5, 0, 0))
	var px := a.distance_to(b)
	if px < 4.0:
		return
	var y := size.y - 24.0
	var x0 := 24.0
	draw_line(Vector2(x0, y), Vector2(x0 + px, y), Color.WHITE, 2.0)
	draw_line(Vector2(x0, y - 5), Vector2(x0, y + 5), Color.WHITE, 2.0)
	draw_line(Vector2(x0 + px, y - 5), Vector2(x0 + px, y + 5), Color.WHITE, 2.0)
	draw_string(font, Vector2(x0, y - 8), "%d m" % int(meters), HORIZONTAL_ALIGNMENT_LEFT, -1, TICK_SIZE, Color.WHITE)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
func _line3(a: Vector3, b: Vector3, col: Color, w: float) -> void:
	if cam.is_position_behind(a) or cam.is_position_behind(b):
		return
	draw_line(cam.unproject_position(a), cam.unproject_position(b), col, w)


func _label3(font: Font, wpos: Vector3, text: String, fs: int, col: Color) -> void:
	if cam.is_position_behind(wpos):
		return
	draw_string(font, cam.unproject_position(wpos), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
