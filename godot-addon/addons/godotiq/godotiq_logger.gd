extends Logger
## GodotIQ Logger — captures script compilation and parse errors from the engine.
## Only available on Godot 4.5+. Loaded conditionally via load() in godotiq_server.gd.

var _append_callable: Callable
var capture_all: bool = false  ## When true, capture errors regardless of file extension (used during exec compilation).


func _init(server: Node) -> void:
	_append_callable = server._append_script_error


func _log_error(function: String, file: String, line: int, code: String, rationale: String, editor_notify: bool, error_type: int, script_backtraces: Array) -> void:
	if not capture_all and not (file.ends_with(".gd") or file.ends_with(".tscn")):
		return
	var entry := {
		"file": file,
		"line": line,
		"message": rationale if rationale != "" else code,
		"type": "script_error",
		"timestamp": Time.get_unix_time_from_system(),
	}
	_append_callable.call(entry)
