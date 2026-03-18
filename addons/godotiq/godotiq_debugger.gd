@tool
extends EditorDebuggerPlugin
## GodotIQ editor-side debugger plugin — bridges EngineDebugger messages
## between the running game and the WebSocket server.

var server  # untyped to avoid circular dependency — set by godotiq_plugin.gd
var _session_id: int = -1


func _has_capture(prefix: String) -> bool:
	return prefix == "godotiq"


func _capture(message: String, data: Array, session_id: int) -> bool:
	if server == null:
		push_warning("GodotIQ debugger: received message but server is null")
		return false
	match message:
		"godotiq:screenshot_result":
			server.handle_game_response("godotiq:screenshot", data)
			return true
		"godotiq:perf_result":
			server.handle_game_response("godotiq:query_perf", data)
			return true
		"godotiq:state_result":
			server.handle_game_response("godotiq:query_state", data)
			return true
		"godotiq:input_result":
			server.handle_game_response("godotiq:input", data)
			return true
		"godotiq:exec_result":
			server.handle_game_response("godotiq:exec", data)
			return true
		"godotiq:nav_result":
			server.handle_game_response("godotiq:query_nav", data)
			return true
		"godotiq:watch_result":
			server.handle_game_response("godotiq:watch", data)
			return true
		"godotiq:ui_map_result":
			server.handle_game_response("godotiq:query_ui_map", data)
			return true
		"godotiq:explore_camera_result":
			server.handle_game_response("godotiq:explore_camera", data)
			return true
		"godotiq:error":
			if data.size() >= 1:
				server._record_error(str(data[0]))
			server.send_event("runtime_error", {"data": data})
			return true
		"godotiq:watch_update":
			server.send_event("watch_update", {"data": data})
			return true
		_:
			push_warning("GodotIQ debugger: unknown message '%s'" % message)
			return false


func _setup_session(session_id: int) -> void:
	# Disconnect signals from previous session to prevent stale callbacks
	if _session_id >= 0:
		var old_session := get_session(_session_id)
		if old_session:
			if old_session.started.is_connected(_on_game_started):
				old_session.started.disconnect(_on_game_started)
			if old_session.stopped.is_connected(_on_game_stopped):
				old_session.stopped.disconnect(_on_game_stopped)

	_session_id = session_id
	var session := get_session(session_id)
	if session == null:
		push_warning("GodotIQ debugger: could not get session %d" % session_id)
		return
	session.started.connect(_on_game_started)
	session.stopped.connect(_on_game_stopped)


func _on_game_started() -> void:
	if server:
		server.on_game_started()


func _on_game_stopped() -> void:
	if server:
		server.on_game_stopped()
	# Do NOT reset _session_id here — Godot reuses sessions across game
	# start/stop cycles without calling _setup_session again.


func send_to_game(message: String, data: Array) -> void:
	if _session_id < 0:
		# Fallback: try to find a valid session (IDs start at 0)
		for candidate_id in range(0, 4):
			var s := get_session(candidate_id)
			if s != null:
				_session_id = candidate_id
				break
	if _session_id < 0:
		push_warning("GodotIQ debugger: no active session, cannot send '%s'" % message)
		return
	var session := get_session(_session_id)
	if session == null:
		push_warning("GodotIQ debugger: session %d not found" % _session_id)
		_session_id = -1
		return
	session.send_message(message, data)
