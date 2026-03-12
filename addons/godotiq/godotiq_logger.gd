extends Logger
## GodotIQ Logger — captures script compilation and parse errors from the engine.
## Only available on Godot 4.5+. Loaded conditionally via load() in godotiq_server.gd.

var _append_callable: Callable


func _init(server: Node) -> void:
	_append_callable = server._append_script_error


func _log_error(function: String, file: String, line: int, code: String, rationale: String, editor_notify: bool, error_type: int, script_backtraces: Array) -> void:
	if not (file.ends_with(".gd") or file.ends_with(".tscn")):
		return
	var entry := {
		"file": file,
		"line": line,
		"message": rationale if rationale != "" else code,
		"type": "script_error",
		"timestamp": Time.get_unix_time_from_system(),
	}
	_append_callable.call(entry)
