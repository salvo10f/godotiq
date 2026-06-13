@tool
extends Node
## GodotIQ WebSocket server — accepts connections from the Python MCP server,
## dispatches requests to editor handlers or forwards to the running game.

const DEFAULT_PORT := 6007
const ADDON_VERSION := "0.5.13"
const SCREENSHOT_TIMEOUT_MS := 30000
const PERF_TIMEOUT_MS := 5000
const INPUT_TIMEOUT_MS := 65000
const EXEC_TIMEOUT_MS := 10000
const STATE_TIMEOUT_MS := 5000
const RUN_ATTACH_TIMEOUT_MS := 3000
var _exec_counter: int = 0

var _tcp_server: TCPServer
var _peers: Dictionary = {}          # peer_id -> WebSocketPeer
var _peer_tcp: Dictionary = {}       # peer_id -> StreamPeerTCP (prevent GC)
var _pending_game_requests: Dictionary = {}  # req_key ("peer:id") -> {peer_id, request_id, method, timeout_at}
var _pending_screenshot = null  # Deferred editor screenshot capture data
var _pending_run = null  # Poll for scene play confirmation {peer_id, id, timeout_at, started_at}
var _pending_scene_open = null  # Deferred scene open + play {peer_id, id, scene_path, timeout}
var _game_running: bool = false
var _runtime_attached: bool = false  # set by _capture via mark_runtime_attached()
var _next_peer_id: int = 1
var _port: int = DEFAULT_PORT
var _bridge_token: String = ""
var debugger  # untyped — set by godotiq_plugin.gd
var undo_redo  # untyped — set by godotiq_plugin.gd (EditorUndoRedoManager)
var status_label: Label  # Bottom panel status label — set by godotiq_plugin.gd
var _godotiq_action_history: Array = []
const MAX_HISTORY_SIZE: int = 50
var _recent_errors: Array = []
const MAX_RECENT_ERRORS: int = 10
var _script_errors: Array = []  # [{file, line, message, type, timestamp}]
var _script_error_mutex: Mutex = Mutex.new()
const MAX_SCRIPT_ERRORS: int = 50
var _error_logger  # Variant — null if Logger unavailable
var _has_logger: bool = false
var _checking_errors: bool = false
var _update_checked: bool = false


func _clear_script_errors() -> void:
	_script_error_mutex.lock()
	_script_errors.clear()
	_script_error_mutex.unlock()


func _append_script_error(entry: Dictionary) -> void:
	_script_error_mutex.lock()
	if _script_errors.size() < MAX_SCRIPT_ERRORS:
		_script_errors.append(entry)
	_script_error_mutex.unlock()


func _get_script_errors() -> Array:
	_script_error_mutex.lock()
	var copy := _script_errors.duplicate(true)
	_script_error_mutex.unlock()
	return copy


func _ready() -> void:
	_port = _load_port_from_config()
	_bridge_token = _load_or_create_bridge_token()
	if _bridge_token.is_empty():
		push_error("GodotIQ: Bridge token unavailable. Requests will be rejected until res://.godotiq/bridge_token can be created.")
	_tcp_server = TCPServer.new()
	var err := _tcp_server.listen(_port, "127.0.0.1")
	if err == OK:
		print("GodotIQ: WebSocket server listening on 127.0.0.1:%d" % _port)
		_update_status_label()
	else:
		push_error("GodotIQ: Failed to start WebSocket server on port %d (error %d)" % [_port, err])
		if status_label:
			status_label.text = "Server: Failed to start (port %d)" % _port
	# Logger registration (Godot 4.5+ only)
	# Use call() for OS.add_logger — avoids compile error on Godot versions without it
	if ClassDB.class_exists("Logger") and OS.has_method("add_logger"):
		var logger_script = load("res://addons/godotiq/godotiq_logger.gd")
		if logger_script:
			_error_logger = logger_script.new(self)
			OS.call("add_logger", _error_logger)
			_has_logger = true
			print("GodotIQ: Logger registered (Godot 4.5+)")
		else:
			push_warning("GodotIQ: Logger class exists but godotiq_logger.gd failed to load")
	# One-time update check against PyPI
	if not _update_checked:
		_update_checked = true
		_check_for_update()


func _check_for_update() -> void:
	var http := HTTPRequest.new()
	http.timeout = 10.0
	add_child(http)
	http.request_completed.connect(_on_update_check_completed.bind(http))
	var err := http.request("https://pypi.org/pypi/godotiq/json")
	if err != OK:
		http.queue_free()


func _on_update_check_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray, http: HTTPRequest) -> void:
	http.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if parsed == null or not parsed.has("info") or not parsed["info"].has("version"):
		return
	var remote_version: String = parsed["info"]["version"]
	if _is_newer_version(remote_version, ADDON_VERSION):
		print("GodotIQ: Update available — v%s (current: v%s)" % [remote_version, ADDON_VERSION])
		if status_label:
			status_label.text = "GodotIQ v%s — Update available: v%s (pip install --upgrade godotiq && godotiq install-addon .)" % [ADDON_VERSION, remote_version]
		# Show one-time popup dialog
		var dialog := AcceptDialog.new()
		dialog.title = "GodotIQ Update Available"
		dialog.dialog_text = "GodotIQ v%s is available (you have v%s).\n\nRun in terminal:\npip install --upgrade godotiq && godotiq install-addon ." % [remote_version, ADDON_VERSION]
		dialog.ok_button_text = "Got it"
		dialog.confirmed.connect(dialog.queue_free)
		dialog.canceled.connect(dialog.queue_free)
		add_child(dialog)
		dialog.popup_centered()


func _is_newer_version(remote: String, local: String) -> bool:
	# PEP 440 pre-release / dev / post suffixes collapse to the base
	# triple — we never want the editor panel to nag stable users that
	# a "0.5.1rc0" is newer than "0.5.0". A prerelease published to
	# PyPI by mistake simply does not trigger the popup.
	var r := _version_triple(remote)
	var l := _version_triple(local)
	var max_len := max(r.size(), l.size())
	for i in range(max_len):
		var rv: int = r[i] if i < r.size() else 0
		var lv: int = l[i] if i < l.size() else 0
		if rv > lv:
			return true
		if rv < lv:
			return false
	return false


func _version_triple(v: String) -> Array:
	# Strip build-metadata ("+...") and hyphen-local-suffix ("-...").
	var clean := v.split("-", true, 1)[0].split("+", true, 1)[0]
	var parts := clean.split(".")
	var out: Array = []
	var pre_re := RegEx.new()
	pre_re.compile("(?i)(a|alpha|b|beta|c|rc|dev|pre|preview|post)\\d*$")
	for part in parts:
		var stripped := pre_re.sub(part, "", true)
		if stripped.is_empty():
			out.append(0)
		else:
			out.append(int(stripped))
	return out


func get_port() -> int:
	return _port


func _update_status_label() -> void:
	if status_label == null:
		return
	if _bridge_token.is_empty():
		status_label.text = "Server: Auth unavailable (.godotiq/bridge_token)"
		return
	if _peers.size() > 0:
		status_label.text = "Server: Connected (port %d)" % _port
	else:
		status_label.text = "Server: Listening (port %d)" % _port


func _load_port_from_config() -> int:
	if not FileAccess.file_exists("res://.godotiq.json"):
		return DEFAULT_PORT
	var file := FileAccess.open("res://.godotiq.json", FileAccess.READ)
	if file == null:
		return DEFAULT_PORT
	var text := file.get_as_text()
	file.close()
	var parsed = JSON.parse_string(text)
	if parsed is Dictionary and parsed.has("server"):
		var server_cfg = parsed["server"]
		if server_cfg is Dictionary and server_cfg.has("addon_port"):
			var port = server_cfg["addon_port"]
			if port is int or port is float:
				return int(port)
	return DEFAULT_PORT


func _load_or_create_bridge_token() -> String:
	var token_path := "res://.godotiq/bridge_token"
	if FileAccess.file_exists(token_path):
		var existing_file := FileAccess.open(token_path, FileAccess.READ)
		if existing_file != null:
			var existing := existing_file.get_as_text().strip_edges()
			existing_file.close()
			if not existing.is_empty():
				return existing

	var dir_err := DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path("res://.godotiq")
	)
	if dir_err != OK and dir_err != ERR_ALREADY_EXISTS:
		push_warning("GodotIQ: Failed to prepare .godotiq dir for bridge token")
		return ""

	var token := _generate_bridge_token()
	var file := FileAccess.open(token_path, FileAccess.WRITE)
	if file == null:
		push_warning("GodotIQ: Failed to persist bridge token")
		return ""
	file.store_string(token)
	file.close()
	return token


func _generate_bridge_token() -> String:
	if ClassDB.class_exists("Crypto"):
		var crypto := Crypto.new()
		var bytes := crypto.generate_random_bytes(32)
		if bytes.size() > 0:
			return bytes.hex_encode()

	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var token := ""
	for _i in range(4):
		token += "%08x" % rng.randi()
	return token


func _process(_delta: float) -> void:
	if _tcp_server == null or not _tcp_server.is_listening():
		return

	# 1. Accept new TCP connections
	while _tcp_server.is_connection_available():
		var tcp := _tcp_server.take_connection()
		if tcp == null:
			continue
		var ws := WebSocketPeer.new()
		var err := ws.accept_stream(tcp)
		if err == OK:
			var peer_id := _next_peer_id
			_next_peer_id += 1
			_peers[peer_id] = ws
			_peer_tcp[peer_id] = tcp
			_update_status_label()
		else:
			push_warning("GodotIQ: Failed to accept WebSocket stream (error %d)" % err)

	# 2. Poll all peers
	var to_remove: Array[int] = []
	for peer_id in _peers:
		var ws: WebSocketPeer = _peers[peer_id]
		ws.poll()
		var state := ws.get_ready_state()
		if state == WebSocketPeer.STATE_OPEN:
			while ws.get_available_packet_count() > 0:
				var packet := ws.get_packet()
				if ws.was_string_packet():
					var text := packet.get_string_from_utf8()
					_handle_message(peer_id, text)
		elif state == WebSocketPeer.STATE_CLOSED:
			to_remove.append(peer_id)

	# 3. Remove disconnected peers
	for peer_id in to_remove:
		_peers.erase(peer_id)
		_peer_tcp.erase(peer_id)
	if to_remove.size() > 0:
		_update_status_label()

	# 4. Process deferred editor screenshot
	if _pending_screenshot != null:
		var s: Dictionary = _pending_screenshot
		_pending_screenshot = null
		_do_editor_screenshot(
			s["peer_id"], s["id"], s["viewport_3d"],
			s["camera"], s["original_transform"], true, s["scale"], s["quality"], s["fmt"], s.get("region", [])
		)

	# 4a. Process deferred scene open -> play
	if _pending_scene_open != null:
		var s: Dictionary = _pending_scene_open
		_pending_scene_open = null
		EditorInterface.play_current_scene()
		_pending_run = {
			"peer_id": s["peer_id"],
			"id": s["id"],
			"started_at": Time.get_ticks_msec(),
			"timeout_at": Time.get_ticks_msec() + int(s.get("timeout", 15.0) * 1000),
			"scene": s.get("scene_path", ""),
			"main_scene_empty": s.get("main_scene_empty", false),
			"script_warnings": s.get("script_warnings", []),
		}

	# 4b. Poll for scene play confirmation. Success is gated on the runtime
	# attach heartbeat (own short sub-timeout): playing-but-unattached past
	# the window still succeeds, but with an explicit runtime_attached:false
	# + warning — never a bare success:true (BUG-02 readiness contract).
	if _pending_run != null:
		var r: Dictionary = _pending_run
		if _is_game_playing():
			if _runtime_attached:
				_pending_run = null
				send_response(r["peer_id"], r["id"], _build_run_response(r, true))
			elif not r.has("attach_timeout_at"):
				r["attach_timeout_at"] = Time.get_ticks_msec() + RUN_ATTACH_TIMEOUT_MS
			elif Time.get_ticks_msec() > r["attach_timeout_at"]:
				_pending_run = null
				send_response(r["peer_id"], r["id"], _build_run_response(r, false))
		elif Time.get_ticks_msec() > r["timeout_at"]:
			_pending_run = null
			var timeout_secs: float = (r["timeout_at"] - r.get("started_at", r["timeout_at"])) / 1000.0
			_send_error(r["peer_id"], r["id"], "RUN_TIMEOUT",
				"Scene did not start within %.1f seconds" % timeout_secs)

	# 5. Check timed-out game requests
	var now := Time.get_ticks_msec()
	var timed_out: Array[String] = []
	for req_id in _pending_game_requests:
		var entry: Dictionary = _pending_game_requests[req_id]
		if now > entry["timeout_at"]:
			timed_out.append(req_id)
	for req_id in timed_out:
		var entry: Dictionary = _pending_game_requests[req_id]
		_send_error(entry["peer_id"], entry["request_id"], "TIMEOUT", "Game request timed out")
		_pending_game_requests.erase(req_id)


func _handle_message(peer_id: int, text: String) -> void:
	var parsed = JSON.parse_string(text)
	if parsed == null or not (parsed is Dictionary):
		_send_error(peer_id, "", "PARSE_ERROR", "Invalid JSON")
		return
	var id: String = str(parsed.get("id", ""))
	var method: String = str(parsed.get("method", ""))
	var params: Dictionary = parsed.get("params", {})
	if not (params is Dictionary):
		params = {}
	var token: String = str(parsed.get("token", ""))
	if _bridge_token.is_empty():
		_bridge_token = _load_or_create_bridge_token()
		if _bridge_token.is_empty():
			_update_status_label()
			_send_error(peer_id, id, "AUTH_UNAVAILABLE", "Bridge token unavailable on addon side")
			return
	if token != _bridge_token:
		_send_error(peer_id, id, "AUTH_ERROR", "Invalid or missing bridge token")
		return
	_dispatch(peer_id, id, method, params)


func _dispatch(peer_id: int, id: String, method: String, params: Dictionary) -> void:
	match method:
		"ping":
			_handle_ping(peer_id, id)
		"editor_context":
			_handle_editor_context(peer_id, id)
		"scene_tree":
			_handle_scene_tree(peer_id, id, params)
		"node_ops":
			_handle_node_ops(peer_id, id, params)
		"run":
			_handle_run(peer_id, id, params)
		"stop":
			_handle_stop(peer_id, id)
		"screenshot":
			_handle_game_forward(peer_id, id, "godotiq:screenshot", params, SCREENSHOT_TIMEOUT_MS)
		"perf_snapshot":
			_handle_game_forward(peer_id, id, "godotiq:query_perf", params, PERF_TIMEOUT_MS)
		"input":
			_handle_game_forward(peer_id, id, "godotiq:input", params, INPUT_TIMEOUT_MS)
		"exec":
			var exec_timeout_ms: int = int(params.get("timeout_ms", EXEC_TIMEOUT_MS))
			_handle_game_forward(peer_id, id, "godotiq:exec", params, exec_timeout_ms)
		"state_inspect":
			_handle_game_forward(peer_id, id, "godotiq:query_state", params, STATE_TIMEOUT_MS)
		"nav_query":
			_handle_game_forward(peer_id, id, "godotiq:query_nav", params, 10000)
		"watch":
			_handle_game_forward(peer_id, id, "godotiq:watch", params, 5000)
		"ui_map":
			_handle_game_forward(peer_id, id, "godotiq:query_ui_map", params, 10000)
		"undo_history":
			_handle_undo_history(peer_id, id, params)
		"exec_editor":
			_handle_exec_editor(peer_id, id, params)
		"save_scene":
			_handle_save_scene(peer_id, id, params)
		"editor_screenshot":
			_handle_editor_screenshot(peer_id, id, params)
		"camera":
			_handle_camera(peer_id, id, params)
		"build_scene":
			_handle_build_scene(peer_id, id, params)
		"check_errors":
			_handle_check_errors(peer_id, id, params)
		"read_debug_console":
			_handle_read_debug_console(peer_id, id, params)
		"set_main_scene":
			_handle_set_main_scene(peer_id, id, params)
		"reload_script":
			_handle_reload_script(peer_id, id, params)
		"uid_probe":
			_handle_uid_probe(peer_id, id, params)
		"wait_for_import":
			_handle_wait_for_import(peer_id, id, params)
		"explore_camera":
			_handle_game_forward(peer_id, id, "godotiq:explore_camera", params, 10000)
		_:
			_send_error(peer_id, id, "UNKNOWN_METHOD", "Unknown method: %s" % method)


# --- Editor-side handlers ---

func _handle_ping(peer_id: int, id: String) -> void:
	send_response(peer_id, id, {
		"editor_version": Engine.get_version_info().get("string", "unknown"),
		# Live editor state, not the stale-on-session-reuse flag — keeps the
		# payload consistent with _editor_state.game_running.
		"game_running": _is_game_playing(),
		"addon_version": ADDON_VERSION,
		# Editor process id — consumed by the Python editor-open guard to
		# identify which editor holds this project (BUG-04).
		"pid": OS.get_process_id(),
	})


func _handle_editor_context(peer_id: int, id: String) -> void:
	var scenes := EditorInterface.get_open_scenes()
	var open_scenes: Array[String] = []
	for i in range(scenes.size()):
		open_scenes.append(scenes[i])
	var selected: Array[String] = []
	var selection := EditorInterface.get_selection()
	if selection:
		for node in selection.get_selected_nodes():
			selected.append(str(node.get_path()))
	send_response(peer_id, id, {
		"open_scenes": open_scenes,
		"selected_nodes": selected,
		"game_running": _is_game_playing(),
		"project_path": ProjectSettings.globalize_path("res://"),
		# Editor process id — consumed by the Python editor-open guard to
		# identify which editor holds this project (BUG-04).
		"pid": OS.get_process_id(),
	})


func _set_main_scene_internal(scene_path: String) -> bool:
	ProjectSettings.set_setting("application/run/main_scene", scene_path)
	var err := ProjectSettings.save()
	return err == OK


func _handle_set_main_scene(peer_id: int, id: String, params: Dictionary) -> void:
	var scene: String = str(params.get("scene", ""))
	if scene.is_empty():
		_send_error(peer_id, id, "MISSING_PARAM", "Missing required parameter: scene")
		return
	if not scene.begins_with("res://"):
		scene = "res://" + scene
	var saved := _set_main_scene_internal(scene)
	send_response(peer_id, id, {"main_scene": scene, "saved": saved})


func _wait_for_import_idle(fs, timeout_ms: int) -> Dictionary:
	# Poll until the editor filesystem scan/import queue is idle (BUG-08).
	# "Idle" means the EDITOR's state is updated — on-disk import artifacts
	# (.godot/imported) may still flush asynchronously. fs is untyped so
	# contract tests can inject a fake in headless runs.
	var start_ms: int = Time.get_ticks_msec()
	var polls: int = 0
	# Grace frames: scan() requested just before this call starts DEFERRED,
	# so is_scanning() is still false on an immediate first check and the
	# wait would return without covering the scan it was meant to observe
	# (reproduced 18/20 in the BUG-08 loop, 2026-06-10).
	for _grace in range(2):
		if fs.is_scanning():
			break
		await Engine.get_main_loop().process_frame
	while fs.is_scanning():
		var waited: int = Time.get_ticks_msec() - start_ms
		if waited >= timeout_ms:
			return {
				"idle": false,
				"timed_out": true,
				"waited_ms": waited,
				"polls": polls,
				"scan_progress": fs.get_scanning_progress(),
			}
		polls += 1
		# Main-loop signal, not get_tree(): works even when this node is
		# not (yet) inside the tree, which headless contract tests rely on.
		await Engine.get_main_loop().process_frame
	return {
		"idle": true,
		"timed_out": false,
		"waited_ms": Time.get_ticks_msec() - start_ms,
		"polls": polls,
	}


func _handle_wait_for_import(peer_id: int, id: String, params: Dictionary) -> void:
	# Explicit, agent-requested wait — scan()/reimport stay fire-and-forget
	# everywhere else; bridge ops must never block by default (BUG-08).
	var timeout_ms: int = int(params.get("timeout_ms", 30000))
	var status: Dictionary = await _wait_for_import_idle(
		EditorInterface.get_resource_filesystem(), timeout_ms
	)
	send_response(peer_id, id, status)


func _handle_uid_probe(peer_id: int, id: String, params: Dictionary) -> void:
	# Read-only probe of the editor's IN-MEMORY ResourceUID view (BUG-05).
	# Used by the Python uid_to_path/path_to_uid divergence check to compare
	# editor memory against the fresh-disk resolution. Must never reimport
	# or rescan — on divergence the recommended fix is an editor restart.
	var uid_text: String = str(params.get("uid", ""))
	var res_path: String = str(params.get("path", ""))
	if uid_text.is_empty() and res_path.is_empty():
		_send_error(peer_id, id, "MISSING_PARAM", "Provide 'uid' or 'path'")
		return
	if not uid_text.is_empty():
		var uid_int := ResourceUID.text_to_id(uid_text)
		var known := uid_int != ResourceUID.INVALID_ID and ResourceUID.has_id(uid_int)
		send_response(peer_id, id, {
			"probe": "uid_to_path",
			"uid": uid_text,
			"path": ResourceUID.get_id_path(uid_int) if known else null,
		})
		return
	if not res_path.begins_with("res://"):
		res_path = "res://" + res_path
	var id_for_path := ResourceSaver.get_resource_id_for_path(res_path, false)
	send_response(peer_id, id, {
		"probe": "path_to_uid",
		"path": res_path,
		"uid": ResourceUID.id_to_text(id_for_path) if id_for_path != ResourceUID.INVALID_ID else null,
	})


func _handle_reload_script(peer_id: int, id: String, params: Dictionary) -> void:
	var path: String = str(params.get("path", ""))
	if path.is_empty() or not path.ends_with(".gd"):
		_send_error(peer_id, id, "INVALID_PATH", "Path must be a non-empty .gd file path")
		return
	var script = load(path)
	if script == null or not (script is GDScript):
		send_response(peer_id, id, {"reloaded": false, "error": "Failed to load script: %s" % path})
		return
	# Typed local: a user script declaring a non-static reload() shadows the
	# untyped call (callp yields null → Nil-to-int crash); the typed call
	# binds the native GDScript.reload().
	var gd_script: GDScript = script
	var err: int = gd_script.reload()
	if err != OK:
		send_response(peer_id, id, {"reloaded": false, "error": "Reload failed with code %d" % err})
		return
	EditorInterface.get_resource_filesystem().scan()
	send_response(peer_id, id, {"reloaded": true, "path": path})


func _find_scene_by_name(scene_name: String) -> Dictionary:
	## Search for a .tscn file matching scene_name. Returns {"path": "res://...", "matches": [...]}.
	var matches: Array[String] = []
	var fs := EditorInterface.get_resource_filesystem()
	if fs:
		_collect_tscn_matches(fs.get_filesystem(), scene_name, matches)
	if matches.size() == 1:
		return {"path": matches[0], "matches": matches}
	return {"path": "", "matches": matches}


func _collect_tscn_matches(dir: EditorFileSystemDirectory, scene_name: String, matches: Array[String]) -> void:
	for i in dir.get_file_count():
		var file_path: String = dir.get_file_path(i)
		if file_path.ends_with(".tscn"):
			var base: String = file_path.get_file().get_basename()
			if base.to_lower() == scene_name.to_lower():
				matches.append(file_path)
	for i in dir.get_subdir_count():
		_collect_tscn_matches(dir.get_subdir(i), scene_name, matches)


func _handle_run(peer_id: int, id: String, params: Dictionary) -> void:
	# Reset attachment at launch start — resetting only in on_game_stopped()
	# leaves a stale-true window when the stopped callback is missed or a
	# late capture from a previous session lands on the next run.
	_runtime_attached = false

	# Step 1: Save all open scenes
	EditorInterface.save_all_scenes()

	# Step 2: Resolve scene path
	var scene_param = params.get("scene", null)
	var resolved_path: String = ""
	var is_current: bool = false

	if scene_param == null or scene_param == "" or scene_param == "main":
		var main_path: String = ProjectSettings.get_setting("application/run/main_scene", "")
		if main_path != "":
			resolved_path = main_path
		else:
			# No main scene — use whatever is open in the editor
			is_current = true
	elif scene_param == "current":
		is_current = true
	else:
		var sp: String = str(scene_param)
		if sp.ends_with(".tscn"):
			if not sp.begins_with("res://"):
				sp = "res://" + sp
			resolved_path = sp
		else:
			# Search by name
			var result := _find_scene_by_name(sp)
			if result["matches"].size() > 1:
				_send_error(peer_id, id, "AMBIGUOUS_SCENE",
					"Multiple scenes match '%s': %s" % [sp, str(result["matches"])])
				return
			if result["path"] == "":
				_send_error(peer_id, id, "SCENE_NOT_FOUND",
					"No .tscn file found matching name: %s" % sp)
				return
			resolved_path = result["path"]

	# If using current scene, resolve from editor
	var edited_root = EditorInterface.get_edited_scene_root()
	if is_current:
		if edited_root:
			resolved_path = edited_root.scene_file_path
		else:
			_send_error(peer_id, id, "NO_SCENE", "No scene is open in the editor")
			return

	# Step 3: Pre-flight script validation (PRESERVED)
	var script_paths: Array[String] = []
	if is_current:
		if edited_root:
			script_paths.append_array(_get_scene_script_paths(edited_root))
	else:
		script_paths.append_array(_get_scripts_from_packed_scene(resolved_path))
		script_paths.append_array(_get_autoload_script_paths())
	var seen := {}
	var unique_paths: Array[String] = []
	for p in script_paths:
		if not seen.has(p):
			seen[p] = true
			unique_paths.append(p)
	var script_warnings := _check_scripts_valid(unique_paths)

	# Step 4: Check if main scene is empty (report only, do NOT auto-write)
	var main_scene_empty: bool = false
	if not is_current and resolved_path != "":
		var current_main: String = ProjectSettings.get_setting("application/run/main_scene", "")
		if current_main == "":
			main_scene_empty = true

	# Step 5: Read timeout
	var timeout: float = float(params.get("timeout", 15.0))

	# Step 6: Open scene if needed, then play
	edited_root = EditorInterface.get_edited_scene_root()
	var current_scene_path: String = edited_root.scene_file_path if edited_root else ""

	if not is_current and resolved_path != current_scene_path:
		# Need to open the scene first — defer play to next _process tick
		EditorInterface.open_scene_from_path(resolved_path)
		_pending_scene_open = {
			"peer_id": peer_id,
			"id": id,
			"scene_path": resolved_path,
			"timeout": timeout,
			"main_scene_empty": main_scene_empty,
			"script_warnings": script_warnings,
		}
	else:
		# Scene already open — play immediately
		EditorInterface.play_current_scene()
		_pending_run = {
			"peer_id": peer_id,
			"id": id,
			"started_at": Time.get_ticks_msec(),
			"timeout_at": Time.get_ticks_msec() + int(timeout * 1000),
			"scene": resolved_path,
			"main_scene_empty": main_scene_empty,
			"script_warnings": script_warnings,
		}


func _build_run_response(r: Dictionary, runtime_attached: bool) -> Dictionary:
	var waited: float = (Time.get_ticks_msec() - r.get("started_at", Time.get_ticks_msec())) / 1000.0
	var resp := {
		"action": "play",
		"success": true,
		"scene": r.get("scene", ""),
		"waited_seconds": waited,
		"runtime_attached": runtime_attached,
	}
	if not runtime_attached:
		resp["warning"] = (
			"Scene is playing but the GodotIQ runtime did not attach; "
			+ "runtime tools (screenshot, input, state_inspect, exec context=game) are unavailable."
		)
	if r.get("main_scene_empty", false):
		resp["main_scene_empty"] = true
		resp["hint"] = "No main_scene set. Use set_main_scene to configure."
	var sw = r.get("script_warnings", [])
	if sw.size() > 0:
		resp["script_warnings"] = sw
	return resp


func _get_scripts_from_packed_scene(scene_path: String) -> Array[String]:
	var result: Array[String] = []
	var packed = load(scene_path)
	if packed == null or not packed is PackedScene:
		return result
	var state = packed.get_state()
	for node_idx in state.get_node_count():
		for prop_idx in state.get_node_property_count(node_idx):
			if state.get_node_property_name(node_idx, prop_idx) == "script":
				var val = state.get_node_property_value(node_idx, prop_idx)
				if val is GDScript and val.resource_path != "":
					result.append(val.resource_path)
	return result


func _get_autoload_script_paths() -> Array[String]:
	var result: Array[String] = []
	for prop in ProjectSettings.get_property_list():
		if prop.name.begins_with("autoload/"):
			var value: String = ProjectSettings.get_setting(prop.name)
			var path: String = value.trim_prefix("*")
			if path.ends_with(".gd"):
				result.append(path)
			elif path.ends_with(".tscn"):
				var scene = load(path)
				if scene and scene is PackedScene:
					var state = scene.get_state()
					if state.get_node_count() > 0:
						for i in state.get_node_property_count(0):
							if state.get_node_property_name(0, i) == "script":
								var script_val = state.get_node_property_value(0, i)
								if script_val is GDScript:
									result.append(script_val.resource_path)
	return result


func _check_scripts_valid(script_paths: Array[String]) -> Array[Dictionary]:
	var errors: Array[Dictionary] = []
	for path in script_paths:
		var res = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		if res == null:
			errors.append({"file": path, "error": "Failed to load script"})
		elif res is GDScript:
			# Typed local — see _check_loaded_script: a non-static reload()
			# shadow crashes the untyped call path.
			var gd_script: GDScript = res
			var err: int = gd_script.reload()
			if err != OK:
				errors.append({"file": path, "error": "Script reload failed (error %d)" % err})
	return errors


func _handle_stop(peer_id: int, id: String) -> void:
	EditorInterface.stop_playing_scene()
	send_response(peer_id, id, {"stopped": true})


func _handle_scene_tree(peer_id: int, id: String, params: Dictionary) -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		_send_error(peer_id, id, "NO_SCENE", "No scene is currently open in the editor")
		return

	# Extract parameters
	var root_param: String = str(params.get("root", ""))
	var depth: int = clampi(int(params.get("depth", 3)), 1, 10)
	var filter_type: String = str(params.get("filter_type", ""))
	var include: Array = params.get("include", ["transform", "script", "groups", "visibility"])

	# Resolve start node
	var start_node: Node = scene_root
	if root_param != "":
		start_node = scene_root.get_node_or_null(NodePath(root_param))
		if start_node == null:
			start_node = _find_by_name_recursive(scene_root, root_param)
		if start_node == null:
			_send_error(peer_id, id, "NODE_NOT_FOUND", "Node not found: %s" % root_param)
			return

	var total_nodes := _count_descendants(start_node)
	var tree: Array = []
	var returned_nodes := _walk_tree(start_node, scene_root, depth, 0, filter_type, include, tree)

	send_response(peer_id, id, {
		"root": str(start_node.name),
		"scene_path": scene_root.scene_file_path,
		"total_nodes": total_nodes,
		"returned_nodes": returned_nodes,
		"tree": tree,
	})


func _walk_tree(node: Node, scene_root: Node, max_depth: int, current_depth: int, filter_type: String, include: Array, out_nodes: Array) -> int:
	var count := 0
	var matches_filter := filter_type == "" or node.is_class(filter_type)

	var node_dict := {}
	if matches_filter:
		node_dict["n"] = str(node.name)
		node_dict["t"] = node.get_class()

		if "transform" in include:
			if node is Node3D:
				var n3d: Node3D = node
				node_dict["p"] = [n3d.position.x, n3d.position.y, n3d.position.z]
				node_dict["r"] = [n3d.rotation_degrees.x, n3d.rotation_degrees.y, n3d.rotation_degrees.z]
				node_dict["s"] = [n3d.scale.x, n3d.scale.y, n3d.scale.z]
			elif node is Node2D:
				var n2d: Node2D = node
				node_dict["p"] = [n2d.position.x, n2d.position.y]
				node_dict["r"] = n2d.rotation_degrees
				node_dict["s"] = [n2d.scale.x, n2d.scale.y]
			elif node is Control:
				var ctrl: Control = node
				node_dict["p"] = [ctrl.position.x, ctrl.position.y]
				node_dict["s"] = [ctrl.size.x, ctrl.size.y]

		if "script" in include and node.get_script() != null:
			node_dict["script"] = node.get_script().resource_path

		if "groups" in include:
			var groups: Array[String] = []
			for g in node.get_groups():
				if not str(g).begins_with("_"):
					groups.append(str(g))
			if groups.size() > 0:
				node_dict["groups"] = groups

		if "visibility" in include and "visible" in node:
			node_dict["visible"] = node.visible

	# Recurse into children
	if current_depth < max_depth and node.get_child_count() > 0:
		var child_nodes: Array = []
		for child in node.get_children():
			count += _walk_tree(child, scene_root, max_depth, current_depth + 1, filter_type, include, child_nodes)
		if matches_filter and child_nodes.size() > 0:
			node_dict["children"] = child_nodes
		elif not matches_filter:
			# Promote children up when current node doesn't match filter
			out_nodes.append_array(child_nodes)
	elif matches_filter and current_depth == max_depth and node.get_child_count() > 0:
		node_dict["children_count"] = node.get_child_count()

	if matches_filter:
		out_nodes.append(node_dict)
		count += 1

	return count


func _count_descendants(node: Node) -> int:
	var count := 1
	for child in node.get_children():
		count += _count_descendants(child)
	return count


func _find_by_name_recursive(node: Node, target_name: String) -> Node:
	if node.name == target_name:
		return node
	for child in node.get_children():
		var found := _find_by_name_recursive(child, target_name)
		if found != null:
			return found
	return null


## Lazy proxy around EditorUndoRedoManager. The action is created only when
## the first do/undo registration arrives, so read-only or all-failed batches
## never call create_action() at all — an open action left behind would
## silently swallow EVERY later node_ops batch until editor restart (E6/E6b).
class LazyEditorAction:
	extends RefCounted

	const UNSET := {}  # identity sentinel for unused optional method-arg slots

	var created := false
	var _manager: Object
	var _action_name: String
	var _context: Node

	func _init(manager: Object, action_name: String, context: Node) -> void:
		_manager = manager
		_action_name = action_name
		_context = context

	func _ensure() -> void:
		if not created:
			_manager.create_action(_action_name, 0, _context)  # 0 = MERGE_DISABLE
			created = true

	func add_do_property(obj: Object, prop: String, value) -> void:
		_ensure()
		_manager.add_do_property(obj, prop, value)

	func add_undo_property(obj: Object, prop: String, value) -> void:
		_ensure()
		_manager.add_undo_property(obj, prop, value)

	func add_do_method(obj: Object, method: String, a1 = UNSET, a2 = UNSET, a3 = UNSET, a4 = UNSET) -> void:
		_ensure()
		_callv_vararg("add_do_method", obj, method, [a1, a2, a3, a4])

	func add_undo_method(obj: Object, method: String, a1 = UNSET, a2 = UNSET, a3 = UNSET, a4 = UNSET) -> void:
		_ensure()
		_callv_vararg("add_undo_method", obj, method, [a1, a2, a3, a4])

	func add_do_reference(obj: Object) -> void:
		_ensure()
		_manager.add_do_reference(obj)

	func add_undo_reference(obj: Object) -> void:
		_ensure()
		_manager.add_undo_reference(obj)

	func commit_if_created() -> void:
		if created:
			_manager.commit_action()

	func _callv_vararg(manager_method: String, obj: Object, method: String, slots: Array) -> void:
		var args: Array = [obj, method]
		for slot in slots:
			if is_same(slot, UNSET):
				break
			args.append(slot)
		_manager.callv(manager_method, args)


func _handle_node_ops(peer_id: int, id: String, params: Dictionary) -> void:
	var operations: Array = params.get("operations", [])
	if not (operations is Array) or operations.size() == 0:
		_send_error(peer_id, id, "INVALID_PARAMS", "operations must be a non-empty array")
		return

	var preflight := _preflight_scene_check(params)
	if not preflight["ok"]:
		_send_error(peer_id, id, "PREFLIGHT_FAILED", preflight["error"])
		return
	var scene_root := EditorInterface.get_edited_scene_root()

	if undo_redo == null:
		_send_error(peer_id, id, "NO_UNDO_REDO", "UndoRedo manager not available")
		return

	var action_name := "GodotIQ: %d node operation(s)" % operations.size()
	var action := LazyEditorAction.new(undo_redo, action_name, scene_root)

	var results: Array = []
	for op_data in operations:
		if not (op_data is Dictionary):
			results.append({"status": "error", "error": "Invalid operation format"})
			continue
		var result := _execute_node_op(op_data, scene_root, action)
		results.append(result)

	# Always close the action once anything was registered — even if later ops
	# in the batch failed. An uncommitted action poisons the manager globally.
	action.commit_if_created()

	if action.created:
		_verify_node_op_results(results)
		_godotiq_action_history.append({
			"action": action_name,
			"operations": results.size(),
			"timestamp": Time.get_ticks_msec(),
		})
		if _godotiq_action_history.size() > MAX_HISTORY_SIZE:
			_godotiq_action_history = _godotiq_action_history.slice(
				_godotiq_action_history.size() - MAX_HISTORY_SIZE
			)

	# Truth in reporting: scene_modified only counts effects observed by the
	# post-commit read-back; all_verified is false if any mutating op failed
	# verification (or errored). get_property is read-only and never counts.
	var scene_modified := false
	var all_verified := true
	for result in results:
		if str(result.get("op", "")) == "get_property":
			continue
		if result.get("_effect_observed", false):
			scene_modified = true
		if str(result.get("status", "")) != "ok" or result.get("verified", false) != true:
			all_verified = false

	# Clean up internal metadata from ALL results before sending response
	for result in results:
		result.erase("_node_ref")
		result.erase("_parent_ref")
		result.erase("_prop_name")
		result.erase("_expected")
		result.erase("_expected_anchors")
		result.erase("_old_name")
		result.erase("_verify")
		result.erase("_effect_observed")

	send_response(peer_id, id, {
		"results": results,
		"scene_modified": scene_modified,
		"all_verified": all_verified,
		"undo_available": action.created,
		"action_name": action_name,
	})


## Post-commit read-back for every mutating operation: confirm against the
## live tree that the requested change actually happened. verified:false
## downgrades the op status to "unverified" ("ok"/"error" keep their meaning).
func _verify_node_op_results(results: Array) -> void:
	var modified_nodes: Dictionary = {}
	for result in results:
		if str(result.get("status", "")) != "ok":
			continue
		var kind: String = str(result.get("_verify", ""))
		if kind.is_empty():
			continue
		var node = result.get("_node_ref")
		var node_ok: bool = node != null and is_instance_valid(node)
		var verified := false
		var effect := false
		match kind:
			"property":
				if node_ok:
					modified_nodes[node] = true
					var prop_name: String = str(result.get("_prop_name", ""))
					var expected = result.get("_expected")
					var actual = node.get(prop_name)
					verified = _values_match(actual, expected)
					result["actual_value"] = _value_to_json(actual)
					effect = verified
			"rename":
				if node_ok:
					modified_nodes[node] = true
					var actual_name := str(node.name)
					var requested := str(result.get("new_name", ""))
					var old_name := str(result.get("_old_name", ""))
					result["actual_name"] = actual_name
					verified = actual_name == requested
					if not verified and actual_name != old_name:
						# Godot deduplicated the name (sibling collision).
						result["name_collision"] = true
					effect = actual_name != old_name
			"delete":
				# The node object survives via the undo reference; deletion
				# is confirmed by it having left the tree.
				verified = node_ok and not node.is_inside_tree()
				effect = verified
			"child_present":
				var parent = result.get("_parent_ref")
				if node_ok and parent != null and is_instance_valid(parent):
					modified_nodes[node] = true
					verified = node.is_inside_tree() and node.get_parent() == parent
					var actual_name := str(node.name)
					result["actual_name"] = actual_name
					var requested := str(result.get("node", result.get("new_name", "")))
					if verified and not requested.is_empty() and actual_name != requested:
						result["name_collision"] = true
				effect = verified
			"reparent":
				var parent = result.get("_parent_ref")
				if node_ok and parent != null and is_instance_valid(parent):
					modified_nodes[node] = true
					verified = node.is_inside_tree() and node.get_parent() == parent
				effect = verified
			"anchors":
				if node_ok:
					modified_nodes[node] = true
					var expected_anchors: Array = result.get("_expected_anchors", [])
					if expected_anchors.size() == 4:
						verified = (
							is_equal_approx(float(node.get("anchor_left")), float(expected_anchors[0]))
							and is_equal_approx(float(node.get("anchor_top")), float(expected_anchors[1]))
							and is_equal_approx(float(node.get("anchor_right")), float(expected_anchors[2]))
							and is_equal_approx(float(node.get("anchor_bottom")), float(expected_anchors[3]))
						)
						result["actual_anchors"] = [
							node.get("anchor_left"), node.get("anchor_top"),
							node.get("anchor_right"), node.get("anchor_bottom"),
						]
					effect = verified
		result["verified"] = verified
		result["_effect_observed"] = effect
		if not verified:
			result["status"] = "unverified"

	# Batch notify property changes on all modified nodes
	for node in modified_nodes:
		if is_instance_valid(node):
			node.notify_property_list_changed()


func _values_match(actual, expected) -> bool:
	if actual is Vector3 and expected is Vector3:
		return (actual as Vector3).is_equal_approx(expected as Vector3)
	if actual is Vector2 and expected is Vector2:
		return (actual as Vector2).is_equal_approx(expected as Vector2)
	if actual is Color and expected is Color:
		return (actual as Color).is_equal_approx(expected as Color)
	if (actual is float or actual is int) and (expected is float or expected is int):
		return is_equal_approx(float(actual), float(expected))
	return actual == expected


# Ops whose effect is a serializable property override (allowed on nodes
# inside instances marked Editable Children).
const _INSTANCE_PROPERTY_OPS: Array[String] = ["move", "rotate", "scale", "set_property", "set_anchors"]
# Ops that restructure the tree: never serializable for instance-internal
# nodes, not even with Editable Children (the editor UI forbids them too).
const _INSTANCE_STRUCTURAL_OPS: Array[String] = ["delete", "rename", "reparent"]


func _execute_node_op(op_data: Dictionary, scene_root: Node, ur) -> Dictionary:
	var op: String = str(op_data.get("op", ""))
	var guard := _instance_internal_guard(op, op_data, scene_root)
	if not guard.is_empty():
		return guard
	match op:
		"move":
			return _op_move(op_data, scene_root, ur)
		"rotate":
			return _op_rotate(op_data, scene_root, ur)
		"scale":
			return _op_scale(op_data, scene_root, ur)
		"set_property":
			return _op_set_property(op_data, scene_root, ur)
		"add_child":
			return _op_add_child(op_data, scene_root, ur)
		"delete":
			return _op_delete(op_data, scene_root, ur)
		"duplicate":
			return _op_duplicate(op_data, scene_root, ur)
		"reparent":
			return _op_reparent(op_data, scene_root, ur)
		"set_anchors":
			return _op_set_anchors(op_data, scene_root, ur)
		"rename":
			return _op_rename(op_data, scene_root, ur)
		"get_property":
			return _op_get_property(op_data, scene_root)
		_:
			return {"op": op, "status": "error", "error": "Unknown operation: %s" % op}


func _find_node_by_name_or_path(name_or_path: String, scene_root: Node) -> Node:
	var node := scene_root.get_node_or_null(NodePath(name_or_path))
	if node != null:
		return node
	return _find_by_name_recursive(scene_root, name_or_path)


## Blocks mutations that would be silently dropped on save because the target
## node is internal to an instanced child scene (owner != scene_root, E7).
## Property overrides are allowed when the instance has Editable Children
## enabled — those DO serialize. Returns {} when the op may proceed.
func _instance_internal_guard(op: String, op_data: Dictionary, scene_root: Node) -> Dictionary:
	var target_key := ""
	if op in _INSTANCE_PROPERTY_OPS or op in _INSTANCE_STRUCTURAL_OPS or op == "duplicate":
		target_key = "node"
	elif op == "add_child":
		target_key = "parent"
	else:
		return {}
	var name_or_path := str(op_data.get(target_key, ""))
	if name_or_path.is_empty():
		return {}  # let the op report its own missing-param error
	var node := _find_node_by_name_or_path(name_or_path, scene_root)
	if node == null or node == scene_root or node.owner == scene_root:
		return {}  # not found (op reports it), or a regular owned node
	var instance_root := _owned_instance_ancestor(node, scene_root)
	if instance_root == null:
		return {
			"op": op,
			"node": name_or_path,
			"status": "error",
			"code": "INSTANCE_INTERNAL_NODE",
			"error": (
				"Node '%s' is not owned by the edited scene, so this change would be "
				+ "silently lost on save (likely an instance-internal or runtime-created node)."
			) % name_or_path,
		}
	var editable: bool = scene_root.is_editable_instance(instance_root)
	if editable and (op in _INSTANCE_PROPERTY_OPS or op == "add_child" or op == "duplicate"):
		return {}  # serializable as overrides / added nodes
	var source_scene := str(instance_root.scene_file_path)
	var message: String
	if editable:
		message = (
			"Node '%s' is internal to instanced scene '%s': %s cannot be serialized "
			+ "even with Editable Children. Edit the source scene '%s' directly."
		) % [name_or_path, str(instance_root.name), op, source_scene]
	else:
		message = (
			"Node '%s' is internal to instanced scene '%s' (Editable Children is OFF): "
			+ "the change would apply live but be silently lost on save. Enable Editable "
			+ "Children on '%s' for property overrides, or edit the source scene '%s' directly."
		) % [name_or_path, str(instance_root.name), str(instance_root.name), source_scene]
	return {
		"op": op,
		"node": name_or_path,
		"status": "error",
		"code": "INSTANCE_INTERNAL_NODE",
		"error": message,
	}


## Walks up from an instance-internal node to the instance root that the
## edited scene actually owns (handles nested instances).
func _owned_instance_ancestor(node: Node, scene_root: Node) -> Node:
	var current := node.get_parent()
	while current != null and current != scene_root:
		if current.owner == scene_root and not str(current.scene_file_path).is_empty():
			return current
		current = current.get_parent()
	return null


func _op_move(op_data: Dictionary, scene_root: Node, ur) -> Dictionary:
	var node_name: String = str(op_data.get("node", ""))
	var node := _find_node_by_name_or_path(node_name, scene_root)
	if node == null:
		return {"op": "move", "node": node_name, "status": "error", "error": "Node not found: %s" % node_name}

	var pos = op_data.get("position", op_data.get("value", [0, 0, 0]))
	if not _is_numeric_array(pos, 2):
		return {"op": "move", "node": node_name, "status": "error", "error": "position must be an array of at least 2 numbers"}
	var new_pos_value  # Variant: Vector3 or Vector2
	if node is Node3D:
		if not _is_numeric_array(pos, 3):
			return {"op": "move", "node": node_name, "status": "error", "error": "Node3D position requires [x, y, z] numbers"}
		var old_pos := (node as Node3D).position
		new_pos_value = Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
		ur.add_do_property(node, "position", new_pos_value)
		ur.add_undo_property(node, "position", old_pos)
	elif node is Node2D:
		var old_pos := (node as Node2D).position
		new_pos_value = Vector2(float(pos[0]), float(pos[1]))
		ur.add_do_property(node, "position", new_pos_value)
		ur.add_undo_property(node, "position", old_pos)
	elif node is Control:
		var old_pos := (node as Control).position
		new_pos_value = Vector2(float(pos[0]), float(pos[1]))
		ur.add_do_property(node, "position", new_pos_value)
		ur.add_undo_property(node, "position", old_pos)
	else:
		return {"op": "move", "node": node_name, "status": "error", "error": "Node does not support position"}

	return {"op": "move", "node": node_name, "status": "ok", "_verify": "property", "_node_ref": node, "_prop_name": "position", "_expected": new_pos_value}


func _op_rotate(op_data: Dictionary, scene_root: Node, ur) -> Dictionary:
	var node_name: String = str(op_data.get("node", ""))
	var node := _find_node_by_name_or_path(node_name, scene_root)
	if node == null:
		return {"op": "rotate", "node": node_name, "status": "error", "error": "Node not found: %s" % node_name}

	if not (node is Node3D):
		return {"op": "rotate", "node": node_name, "status": "error", "error": "Rotate only supports Node3D"}

	var rot = op_data.get("rotation", op_data.get("value", [0, 0, 0]))
	if not _is_numeric_array(rot, 3):
		return {"op": "rotate", "node": node_name, "status": "error", "error": "rotation requires [x, y, z] numbers"}
	var n3d: Node3D = node
	var old_rot := n3d.rotation_degrees
	var new_rot := Vector3(float(rot[0]), float(rot[1]), float(rot[2]))
	ur.add_do_property(node, "rotation_degrees", new_rot)
	ur.add_undo_property(node, "rotation_degrees", old_rot)
	return {"op": "rotate", "node": node_name, "status": "ok", "_verify": "property", "_node_ref": node, "_prop_name": "rotation_degrees", "_expected": new_rot}


func _op_scale(op_data: Dictionary, scene_root: Node, ur) -> Dictionary:
	var node_name: String = str(op_data.get("node", ""))
	var node := _find_node_by_name_or_path(node_name, scene_root)
	if node == null:
		return {"op": "scale", "node": node_name, "status": "error", "error": "Node not found: %s" % node_name}

	if not (node is Node3D):
		return {"op": "scale", "node": node_name, "status": "error", "error": "Scale only supports Node3D"}

	var sc = op_data.get("scale", op_data.get("value", [1, 1, 1]))
	if not _is_numeric_array(sc, 3):
		return {"op": "scale", "node": node_name, "status": "error", "error": "scale requires [x, y, z] numbers"}
	var n3d: Node3D = node
	var old_scale := n3d.scale
	var new_scale := Vector3(float(sc[0]), float(sc[1]), float(sc[2]))
	ur.add_do_property(node, "scale", new_scale)
	ur.add_undo_property(node, "scale", old_scale)
	return {"op": "scale", "node": node_name, "status": "ok", "_verify": "property", "_node_ref": node, "_prop_name": "scale", "_expected": new_scale}


func _op_set_property(op_data: Dictionary, scene_root: Node, ur) -> Dictionary:
	var node_name: String = str(op_data.get("node", ""))
	var node := _find_node_by_name_or_path(node_name, scene_root)
	if node == null:
		return {"op": "set_property", "node": node_name, "status": "error", "error": "Node not found: %s" % node_name}

	var property: String = str(op_data.get("property", ""))
	var value = op_data.get("value")

	# Handle sub-path syntax (e.g., "position:x")
	var parts := property.split(":")
	var base_property: String = parts[0]

	var old_value = node.get(base_property)
	if old_value == null:
		return {"op": "set_property", "node": node_name, "status": "error", "error": "Property not found: %s" % property}

	if parts.size() > 1:
		# Sub-path: modify only the component
		if not (value is int or value is float):
			return {"op": "set_property", "node": node_name, "status": "error", "error": "Sub-path '%s' requires a numeric value" % property}
		var sub_path: String = parts[1]
		var ref_value = old_value
		if ref_value is Vector3:
			var v := Vector3(ref_value.x, ref_value.y, ref_value.z)
			match sub_path:
				"x": v.x = float(value)
				"y": v.y = float(value)
				"z": v.z = float(value)
			value = v
		elif ref_value is Vector2:
			var v := Vector2(ref_value.x, ref_value.y)
			match sub_path:
				"x": v.x = float(value)
				"y": v.y = float(value)
			value = v
		elif ref_value is Color:
			var c := Color(ref_value.r, ref_value.g, ref_value.b, ref_value.a)
			match sub_path:
				"r": c.r = float(value)
				"g": c.g = float(value)
				"b": c.b = float(value)
				"a": c.a = float(value)
			value = c
		else:
			return {"op": "set_property", "node": node_name, "status": "error", "error": "Sub-path not supported for type: %s" % typeof(ref_value)}
	else:
		value = _convert_value(value, old_value)

	ur.add_do_property(node, base_property, value)
	ur.add_undo_property(node, base_property, old_value)
	return {"op": "set_property", "node": node_name, "status": "ok", "property": property, "_verify": "property", "_node_ref": node, "_prop_name": base_property, "_expected": value}


func _op_add_child(op_data: Dictionary, scene_root: Node, ur) -> Dictionary:
	var parent_name: String = str(op_data.get("parent", ""))
	var parent := _find_node_by_name_or_path(parent_name, scene_root)
	if parent == null:
		return {"op": "add_child", "status": "error", "error": "Parent not found: %s" % parent_name}

	var new_node: Node = null
	var scene_path: String = str(op_data.get("scene", ""))
	var type_name: String = str(op_data.get("type", ""))

	if scene_path != "":
		var packed = ResourceLoader.load(scene_path)
		if packed == null or not (packed is PackedScene):
			return {"op": "add_child", "status": "error", "error": "Failed to load scene: %s" % scene_path}
		new_node = packed.instantiate()
		if new_node == null:
			return {"op": "add_child", "status": "error", "error": "Scene could not be instantiated: %s" % scene_path}
	elif type_name != "":
		if not ClassDB.class_exists(type_name) or not ClassDB.can_instantiate(type_name):
			return {"op": "add_child", "status": "error", "error": "Cannot instantiate type: %s" % type_name}
		new_node = ClassDB.instantiate(type_name)
	else:
		return {"op": "add_child", "status": "error", "error": "Must provide 'scene' or 'type'"}

	var child_name: String = str(op_data.get("name", "NewNode"))
	new_node.name = child_name

	# Validate position BEFORE the first undo/redo registration: a malformed
	# value must produce a per-op error, never a mid-action runtime crash.
	var pos = op_data.get("position", null)
	if pos != null and not _is_numeric_array(pos, 2):
		new_node.free()
		return {"op": "add_child", "node": child_name, "status": "error", "error": "position must be an array of at least 2 numbers"}

	ur.add_do_method(parent, "add_child", new_node)
	ur.add_do_method(self, "_set_owner_recursive", new_node, scene_root)
	ur.add_do_reference(new_node)
	ur.add_undo_method(parent, "remove_child", new_node)

	# Set position after adding if provided
	if pos is Array and pos.size() >= 2:
		if new_node is Node3D and pos.size() >= 3:
			ur.add_do_property(new_node, "position", Vector3(float(pos[0]), float(pos[1]), float(pos[2])))
		elif new_node is Node2D or new_node is Control:
			ur.add_do_property(new_node, "position", Vector2(float(pos[0]), float(pos[1])))

	return {"op": "add_child", "node": child_name, "parent": parent_name, "status": "ok", "_verify": "child_present", "_node_ref": new_node, "_parent_ref": parent}


func _op_delete(op_data: Dictionary, scene_root: Node, ur) -> Dictionary:
	var node_name: String = str(op_data.get("node", ""))
	var node := _find_node_by_name_or_path(node_name, scene_root)
	if node == null:
		return {"op": "delete", "node": node_name, "status": "error", "error": "Node not found: %s" % node_name}

	if node == scene_root:
		return {"op": "delete", "node": node_name, "status": "error", "error": "Cannot delete scene root"}

	var parent := node.get_parent()
	ur.add_do_method(parent, "remove_child", node)
	ur.add_undo_method(parent, "add_child", node)
	ur.add_undo_method(node, "set_owner", scene_root)
	ur.add_undo_reference(node)
	return {"op": "delete", "node": node_name, "status": "ok", "_verify": "delete", "_node_ref": node}


func _op_duplicate(op_data: Dictionary, scene_root: Node, ur) -> Dictionary:
	var node_name: String = str(op_data.get("node", ""))
	var node := _find_node_by_name_or_path(node_name, scene_root)
	if node == null:
		return {"op": "duplicate", "node": node_name, "status": "error", "error": "Node not found: %s" % node_name}

	var dup := node.duplicate()
	var dup_name: String = str(op_data.get("name", str(node.name) + "_copy"))
	dup.name = dup_name

	var parent := node.get_parent()
	ur.add_do_method(parent, "add_child", dup)
	ur.add_do_method(self, "_set_owner_recursive", dup, scene_root)
	ur.add_do_reference(dup)
	ur.add_undo_method(parent, "remove_child", dup)
	return {"op": "duplicate", "node": node_name, "new_name": dup_name, "status": "ok", "_verify": "child_present", "_node_ref": dup, "_parent_ref": parent}


func _op_reparent(op_data: Dictionary, scene_root: Node, ur) -> Dictionary:
	var node_name: String = str(op_data.get("node", ""))
	var node := _find_node_by_name_or_path(node_name, scene_root)
	if node == null:
		return {"op": "reparent", "node": node_name, "status": "error", "error": "Node not found: %s" % node_name}

	var new_parent_name: String = str(op_data.get("new_parent", ""))
	var new_parent := _find_node_by_name_or_path(new_parent_name, scene_root)
	if new_parent == null:
		return {"op": "reparent", "node": node_name, "status": "error", "error": "New parent not found: %s" % new_parent_name}

	var old_parent := node.get_parent()
	ur.add_do_method(old_parent, "remove_child", node)
	ur.add_do_method(new_parent, "add_child", node)
	ur.add_do_method(self, "_set_owner_recursive", node, scene_root)
	ur.add_undo_method(new_parent, "remove_child", node)
	ur.add_undo_method(old_parent, "add_child", node)
	ur.add_undo_method(self, "_set_owner_recursive", node, scene_root)
	return {"op": "reparent", "node": node_name, "new_parent": new_parent_name, "status": "ok", "_verify": "reparent", "_node_ref": node, "_parent_ref": new_parent}


func _op_set_anchors(op_data: Dictionary, scene_root: Node, ur) -> Dictionary:
	var node_name: String = str(op_data.get("node", ""))
	var node := _find_node_by_name_or_path(node_name, scene_root)
	if node == null:
		return {"op": "set_anchors", "node": node_name, "status": "error", "error": "Node not found: %s" % node_name}

	if not (node is Control):
		return {"op": "set_anchors", "node": node_name, "status": "error", "error": "Node is not a Control: %s" % node_name}

	var ctrl: Control = node as Control
	var old_anchors: Array = [ctrl.anchor_left, ctrl.anchor_top, ctrl.anchor_right, ctrl.anchor_bottom]
	var new_anchors: Array = []

	var preset_name: String = str(op_data.get("preset", ""))

	if preset_name != "":
		var preset_map: Dictionary = {
			"top_left": Control.PRESET_TOP_LEFT,
			"top_right": Control.PRESET_TOP_RIGHT,
			"bottom_left": Control.PRESET_BOTTOM_LEFT,
			"bottom_right": Control.PRESET_BOTTOM_RIGHT,
			"center_left": Control.PRESET_CENTER_LEFT,
			"center_top": Control.PRESET_CENTER_TOP,
			"center_right": Control.PRESET_CENTER_RIGHT,
			"center_bottom": Control.PRESET_CENTER_BOTTOM,
			"center": Control.PRESET_CENTER,
			"left_wide": Control.PRESET_LEFT_WIDE,
			"top_wide": Control.PRESET_TOP_WIDE,
			"right_wide": Control.PRESET_RIGHT_WIDE,
			"bottom_wide": Control.PRESET_BOTTOM_WIDE,
			"vcenter_wide": Control.PRESET_VCENTER_WIDE,
			"hcenter_wide": Control.PRESET_HCENTER_WIDE,
			"full_rect": Control.PRESET_FULL_RECT,
		}

		if not preset_map.has(preset_name):
			return {"op": "set_anchors", "node": node_name, "status": "error", "error": "Unknown preset: %s" % preset_name}

		var preset_val: int = preset_map[preset_name]
		ctrl.set_anchors_preset(preset_val)
		new_anchors = [ctrl.anchor_left, ctrl.anchor_top, ctrl.anchor_right, ctrl.anchor_bottom]
		# Restore old values so undo_redo can apply them properly
		ctrl.anchor_left = old_anchors[0]
		ctrl.anchor_top = old_anchors[1]
		ctrl.anchor_right = old_anchors[2]
		ctrl.anchor_bottom = old_anchors[3]

	elif op_data.has("anchors"):
		var anchors = op_data["anchors"]
		if not _is_numeric_array(anchors, 4):
			return {"op": "set_anchors", "node": node_name, "status": "error", "error": "anchors requires [left, top, right, bottom] numbers"}
		new_anchors = [float(anchors[0]), float(anchors[1]), float(anchors[2]), float(anchors[3])]

	else:
		return {"op": "set_anchors", "node": node_name, "status": "error", "error": "Provide 'preset' name or 'anchors' [left, top, right, bottom]"}

	ur.add_do_property(ctrl, "anchor_left", new_anchors[0])
	ur.add_do_property(ctrl, "anchor_top", new_anchors[1])
	ur.add_do_property(ctrl, "anchor_right", new_anchors[2])
	ur.add_do_property(ctrl, "anchor_bottom", new_anchors[3])
	ur.add_undo_property(ctrl, "anchor_left", old_anchors[0])
	ur.add_undo_property(ctrl, "anchor_top", old_anchors[1])
	ur.add_undo_property(ctrl, "anchor_right", old_anchors[2])
	ur.add_undo_property(ctrl, "anchor_bottom", old_anchors[3])

	var result: Dictionary = {"op": "set_anchors", "node": node_name, "status": "ok", "anchors": new_anchors, "_verify": "anchors", "_node_ref": ctrl, "_expected_anchors": new_anchors}
	if preset_name != "":
		result["preset"] = preset_name
	return result


func _op_rename(op_data: Dictionary, scene_root: Node, ur) -> Dictionary:
	var node_name: String = str(op_data.get("node", ""))
	var new_name: String = str(op_data.get("new_name", ""))
	var node := _find_node_by_name_or_path(node_name, scene_root)
	if node == null:
		return {"op": "rename", "node": node_name, "status": "error", "error": "Node not found: %s" % node_name}
	if new_name.is_empty():
		return {"op": "rename", "node": node_name, "status": "error", "error": "new_name must not be empty"}
	var old_name: String = node.name
	ur.add_do_property(node, "name", new_name)
	ur.add_undo_property(node, "name", old_name)
	return {"op": "rename", "node": node_name, "status": "ok", "new_name": new_name, "_verify": "rename", "_node_ref": node, "_old_name": old_name}


func _op_get_property(op_data: Dictionary, scene_root: Node) -> Dictionary:
	var node_name: String = str(op_data.get("node", ""))
	var property_name: String = str(op_data.get("property", ""))
	var node := _find_node_by_name_or_path(node_name, scene_root)
	if node == null:
		return {"op": "get_property", "node": node_name, "status": "error", "error": "Node not found: %s" % node_name}
	if property_name.is_empty():
		return {"op": "get_property", "node": node_name, "status": "error", "error": "property must not be empty"}

	# Check property exists via property list
	var found := false
	for prop in node.get_property_list():
		if prop["name"] == property_name:
			found = true
			break
	if not found:
		return {"op": "get_property", "node": node_name, "status": "error", "error": "Property not found: %s" % property_name}

	var value = node.get(property_name)
	return {"op": "get_property", "node": node_name, "status": "ok", "property": property_name, "value": _value_to_json(value)}


func _value_to_json(value) -> Variant:
	if value == null:
		return null
	if value is int or value is float or value is bool or value is String:
		return value
	if value is Vector2:
		return [snapped(value.x, 0.001), snapped(value.y, 0.001)]
	if value is Vector3:
		return [snapped(value.x, 0.001), snapped(value.y, 0.001), snapped(value.z, 0.001)]
	if value is Color:
		return [snapped(value.r, 0.001), snapped(value.g, 0.001), snapped(value.b, 0.001), snapped(value.a, 0.001)]
	if value is Array:
		var arr: Array = []
		for item in value:
			arr.append(_value_to_json(item))
		return arr
	if value is Dictionary:
		var dict: Dictionary = {}
		for key in value.keys():
			dict[str(key)] = _value_to_json(value[key])
		return dict
	if value is Transform3D:
		var b: Basis = value.basis
		return {
			"origin": [snapped(value.origin.x, 0.001), snapped(value.origin.y, 0.001), snapped(value.origin.z, 0.001)],
			"basis": [
				[snapped(b.x.x, 0.001), snapped(b.x.y, 0.001), snapped(b.x.z, 0.001)],
				[snapped(b.y.x, 0.001), snapped(b.y.y, 0.001), snapped(b.y.z, 0.001)],
				[snapped(b.z.x, 0.001), snapped(b.z.y, 0.001), snapped(b.z.z, 0.001)],
			],
		}
	return str(value)


func _is_numeric_array(value, min_size: int) -> bool:
	if not (value is Array) or value.size() < min_size:
		return false
	for i in range(min_size):
		if not (value[i] is int or value[i] is float):
			return false
	return true


func _to_vector3(value, fallback: Vector3 = Vector3.ZERO) -> Vector3:
	if value is Vector3:
		return value
	if value is Vector3i:
		return Vector3(value.x, value.y, value.z)
	if value is Dictionary:
		return Vector3(
			float(value.get("x", fallback.x)),
			float(value.get("y", fallback.y)),
			float(value.get("z", fallback.z))
		)
	if value is Array and value.size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return fallback


func _to_vector2(value, fallback: Vector2 = Vector2.ZERO) -> Vector2:
	if value is Vector2:
		return value
	if value is Vector2i:
		return Vector2(value.x, value.y)
	if value is Dictionary:
		return Vector2(
			float(value.get("x", fallback.x)),
			float(value.get("y", fallback.y))
		)
	if value is Array and value.size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	return fallback


func _to_color(value, fallback: Color = Color.WHITE) -> Color:
	if value is Color:
		return value
	if value is String:
		return Color(value)
	if value is Dictionary:
		return Color(
			float(value.get("r", fallback.r)),
			float(value.get("g", fallback.g)),
			float(value.get("b", fallback.b)),
			float(value.get("a", 1.0))
		)
	if value is Array and value.size() >= 3:
		var a: float = float(value[3]) if value.size() >= 4 else 1.0
		return Color(float(value[0]), float(value[1]), float(value[2]), a)
	return fallback


func _convert_value(value, reference_value):
	if reference_value is Vector3:
		return _to_vector3(value, reference_value)
	elif reference_value is Vector2:
		return _to_vector2(value, reference_value)
	elif reference_value is Color:
		return _to_color(value, reference_value)
	elif reference_value is int and (value is int or value is float):
		return int(value)
	elif reference_value is float and (value is int or value is float):
		return float(value)
	elif reference_value is bool:
		return bool(value)
	return value


func _set_owner_recursive(node: Node, owner: Node) -> void:
	node.owner = owner
	for child in node.get_children():
		_set_owner_recursive(child, owner)


func _handle_undo_history(peer_id: int, id: String, _params: Dictionary) -> void:
	if undo_redo == null:
		_send_error(peer_id, id, "NO_UNDO_REDO", "UndoRedo manager not available")
		return

	# EditorUndoRedoManager: get the scene history's UndoRedo for has_undo/redo
	var can_undo: bool = false
	var can_redo: bool = false
	var current_action: String = ""

	# Try scene history (id 0 = global, 1+ = scene-specific)
	if undo_redo.has_method("get_history_undo_redo"):
		var scene_ur = undo_redo.get_history_undo_redo(0)
		if scene_ur != null:
			can_undo = scene_ur.has_undo()
			can_redo = scene_ur.has_redo()
			current_action = scene_ur.get_current_action_name()

	send_response(peer_id, id, {
		"can_undo": can_undo,
		"can_redo": can_redo,
		"current_action": current_action,
		"godotiq_actions": _godotiq_action_history,
		"total_godotiq_actions": _godotiq_action_history.size(),
	})


func _handle_exec_editor(peer_id: int, id: String, params: Dictionary) -> void:
	var code: String = params.get("code", "")
	# timeout_ms is enforced by the Python bridge timeout; editor execution here is synchronous.

	if code.is_empty():
		_send_error(peer_id, id, "EXEC_ERROR", "No code provided")
		return

	# Safety: must contain func run():
	if code.find("func run():") == -1 and code.find("func run() ->") == -1:
		send_response(peer_id, id, {
			"status": "BLOCKED",
			"result": "",
			"error": "Code must contain 'func run():' or 'func run() -> Type:'",
		})
		return

	# Safety: blocked patterns
	# Safety: blocked patterns — keep in sync with godotiq_runtime.gd and Python exec_code._BLOCKED_PATTERNS
	# Note: DirAccess.remove also catches DirAccess.remove_absolute() via substring match
	var blocked_patterns: Array = [
		"DirAccess.remove",
		"DirAccess.open",
		"FileAccess.open",
		"FileAccess.get_file_as_string",
		"FileAccess.get_file_as_bytes",
		"OS.execute",
		"OS.kill",
		"OS.shell_open",
	]
	for pattern in blocked_patterns:
		if code.find(pattern) != -1:
			send_response(peer_id, id, {
				"status": "BLOCKED",
				"result": "",
				"error": "Blocked pattern found: %s" % pattern,
			})
			return

	# Compile the script — capture errors via Logger if available
	# Prepend offset: "@tool\nextends Node\n\n" = 3 lines
	var _exec_prepend_lines: int = 3
	if _has_logger:
		_clear_script_errors()
		_error_logger.capture_all = true
	var script := GDScript.new()
	script.source_code = "@tool\nextends Node\n\n" + code
	var err: int = script.reload()
	if _has_logger:
		_error_logger.capture_all = false
	if err != OK:
		var resp := {
			"status": "COMPILE_ERROR",
			"result": "",
			"error": "Compilation failed (error %d: %s). Check GDScript syntax." % [err, error_string(err)],
		}
		if _has_logger:
			var captured := _get_script_errors()
			if not captured.is_empty():
				var details: Array = []
				for entry in captured:
					var adj_line: int = maxi(entry.get("line", 0) - _exec_prepend_lines, 1)
					details.append({"line": adj_line, "message": entry.get("message", "")})
				resp["error_detail"] = details
		send_response(peer_id, id, resp)
		return

	# Instantiate and execute
	var obj = script.new()
	if obj == null:
		# Fallback to file-based approach (Godot bug #87046)
		var file_result: Dictionary = _exec_editor_via_file(code)
		send_response(peer_id, id, file_result)
		return

	# Add as temporary child — gives obj get_tree(), get_parent(), etc.
	add_child(obj)

	var result = null
	var exec_error: String = ""
	if obj.has_method("run"):
		result = obj.run()
	else:
		exec_error = "Script compiled but has no run() method"

	# Cleanup
	remove_child(obj)
	obj.queue_free()

	if not exec_error.is_empty():
		send_response(peer_id, id, {
			"status": "ERROR",
			"result": "",
			"error": exec_error,
		})
		return

	var result_str: String = ""
	if result != null:
		result_str = str(result)
	else:
		result_str = "null"

	send_response(peer_id, id, {
		"status": "OK",
		"result": result_str,
		"error": "",
	})


func _exec_editor_via_file(code: String) -> Dictionary:
	_exec_counter += 1
	var tmp_path: String = "res://addons/godotiq/_temp_exec_%d.gd" % _exec_counter

	var file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		return {
			"status": "ERROR",
			"result": "",
			"error": "Cannot create temp file: %s" % str(FileAccess.get_open_error()),
		}
	file.store_string("@tool\nextends Node\n\n" + code)
	file.close()

	var script = load(tmp_path)
	if script == null:
		DirAccess.remove_absolute(tmp_path)
		return {
			"status": "ERROR",
			"result": "",
			"error": "Failed to load temp script. Godot may need a filesystem scan.",
		}

	var obj = script.new()
	if obj == null:
		DirAccess.remove_absolute(tmp_path)
		return {
			"status": "ERROR",
			"result": "",
			"error": "Failed to instantiate temp script",
		}

	add_child(obj)
	var result = null
	if obj.has_method("run"):
		result = obj.run()
	remove_child(obj)
	obj.queue_free()

	# Cleanup temp file
	DirAccess.remove_absolute(tmp_path)

	var result_str: String = ""
	if result != null:
		result_str = str(result)
	else:
		result_str = "null"

	return {
		"status": "OK",
		"result": result_str,
		"error": "",
	}


func _handle_save_scene(peer_id: int, id: String, params: Dictionary) -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		_send_error(peer_id, id, "NO_SCENE", "No scene is currently open in the editor")
		return

	var scene_path: String = scene_root.scene_file_path

	# Optional guard: refuse to save when a different scene than the caller
	# expects is active (E2/E3 — wrong-tab edits persisted or stranded).
	var expected_scene := str(params.get("expected_scene", ""))
	if not expected_scene.is_empty() and expected_scene != scene_path:
		_send_error(peer_id, id, "SCENE_MISMATCH",
			"Active scene is '%s' but expected_scene is '%s' — nothing was saved. Open the expected scene first (godotiq_exec: EditorInterface.open_scene_from_path)." % [scene_path, expected_scene])
		return

	var existed_before := scene_path != "" and FileAccess.file_exists(scene_path)
	var mtime_before: int = FileAccess.get_modified_time(scene_path) if existed_before else 0

	var err: int = EditorInterface.save_scene()

	var exists_after := scene_path != "" and FileAccess.file_exists(scene_path)
	var mtime_changed := exists_after and FileAccess.get_modified_time(scene_path) != mtime_before
	var saved := err == OK and exists_after
	# EditorInterface.save_scene() returns OK even when ResourceSaver fails
	# (verified live: read-only dir -> OK, file untouched). When the timestamp
	# did not move, a write probe disambiguates the permission failure from a
	# legitimate same-second rewrite — the probe never fails on writable paths.
	var write_failed := false
	if saved and existed_before and not mtime_changed and not _scene_write_probe(scene_path):
		write_failed = true
		saved = false
		err = ERR_FILE_CANT_WRITE

	# Compute feedback: file size and node count
	var file_size_kb := 0
	if exists_after:
		var f := FileAccess.open(scene_path, FileAccess.READ)
		if f != null:
			file_size_kb = maxi(1, int(f.get_length() / 1024.0))
			f.close()

	var node_count := _count_nodes(scene_root)

	var response := {
		"saved": saved,
		"scene_path": scene_path,
		"scene_name": scene_root.name,
		"file_size_kb": file_size_kb,
		"node_count": node_count,
		# Informational only (1-second fs granularity): a save within the same
		# second as the previous write legitimately reports false.
		"file_mtime_changed": mtime_changed,
	}
	if not saved:
		var detail := ""
		if write_failed:
			detail = "; the scene file/directory is not writable (check permissions and the editor log)"
		elif not exists_after:
			detail = "; file missing: %s" % scene_path
		response["error_code"] = err
		response["error"] = (
			"save_scene failed (Error %d)%s — the scene was NOT written to disk."
			% [err, detail]
		)
		_record_error("save_scene failed for '%s' (Error %d)" % [scene_path, err])
	send_response(peer_id, id, response)


## True when both the scene file and its directory accept writes. READ_WRITE
## does not truncate, and the directory probe file is removed immediately.
func _scene_write_probe(scene_path: String) -> bool:
	var f := FileAccess.open(scene_path, FileAccess.READ_WRITE)
	if f == null:
		return false
	f.close()
	var probe_path := scene_path.get_base_dir().path_join(".godotiq_write_probe.tmp")
	var p := FileAccess.open(probe_path, FileAccess.WRITE)
	if p == null:
		return false
	p.close()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(probe_path))
	return true


func _count_nodes(root: Node) -> int:
	var count := 1
	for child in root.get_children():
		count += _count_nodes(child)
	return count


func _handle_editor_screenshot(peer_id: int, id: String, params: Dictionary) -> void:
	# Ensure 3D viewport is active — without this, screenshot may capture Script tab
	EditorInterface.set_main_screen_editor("3D")

	var scale: float = params.get("scale", 0.25)
	var quality: float = clampf(params.get("quality", 0.5), 0.1, 1.0)
	var fmt: String = params.get("format", "webp")
	var region: Array = params.get("region", [])

	var viewport_3d := EditorInterface.get_editor_viewport_3d(0)
	if viewport_3d == null:
		_send_error(peer_id, id, "NO_VIEWPORT", "Editor 3D viewport not available. Is a 3D scene open?")
		return

	var camera := viewport_3d.get_camera_3d()
	if camera == null:
		_send_error(peer_id, id, "NO_CAMERA", "Editor 3D camera not available. Is a 3D scene open?")
		return

	# If camera override requested, move camera then defer capture to next frame
	var camera_moved: bool = false
	var original_transform: Transform3D = camera.global_transform
	if params.has("camera_position"):
		var pos_arr: Array = params["camera_position"]
		if pos_arr.size() >= 3:
			camera_moved = true
			var new_pos := Vector3(float(pos_arr[0]), float(pos_arr[1]), float(pos_arr[2]))
			camera.global_position = new_pos

			if params.has("camera_target"):
				var tgt_arr: Array = params["camera_target"]
				if tgt_arr.size() >= 3:
					var target_pos := Vector3(float(tgt_arr[0]), float(tgt_arr[1]), float(tgt_arr[2]))
					if new_pos.distance_to(target_pos) > 0.001:
						camera.look_at(target_pos)

	if camera_moved:
		# Defer capture to next frame so viewport re-renders with new camera
		_pending_screenshot = {
			"peer_id": peer_id, "id": id, "viewport_3d": viewport_3d,
			"camera": camera, "original_transform": original_transform,
			"scale": scale, "quality": quality, "fmt": fmt, "region": region,
		}
		return

	# No camera move — capture current viewport texture immediately
	_do_editor_screenshot(peer_id, id, viewport_3d, camera, original_transform, false, scale, quality, fmt, region)


func _do_editor_screenshot(peer_id: int, id: String, viewport_3d: SubViewport, camera: Camera3D, original_transform: Transform3D, restore_camera: bool, scale: float, quality: float, fmt: String, region: Array = []) -> void:
	var img := viewport_3d.get_texture().get_image()
	if img == null:
		if restore_camera and camera != null:
			camera.global_transform = original_transform
		_send_error(peer_id, id, "CAPTURE_FAILED", "Failed to capture editor viewport image")
		return

	# Apply region crop before scaling
	if region.size() == 4:
		var rx: int = clampi(int(region[0]), 0, img.get_width())
		var ry: int = clampi(int(region[1]), 0, img.get_height())
		var rw: int = clampi(int(region[2]), 1, img.get_width() - rx)
		var rh: int = clampi(int(region[3]), 1, img.get_height() - ry)
		img = img.get_region(Rect2i(rx, ry, rw, rh))

	if scale < 1.0 and scale > 0.0:
		var new_width: int = int(img.get_width() * scale)
		var new_height: int = int(img.get_height() * scale)
		if new_width > 0 and new_height > 0:
			img.resize(new_width, new_height)

	var encoded: PackedByteArray
	var actual_format: String = fmt
	match fmt:
		"webp":
			encoded = img.save_webp_to_buffer(true, quality)
		"png":
			encoded = img.save_png_to_buffer()
		"jpg", "jpeg":
			encoded = img.save_jpg_to_buffer(quality)
			actual_format = "jpg"
		_:
			encoded = img.save_webp_to_buffer(true, quality)
			actual_format = "webp"

	# If encoded image is too large for WS buffer, progressively downscale
	var max_encoded_bytes: int = 45000
	while encoded.size() > max_encoded_bytes and img.get_width() > 100:
		var w: int = int(img.get_width() * 0.7)
		var h: int = int(img.get_height() * 0.7)
		img.resize(w, h)
		match actual_format:
			"webp":
				encoded = img.save_webp_to_buffer(true, quality)
			"png":
				encoded = img.save_png_to_buffer()
			"jpg":
				encoded = img.save_jpg_to_buffer(quality)

	var base64_str: String = Marshalls.raw_to_base64(encoded)

	if restore_camera and camera != null:
		camera.global_transform = original_transform

	send_response(peer_id, id, {
		"image": base64_str,
		"width": img.get_width(),
		"height": img.get_height(),
		"format": actual_format,
		"viewport": "editor",
	})


func _handle_camera(peer_id: int, id: String, params: Dictionary) -> void:
	# Ensure 3D viewport is active for camera operations
	EditorInterface.set_main_screen_editor("3D")

	var action: String = params.get("action", "get_position")

	var viewport_3d := EditorInterface.get_editor_viewport_3d(0)
	if viewport_3d == null:
		_send_error(peer_id, id, "NO_VIEWPORT", "Editor 3D viewport not available")
		return

	var camera := viewport_3d.get_camera_3d()
	if camera == null:
		_send_error(peer_id, id, "NO_CAMERA", "Editor 3D camera not available")
		return

	match action:
		"get_position":
			var pos: Vector3 = camera.global_position
			var rot: Vector3 = camera.global_rotation_degrees
			var basis: Basis = camera.global_transform.basis
			var fwd: Vector3 = -basis.z

			send_response(peer_id, id, {
				"action": "get_position",
				"position": [snapped(pos.x, 0.01), snapped(pos.y, 0.01), snapped(pos.z, 0.01)],
				"rotation_degrees": [snapped(rot.x, 0.01), snapped(rot.y, 0.01), snapped(rot.z, 0.01)],
				"forward": [snapped(fwd.x, 0.01), snapped(fwd.y, 0.01), snapped(fwd.z, 0.01)],
				"fov": camera.fov,
			})

		"look_at":
			var pos_arr: Array = params.get("position", [])
			var tgt_arr: Array = params.get("target", [])

			if pos_arr.size() < 3:
				_send_error(peer_id, id, "MISSING_PARAM", "action 'look_at' requires 'position' [x,y,z]")
				return

			var new_pos := Vector3(float(pos_arr[0]), float(pos_arr[1]), float(pos_arr[2]))
			camera.global_position = new_pos

			if tgt_arr.size() >= 3:
				var target_pos := Vector3(float(tgt_arr[0]), float(tgt_arr[1]), float(tgt_arr[2]))
				if new_pos.distance_to(target_pos) > 0.001:
					camera.look_at(target_pos)

			var final_pos: Vector3 = camera.global_position
			var final_rot: Vector3 = camera.global_rotation_degrees

			send_response(peer_id, id, {
				"action": "look_at",
				"position": [snapped(final_pos.x, 0.01), snapped(final_pos.y, 0.01), snapped(final_pos.z, 0.01)],
				"rotation_degrees": [snapped(final_rot.x, 0.01), snapped(final_rot.y, 0.01), snapped(final_rot.z, 0.01)],
				"note": "Camera position is temporary — editor interpolation may reset it on user interaction.",
			})

		"focus_node":
			var node_name: String = params.get("node", "")
			if node_name.is_empty():
				_send_error(peer_id, id, "MISSING_PARAM", "action 'focus_node' requires 'node' name")
				return

			var scene_root := EditorInterface.get_edited_scene_root()
			if scene_root == null:
				_send_error(peer_id, id, "NO_SCENE", "No scene open in editor")
				return

			var target_node: Node = _find_node_by_name_or_path(node_name, scene_root)
			if target_node == null:
				_send_error(peer_id, id, "NODE_NOT_FOUND", "Node '%s' not found in scene" % node_name)
				return

			var selection := EditorInterface.get_selection()
			selection.clear()
			selection.add_node(target_node)

			var node_pos: Array = [0, 0, 0]
			if target_node is Node3D:
				var p: Vector3 = (target_node as Node3D).global_position
				node_pos = [snapped(p.x, 0.01), snapped(p.y, 0.01), snapped(p.z, 0.01)]

			send_response(peer_id, id, {
				"action": "focus_node",
				"node": str(target_node.name),
				"node_position": node_pos,
				"selected": true,
				"note": "Previous editor selection was replaced.",
				"hint": "Use editor_screenshot with camera_position near node_position to see it.",
			})

		_:
			_send_error(peer_id, id, "UNKNOWN_ACTION", "Unknown camera action: '%s'. Use get_position, look_at, or focus_node." % action)


# --- Build scene handler ---

const BUILD_SCENE_MAX_NODES: int = 256


func _handle_build_scene(peer_id: int, id: String, params: Dictionary) -> void:
	var preflight := _preflight_scene_check(params)
	if not preflight["ok"]:
		_send_error(peer_id, id, "PREFLIGHT_FAILED", preflight["error"])
		return
	var scene_root := EditorInterface.get_edited_scene_root()

	if undo_redo == null:
		_send_error(peer_id, id, "NO_UNDO_REDO", "UndoRedo manager not available")
		return

	# Resolve parent node (strip root node name from path if first segment matches)
	var parent_str: String = str(params.get("parent", ""))
	var original_parent_str: String = parent_str
	var parent: Node = scene_root
	if parent_str != "":
		var root_name: String = scene_root.name
		if parent_str == root_name:
			parent_str = ""
		elif parent_str.begins_with(root_name + "/"):
			parent_str = parent_str.substr(root_name.length() + 1)

		if parent_str != "":
			parent = _find_node_by_name_or_path(parent_str, scene_root)
			if parent == null:
				_send_error(peer_id, id, "PARENT_NOT_FOUND",
					"Parent node not found: %s (root node is '%s', use relative paths from root children)" % [original_parent_str, root_name])
				return

	# Expand pattern into flat node specs
	var specs: Array = _expand_build_pattern(params)

	# Safety cap
	var original_size: int = specs.size()
	var truncated := false
	if specs.size() > BUILD_SCENE_MAX_NODES:
		specs = specs.slice(0, BUILD_SCENE_MAX_NODES)
		truncated = true

	if specs.size() == 0:
		_send_error(peer_id, id, "NO_NODES", "Pattern expansion produced no nodes")
		return

	# Create single undo action
	var action_name := "GodotIQ: build %d nodes" % specs.size()
	undo_redo.create_action(action_name)

	var created: int = 0
	var errors: Array = []
	var node_names: Array = []

	for spec in specs:
		if not (spec is Dictionary):
			errors.append({"error": "Invalid spec format"})
			continue
		var result: Dictionary = _create_build_node(spec, parent, scene_root, undo_redo)
		if result.get("ok", false):
			created += 1
			node_names.append(result.get("name", ""))
		else:
			errors.append(result)

	if created > 0:
		undo_redo.commit_action()
		_godotiq_action_history.append({
			"action": action_name,
			"operations": created,
			"timestamp": Time.get_ticks_msec(),
		})
		if _godotiq_action_history.size() > MAX_HISTORY_SIZE:
			_godotiq_action_history = _godotiq_action_history.slice(
				_godotiq_action_history.size() - MAX_HISTORY_SIZE
			)

	send_response(peer_id, id, {
		"created": created,
		"node_names": node_names,
		"errors": errors,
		"total_requested": original_size,
		"parent": parent.name,
		"truncated": truncated,
	})
	EditorInterface.get_resource_filesystem().scan()


func _expand_build_pattern(params: Dictionary) -> Array:
	var offset: Array = params.get("offset", [0, 0, 0])
	if params.has("grid"):
		return _expand_build_grid(params["grid"], offset)
	if params.has("line"):
		return _expand_build_line(params["line"], offset)
	if params.has("scatter"):
		var scatter: Dictionary = params["scatter"]
		var items: Array = scatter.get("items", [])
		var off_x: float = float(offset[0])
		var off_y: float = float(offset[1])
		var off_z: float = float(offset[2])
		var index: int = 0
		for item in items:
			if item is Dictionary and item.has("position"):
				var pos: Array = item["position"]
				item["position"] = [float(pos[0]) + off_x, float(pos[1]) + off_y, float(pos[2]) + off_z]
			if item is Dictionary and not item.has("name"):
				item["name"] = "%s_%d" % [_build_spec_name_prefix(item), index]
			index += 1
		return items
	if params.has("nodes"):
		return params["nodes"]
	return []


func _build_spec_name_prefix(spec: Dictionary) -> String:
	if spec.has("prefix"):
		return str(spec["prefix"])
	var scene_path: String = str(spec.get("scene", ""))
	if scene_path != "":
		return scene_path.get_file().get_basename()
	var type_name: String = str(spec.get("type", ""))
	if type_name != "":
		return type_name
	return "BuildNode"


func _expand_build_grid(grid: Dictionary, offset: Array = [0, 0, 0]) -> Array:
	var scene_path: String = str(grid.get("scene", ""))
	var prefix: String
	if grid.has("prefix"):
		prefix = str(grid["prefix"])
	elif scene_path != "":
		prefix = scene_path.get_file().get_basename()
	else:
		prefix = "Node"
	var rows: int = int(grid.get("rows", 1))
	var cols: int = int(grid.get("cols", 1))
	var spacing: float = float(grid.get("spacing", 1.0))
	var origin: Array = grid.get("origin", [0, 0, 0])
	var axis: String = str(grid.get("axis", "xz"))
	var overrides: Dictionary = grid.get("overrides", {})
	var type_name: String = str(grid.get("type", ""))

	var ox: float = float(origin[0]) if origin.size() > 0 else 0.0
	var oy: float = float(origin[1]) if origin.size() > 1 else 0.0
	var oz: float = float(origin[2]) if origin.size() > 2 else 0.0
	var off_x: float = float(offset[0])
	var off_y: float = float(offset[1])
	var off_z: float = float(offset[2])

	var result: Array = []
	for row in range(rows):
		for col in range(cols):
			var cell_key := "%d,%d" % [row, col]
			var spec: Dictionary = {}

			if overrides.has(cell_key):
				spec = overrides[cell_key].duplicate()
				if not spec.has("scene") and scene_path != "":
					spec["scene"] = scene_path
				if not spec.has("type") and type_name != "":
					spec["type"] = type_name
			else:
				if scene_path != "":
					spec["scene"] = scene_path
				if type_name != "":
					spec["type"] = type_name

			if not spec.has("name"):
				spec["name"] = "%s_%d_%d" % [prefix, row, col]

			if not spec.has("position"):
				if axis == "xy":
					spec["position"] = [ox + col * spacing + off_x, oy + row * spacing + off_y, oz + off_z]
				else:  # "xz" default
					spec["position"] = [ox + col * spacing + off_x, oy + off_y, oz + row * spacing + off_z]
			else:
				var pos: Array = spec["position"]
				spec["position"] = [float(pos[0]) + off_x, float(pos[1]) + off_y, float(pos[2]) + off_z]

			result.append(spec)
	return result


func _expand_build_line(line: Dictionary, offset: Array = [0, 0, 0]) -> Array:
	var scene_path: String = str(line.get("scene", ""))
	var prefix: String
	if line.has("prefix"):
		prefix = str(line["prefix"])
	elif scene_path != "":
		prefix = scene_path.get_file().get_basename()
	else:
		prefix = "Node"
	var points: Array = line.get("points", [])
	var spacing: float = float(line.get("spacing", 1.0))
	var align_to_path: bool = line.get("align_to_path", false)
	var type_name: String = str(line.get("type", ""))
	var off_x: float = float(offset[0])
	var off_y: float = float(offset[1])
	var off_z: float = float(offset[2])

	if points.size() < 2 or spacing <= 0:
		return []

	var result: Array = []
	var index: int = 0

	# Place first node at start point with rotation from first segment
	var first_pt: Array = points[0]
	var first_spec: Dictionary = {"name": "%s_%d" % [prefix, index], "position": [float(first_pt[0]) + off_x, float(first_pt[1]) + off_y, float(first_pt[2]) + off_z]}
	if scene_path != "":
		first_spec["scene"] = scene_path
	if type_name != "":
		first_spec["type"] = type_name
	if align_to_path:
		var s0 := Vector3(float(points[0][0]), float(points[0][1]), float(points[0][2]))
		var s1 := Vector3(float(points[1][0]), float(points[1][1]), float(points[1][2]))
		var first_dir := (s1 - s0).normalized()
		if first_dir.length() > 0.001:
			first_spec["rotation"] = [0, rad_to_deg(atan2(first_dir.x, first_dir.z)), 0]
	result.append(first_spec)
	index += 1

	var remainder: float = 0.0

	for i in range(points.size() - 1):
		var start := Vector3(float(points[i][0]), float(points[i][1]), float(points[i][2]))
		var end := Vector3(float(points[i + 1][0]), float(points[i + 1][1]), float(points[i + 1][2]))
		var seg_dir := (end - start).normalized()
		var seg_len := (end - start).length()

		var y_rot: float = 0.0
		if align_to_path and seg_dir.length() > 0.001:
			y_rot = rad_to_deg(atan2(seg_dir.x, seg_dir.z))

		var dist_along := spacing - remainder
		while dist_along <= seg_len:
			var pos := start + seg_dir * dist_along
			var spec: Dictionary = {
				"name": "%s_%d" % [prefix, index],
				"position": [pos.x + off_x, pos.y + off_y, pos.z + off_z],
			}
			if scene_path != "":
				spec["scene"] = scene_path
			if type_name != "":
				spec["type"] = type_name
			if align_to_path:
				spec["rotation"] = [0, y_rot, 0]
			result.append(spec)
			index += 1
			dist_along += spacing

		# Remainder = how far past the segment end the next placement would be
		remainder = dist_along - seg_len

	# Endpoint inclusion: check if last placed node is near the final point
	var final_pt: Array = points[points.size() - 1]
	var final_pos := Vector3(float(final_pt[0]) + off_x, float(final_pt[1]) + off_y, float(final_pt[2]) + off_z)
	var place_endpoint := true
	if result.size() > 0:
		var last_spec: Dictionary = result[result.size() - 1]
		var last_pos_arr: Array = last_spec.get("position", [0, 0, 0])
		var last_pos := Vector3(float(last_pos_arr[0]), float(last_pos_arr[1]), float(last_pos_arr[2]))
		if last_pos.distance_to(final_pos) < spacing * 0.1:
			place_endpoint = false

	if place_endpoint:
		var end_spec: Dictionary = {
			"name": "%s_%d" % [prefix, index],
			"position": [final_pos.x + off_x, final_pos.y + off_y, final_pos.z + off_z],
		}
		if scene_path != "":
			end_spec["scene"] = scene_path
		if type_name != "":
			end_spec["type"] = type_name
		if align_to_path and points.size() >= 2:
			var last_seg_start := Vector3(float(points[points.size() - 2][0]), float(points[points.size() - 2][1]), float(points[points.size() - 2][2]))
			var last_dir := (final_pos - last_seg_start).normalized()
			if last_dir.length() > 0.001:
				end_spec["rotation"] = [0, rad_to_deg(atan2(last_dir.x, last_dir.z)), 0]
		result.append(end_spec)

	return result


func _create_build_node(spec: Dictionary, parent: Node, scene_root: Node, ur) -> Dictionary:
	var new_node: Node = null
	var scene_path: String = str(spec.get("scene", ""))
	var type_name: String = str(spec.get("type", ""))

	if scene_path != "":
		var packed = ResourceLoader.load(scene_path)
		if packed == null or not (packed is PackedScene):
			return {"ok": false, "error": "Failed to load scene: %s" % scene_path}
		new_node = packed.instantiate()
	elif type_name != "":
		if not ClassDB.class_exists(type_name) or not ClassDB.can_instantiate(type_name):
			return {"ok": false, "error": "Cannot instantiate type: %s" % type_name}
		new_node = ClassDB.instantiate(type_name)
	else:
		return {"ok": false, "error": "Spec must have 'scene' or 'type'"}

	# Set name
	var node_name: String = str(spec.get("name", ""))
	if node_name == "":
		node_name = _build_spec_name_prefix(spec)
		if scene_path != "" and new_node.name != "":
			node_name = str(new_node.name)
	new_node.name = node_name

	# Register with undo/redo (deferred)
	ur.add_do_method(parent, "add_child", new_node)
	ur.add_do_method(self, "_set_owner_recursive", new_node, scene_root)
	ur.add_do_reference(new_node)
	ur.add_undo_method(parent, "remove_child", new_node)

	# Set transform properties (deferred)
	if new_node is Node3D:
		var pos = spec.get("position", null)
		if pos is Array and pos.size() >= 3:
			ur.add_do_property(new_node, "position", Vector3(float(pos[0]), float(pos[1]), float(pos[2])))
		var rot = spec.get("rotation", null)
		if rot is Array and rot.size() >= 3:
			ur.add_do_property(new_node, "rotation_degrees", Vector3(float(rot[0]), float(rot[1]), float(rot[2])))
		var scl = spec.get("scale", null)
		if scl is Array and scl.size() >= 3:
			ur.add_do_property(new_node, "scale", Vector3(float(scl[0]), float(scl[1]), float(scl[2])))
	elif new_node is Node2D or new_node is Control:
		var pos = spec.get("position", null)
		if pos is Array and pos.size() >= 2:
			ur.add_do_property(new_node, "position", Vector2(float(pos[0]), float(pos[1])))
		var scl = spec.get("scale", null)
		if scl is Array and scl.size() >= 2:
			ur.add_do_property(new_node, "scale", Vector2(float(scl[0]), float(scl[1])))

	# Set custom properties
	var properties = spec.get("properties", null)
	if properties is Dictionary:
		for prop_name in properties:
			ur.add_do_property(new_node, prop_name, properties[prop_name])

	return {"ok": true, "name": str(new_node.name)}


# --- Game-side forwarding ---

func _is_game_playing() -> bool:
	# Liveness comes from the editor, not from _game_running: that flag is
	# driven only by the debugger `started` signal, which Godot does not
	# re-fire on session reuse — unreliable from the second run on.
	# (Also the contract-test seam: EditorInterface is editor-only.)
	return EditorInterface.is_playing_scene()


func _handle_game_forward(peer_id: int, id: String, msg_type: String, params: Dictionary, timeout_ms: int) -> void:
	if not _is_game_playing():
		_send_error(peer_id, id, "GAME_NOT_RUNNING", "No game session is running")
		return
	if debugger == null:
		_send_error(peer_id, id, "NO_DEBUGGER", "Debugger plugin not available")
		return
	if not _runtime_attached:
		_send_error(peer_id, id, "RUNTIME_NOT_ATTACHED",
			"Game is running but the GodotIQ runtime did not attach; runtime tools are unavailable. Restart the game with godotiq_run to retry the handshake.")
		return
	var req_key := "%d:%s" % [peer_id, id]
	var forward_params: Dictionary = params.duplicate(true)
	forward_params["_request_id"] = req_key
	# Register the pending entry only AFTER a successful send — a failed send
	# must fail loud now, not linger until the timeout sweep.
	var sent: bool = debugger.send_to_game(msg_type, [JSON.stringify(forward_params)])
	if not sent:
		_send_error(peer_id, id, "NO_GAME_SESSION",
			"Debugger session unavailable; cannot reach the running game. Restart the game with godotiq_run.")
		return
	_pending_game_requests[req_key] = {
		"peer_id": peer_id,
		"request_id": id,
		"method": msg_type,
		"timeout_at": Time.get_ticks_msec() + timeout_ms,
	}


func handle_game_response(response_type: String, data: Array) -> void:
	var result: Dictionary = {}
	var response_request_id := ""
	if data.size() >= 1 and data[0] is String:
		var parsed = JSON.parse_string(data[0])
		if parsed is Dictionary:
			result = parsed
			response_request_id = str(result.get("request_id", ""))
			result.erase("request_id")
		else:
			result = {"raw": data[0]}
	elif response_type == "godotiq:screenshot" and data.size() >= 4:
		result = {
			"image": data[0],
			"format": data[1],
			"width": data[2],
			"height": data[3],
		}
	else:
		result = {"data": data}

	var matched_id := ""
	if response_request_id != "":
		if _pending_game_requests.has(response_request_id):
			matched_id = response_request_id
		else:
			for req_id in _pending_game_requests:
				var entry_by_request_id: Dictionary = _pending_game_requests[req_id]
				if entry_by_request_id["method"] == response_type and entry_by_request_id["request_id"] == response_request_id:
					matched_id = req_id
					break

	if matched_id == "":
		for req_id in _pending_game_requests:
			var entry_by_method: Dictionary = _pending_game_requests[req_id]
			if entry_by_method["method"] == response_type:
				matched_id = req_id
				break

	if matched_id == "":
		return  # no matching request — stale or duplicate

	var entry: Dictionary = _pending_game_requests[matched_id]
	_pending_game_requests.erase(matched_id)
	send_response(entry["peer_id"], entry["request_id"], result)


# --- Game lifecycle callbacks ---

func mark_runtime_attached() -> void:
	# Called by the debugger plugin on ANY godotiq:* capture — every captured
	# message proves the game-side runtime registered its message capture.
	_runtime_attached = true


func on_game_started() -> void:
	_game_running = true
	send_event("game_started", {})


func on_game_stopped() -> void:
	_game_running = false
	_runtime_attached = false
	# Fail all pending game requests
	for req_id in _pending_game_requests.keys():
		var entry: Dictionary = _pending_game_requests[req_id]
		_send_error(entry["peer_id"], entry["request_id"], "GAME_STOPPED", "Game session ended")
	_pending_game_requests.clear()
	send_event("game_stopped", {})


# --- Pre-flight checks ---

func _preflight_scene_check(params: Dictionary) -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return {"ok": false, "error": "No scene is open in the editor. Call godotiq_exec to open a scene first: EditorInterface.open_scene_from_path('res://YourScene.tscn')"}
	var requested_scene: String = ""
	if params.has("scene"):
		requested_scene = str(params["scene"])
	elif params.has("target_scene"):
		requested_scene = str(params["target_scene"])
	if requested_scene != "" and root.scene_file_path != requested_scene:
		return {"ok": false, "error": "Scene '%s' is open but you requested '%s'. Save and switch scenes first: call godotiq_save_scene() then godotiq_exec('EditorInterface.open_scene_from_path(\"%s\")')" % [root.scene_file_path, requested_scene, requested_scene]}
	return {"ok": true}


# --- Editor state helpers ---

func _record_error(msg: String) -> void:
	_recent_errors.append(msg)
	if _recent_errors.size() > MAX_RECENT_ERRORS:
		_recent_errors = _recent_errors.slice(-MAX_RECENT_ERRORS)


func _clear_recent_errors() -> void:
	_recent_errors.clear()


func _format_runtime_error(raw, index: int) -> Dictionary:
	var message := str(raw)
	var parsed = JSON.parse_string(message)
	if parsed is Dictionary:
		var out: Dictionary = parsed.duplicate(true)
		out["source"] = str(out.get("source", "runtime"))
		out["severity"] = str(out.get("severity", "error"))
		if not out.has("message"):
			out["message"] = str(out.get("error", message))
		out["index"] = index
		return out
	return {
		"source": "runtime",
		"severity": "error",
		"message": message,
		"index": index,
	}


func _format_script_error(entry: Dictionary) -> Dictionary:
	return {
		"source": "script",
		"severity": "error",
		"file": str(entry.get("file", "")),
		"line": int(entry.get("line", 0)),
		"message": str(entry.get("message", entry.get("error", ""))),
		"timestamp": entry.get("timestamp", 0),
	}


func _handle_read_debug_console(peer_id: int, id: String, params: Dictionary) -> void:
	var limit: int = clampi(int(params.get("limit", 20)), 1, 100)
	var clear_after_read: bool = bool(params.get("clear", false))
	var include_runtime: bool = bool(params.get("include_runtime", true))
	var include_script: bool = bool(params.get("include_script", true))
	var entries: Array = []
	var runtime_total := _recent_errors.size()
	var script_entries := _get_script_errors()
	var script_total := script_entries.size()
	var included_total := 0

	if include_runtime:
		included_total += runtime_total
		var start_idx: int = max(0, runtime_total - limit)
		for i in range(start_idx, runtime_total):
			entries.append(_format_runtime_error(_recent_errors[i], i))

	if include_script:
		included_total += script_total
		var script_start_idx: int = max(0, script_total - limit)
		for i in range(script_start_idx, script_total):
			entries.append(_format_script_error(script_entries[i]))

	if entries.size() > limit:
		entries = entries.slice(entries.size() - limit, entries.size())

	if clear_after_read:
		if include_runtime:
			_clear_recent_errors()
		if include_script:
			_clear_script_errors()

	send_response(peer_id, id, {
		"entries": entries,
		"total": entries.size(),
		"runtime_errors_total": runtime_total,
		"script_errors_total": script_total,
		"truncated": included_total > entries.size(),
		"cleared": clear_after_read,
		"capture": {
			"runtime_errors": true,
			"script_errors": _has_logger,
			"script_errors_note": "" if _has_logger else "Script logger requires Godot 4.5+; use godotiq_check_errors for explicit script checks.",
		},
	})


func _get_editor_state() -> Dictionary:
	var scene_path := ""
	var root := EditorInterface.get_edited_scene_root()
	if root != null:
		scene_path = root.scene_file_path
	return {
		"open_scene": scene_path,
		"game_running": EditorInterface.is_playing_scene(),
		"recent_errors": _recent_errors.slice(-3),
	}


# --- Transport helpers ---

func send_response(peer_id: int, id: String, result: Dictionary) -> void:
	result["_editor_state"] = _get_editor_state()
	var msg := JSON.stringify({"id": id, "status": "ok", "result": result})
	_send_text(peer_id, msg)


func _send_error(peer_id: int, id: String, code: String, message: String) -> void:
	var msg := JSON.stringify({
		"id": id,
		"status": "error",
		"error": {"code": code, "message": message},
		"_editor_state": _get_editor_state(),
	})
	_send_text(peer_id, msg)


func send_event(event_name: String, data: Dictionary) -> void:
	var msg := JSON.stringify({"event": event_name, "data": data})
	for peer_id in _peers:
		var ws: WebSocketPeer = _peers[peer_id]
		if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			ws.send_text(msg)


func _send_text(peer_id: int, text: String) -> void:
	if not _peers.has(peer_id):
		return
	var ws: WebSocketPeer = _peers[peer_id]
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(text)


# --- check_errors ---

func _handle_check_errors(peer_id: int, id: String, params: Dictionary):
	if _checking_errors:
		_send_error(peer_id, id, "CHECK_IN_PROGRESS", "A check_errors operation is already running")
		return
	_checking_errors = true
	var scope: String = params.get("scope", "scene")
	if _has_logger:
		_clear_script_errors()
	# Collect script paths based on scope
	var script_paths: Array[String] = []
	if scope == "project":
		var fs := EditorInterface.get_resource_filesystem().get_filesystem()
		script_paths = _get_script_paths_recursive(fs)
	elif scope == "scene":
		var edited_root := EditorInterface.get_edited_scene_root()
		script_paths = _get_scene_script_paths(edited_root)
	else:
		script_paths = [scope]  # Treat as a specific res:// path
	# Script check loop
	var basic_errors: Dictionary = {}  # file -> error dict (basic, line=0)
	var checked: int = 0
	for i in script_paths.size():
		var path: String = script_paths[i]
		var res = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		var basic_error := _check_loaded_script(path, res)
		if not basic_error.is_empty():
			basic_errors[path] = basic_error
		checked += 1
		if checked % 10 == 0:
			await get_tree().process_frame
	# Let trailing async Logger callbacks land before the merge — the check
	# loop only yields every 10 scripts, so the last <10 batch may still be
	# in flight when we read _get_script_errors().
	await get_tree().process_frame
	var logger_entries: Array = _get_script_errors() if _has_logger else []
	var deduped := _merge_and_dedup_errors(basic_errors, logger_entries)
	_checking_errors = false
	send_response(peer_id, id, {
		"errors": deduped,
		"total": deduped.size(),
		"scripts_checked": checked,
		"scope": scope,
	})


func _merge_and_dedup_errors(basic_errors: Dictionary, logger_entries: Array) -> Array:
	# Logger entries carry a real line and replace the line-unavailable basic
	# error for the same file.
	var final_errors: Array = []
	var logger_by_file: Dictionary = {}  # file -> [entries]
	for entry in logger_entries:
		if not logger_by_file.has(entry.file):
			logger_by_file[entry.file] = []
		logger_by_file[entry.file].append({"file": entry.file, "line": entry.line, "error": entry.message})
	# For files with Logger entries, use those instead of basic errors
	for file_path in basic_errors:
		if logger_by_file.has(file_path):
			final_errors.append_array(logger_by_file[file_path])
			logger_by_file.erase(file_path)
		else:
			final_errors.append(basic_errors[file_path])
	# Add Logger entries for files not in basic_errors
	for file_path in logger_by_file:
		final_errors.append_array(logger_by_file[file_path])
	# Deduplicate by file+line+message. All string placeholders on purpose:
	# basic errors carry line:null (line_unavailable) and an int placeholder
	# on null is unsafe.
	var seen := {}
	var deduped: Array = []
	for err in final_errors:
		var key := "%s|%s|%s" % [err.file, str(err.line), err.error]
		if not seen.has(key):
			seen[key] = true
			deduped.append(err)
	return deduped


func _check_loaded_script(path: String, script_res) -> Dictionary:
	# GDScript.reload() returns only an int error code — there is no real
	# line to report. line:null + line_unavailable:true, never a hardcoded
	# 0: the error is often real and a fake line 0 reads as a false positive.
	if script_res == null:
		return {"file": path, "line": null, "line_unavailable": true, "error": "Failed to load script"}
	# A project script may declare its own non-static `reload()` (an FPS
	# weapon, say): the untyped call dispatches through callp, which refuses
	# the non-static shadow and yields null — int(null) then crashed HERE,
	# making check_errors flag the addon itself as a permanent project
	# error. A GDScript-typed local binds the native method instead, so the
	# shadowing script is still genuinely compile-checked.
	var reload_result
	if script_res is GDScript:
		var gd_script: GDScript = script_res
		reload_result = gd_script.reload()
	elif script_res.has_method("reload"):
		reload_result = script_res.reload()
	else:
		return {}
	var reload_err: int = reload_result if reload_result is int else OK
	if reload_err != OK:
		return {"file": path, "line": null, "line_unavailable": true, "error": "Script reload failed (error %d)" % reload_err}
	return {}


func _get_script_paths_recursive(dir: EditorFileSystemDirectory) -> Array[String]:
	var result: Array[String] = []
	if dir == null:
		return result
	var excluded := ["addons", ".godot", "build", "export"]
	for i in dir.get_subdir_count():
		var subdir := dir.get_subdir(i)
		if subdir.get_name() in excluded:
			continue
		result.append_array(_get_script_paths_recursive(subdir))
	for i in dir.get_file_count():
		var file_path := dir.get_file_path(i)
		if file_path.ends_with(".gd"):
			result.append(file_path)
	return result


func _get_scene_script_paths(root: Node) -> Array[String]:
	var result: Array[String] = []
	# Walk scene tree
	if root != null:
		var nodes := [root]
		while nodes.size() > 0:
			var node: Node = nodes.pop_back()
			var script = node.get_script()
			if script is GDScript and script.resource_path != "":
				result.append(script.resource_path)
			for child in node.get_children():
				nodes.append(child)
	# Autoload discovery (shared helper)
	result.append_array(_get_autoload_script_paths())
	# Deduplicate
	var seen := {}
	var deduped: Array[String] = []
	for p in result:
		if not seen.has(p):
			seen[p] = true
			deduped.append(p)
	return deduped


# --- Cleanup ---

func _exit_tree() -> void:
	if _has_logger and _error_logger:
		OS.remove_logger(_error_logger)
		_error_logger = null
		_has_logger = false
	for peer_id in _peers:
		var ws: WebSocketPeer = _peers[peer_id]
		if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			ws.close()
	_peers.clear()
	_peer_tcp.clear()
	_pending_game_requests.clear()
	if _tcp_server:
		_tcp_server.stop()
		_tcp_server = null
