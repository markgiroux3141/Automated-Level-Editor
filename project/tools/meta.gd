extends RefCounted
## Meta / robustness tool group (spec §7f).
## checkpoint / restore (named, file-backed), undo / redo (auto per mutating
## batch), log_intent, audit (run all checks + re-render).

var ed

func _init(editor) -> void:
	ed = editor


# checkpoint {name} — serialize the scene to checkpoints/<name>.json
func checkpoint(args: Dictionary) -> Dictionary:
	var name := _safe_name(str(args.get("name", "checkpoint")))
	var path := "res://checkpoints/%s.json" % name
	ed._write_json_atomic(path, ed.snapshot_scene())
	return ed._ok({ "checkpoint": name, "path": "checkpoints/%s.json" % name })


# restore {name} — load a named checkpoint and rebuild the scene
func restore(args: Dictionary) -> Dictionary:
	var name := _safe_name(str(args.get("name", "")))
	var abs_path := ProjectSettings.globalize_path("res://checkpoints/%s.json" % name)
	if not FileAccess.file_exists(abs_path):
		return ed._err("no checkpoint named '%s'" % name)
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(abs_path)) != OK:
		return ed._err("checkpoint '%s' is corrupt" % name)
	ed.apply_snapshot(json.data)
	return ed._ok({ "restored": name, "objects": ed.registry.size() })


# undo {} — revert the most recent mutating batch
func undo(_args: Dictionary) -> Dictionary:
	if ed.undo_stack.is_empty():
		return ed._err("nothing to undo")
	ed.redo_stack.append(ed.snapshot_scene())
	var snap: Dictionary = ed.undo_stack.pop_back()
	ed.apply_snapshot(snap)
	return ed._ok({ "undone": true, "objects": ed.registry.size(), "undo_depth": ed.undo_stack.size() })


# redo {} — re-apply the most recently undone batch
func redo(_args: Dictionary) -> Dictionary:
	if ed.redo_stack.is_empty():
		return ed._err("nothing to redo")
	ed.undo_stack.append(ed.snapshot_scene())
	var snap: Dictionary = ed.redo_stack.pop_back()
	ed.apply_snapshot(snap)
	return ed._ok({ "redone": true, "objects": ed.registry.size() })


# log_intent {text} — append a free-text rationale to build_log.jsonl
func log_intent(args: Dictionary) -> Dictionary:
	var text := str(args.get("text", ""))
	ed._append_build_log({ "intent": text })
	return ed._ok({ "logged": text })


# audit {} — run all checks (support/overlaps/scale) + re-render. The render
# is forced by the command loop seeing this is an audit (see main).
func audit(_args: Dictionary) -> Dictionary:
	var s: Dictionary = ed.verify.check_support({})
	var o: Dictionary = ed.verify.check_overlaps({})
	var sc: Dictionary = ed.verify.check_scale({})
	return ed._ok({
		"floaters": s["result"]["floaters"],
		"overlaps": o["result"]["overlaps"],
		"scale_warnings": sc["result"]["scale_warnings"],
		"navmesh_baked": ed.checks["navmesh_baked"],
	})


const _ALLOWED := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
func _safe_name(name: String) -> String:
	var out := ""
	for c in name:
		out += c if c in _ALLOWED else "_"
	return out if out != "" else "checkpoint"
