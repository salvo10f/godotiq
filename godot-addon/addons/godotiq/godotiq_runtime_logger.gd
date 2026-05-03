extends Logger
## GodotIQ runtime logger — forwards game errors to the editor bridge.
## Loaded conditionally from GodotIQRuntime on Godot 4.5+.

var _send_callable: Callable


func _init(send_callable: Callable) -> void:
	_send_callable = send_callable


func _log_error(function: String, file: String, line: int, code: String, rationale: String, editor_notify: bool, error_type: int, script_backtraces: Array) -> void:
	var message := rationale if rationale != "" else code
	_send_callable.call({
		"source": "runtime",
		"severity": _severity_from_error_type(error_type),
		"function": function,
		"file": file,
		"line": line,
		"message": message,
		"code": code,
		"error_type": error_type,
		"timestamp": Time.get_unix_time_from_system(),
		"backtrace_count": script_backtraces.size(),
	})


func _log_message(message: String, error: bool) -> void:
	if not error:
		return
	_send_callable.call({
		"source": "runtime",
		"severity": "error",
		"message": message,
		"timestamp": Time.get_unix_time_from_system(),
	})


func _severity_from_error_type(error_type: int) -> String:
	match error_type:
		0:
			return "error"
		1:
			return "warning"
		2:
			return "script_error"
		3:
			return "shader_error"
		_:
			return "error"
