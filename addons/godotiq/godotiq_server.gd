@tool
extends Node
## GodotIQ WebSocket server — accepts connections from the Python MCP server,
## dispatches requests to editor handlers or forwards to the running game.

const DEFAULT_PORT := 6007
const ADDON_VERSION := "2.0.0"
const SCREENSHOT_TIMEOUT_MS := 30000
const PERF_TIMEOUT_MS := 5000
const INPUT_TIMEOUT_MS := 65000
const EXEC_TIMEOUT_MS := 10000
const STATE_TIMEOUT_MS := 5000
var _exec_counter: int = 0

var _tcp_server: TCPServer
var _peers: Dictionary = {}          # peer_id -> WebSocketPeer
var _peer_tcp: Dictionary = {}       # peer_id -> StreamPeerTCP (prevent GC)
var _pending_game_requests: Dictionary = {}  # request_id -> {peer_id, method, timeout_at}
var _pending_screenshot = null  # Deferred editor screenshot capture data
var _pending_run = null  # Poll for scene play confirmation {peer_id, id, timeout_at, started_at}
var _pending_scene_open = null  # Deferred scene open + play {peer_id, id, scene_path, timeout}
var _game_running: bool = false
var _next_peer_id: int = 1
var _port: int = DEFAULT_PORT
var debugger  # untyped — set by godotiq_plugin.gd
var undo_redo  # untyped — set by godotiq_plugin.gd (EditorUndoRedoManager)
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
	_tcp_server = TCPServer.new()
	var err := _tcp_server.listen(_port, "127.0.0.1")
	if err == OK:
		print("GodotIQ: WebSocket server listening on 127.0.0.1:%d" % _port)
	else:
		push_error("GodotIQ: Failed to start WebSocket server on port %d (error %d)" % [_port, err])
	# Logger registration (Godot 4.5+ only)
	if ClassDB.class_exists("Logger"):
		var logger_script = load("res://addons/godotiq/godotiq_logger.gd")
		if logger_script:
			_error_logger = logger_script.new(self)
			OS.add_logger(_error_logger)
			_has_logger = true
			print("GodotIQ: Logger registered (Godot 4.5+)")
		else:
			push_warning("GodotIQ: Logger class exists but godotiq_logger.gd failed to load")


func get_port() -> int:
	return _port


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

	# 4. Process deferred editor screenshot
	if _pending_screenshot != null:
		var s: Dictionary = _pending_screenshot
		_pending_screenshot = null
		_do_editor_screenshot(
			s["peer_id"], s["id"], s["viewport_3d"],
			s["camera"], s["original_transform"], true, s["scale"], s["quality"], s["fmt"]
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
			"main_scene_set": s.get("main_scene_set", false),
		}

	# 4b. Poll for scene play confirmation
	if _pending_run != null:
		var r: Dictionary = _pending_run
		if EditorInterface.is_playing_scene():
			_pending_run = null
			var waited: float = (Time.get_ticks_msec() - r.get("started_at", Time.get_ticks_msec())) / 1000.0
			var resp := {"action": "play", "success": true, "scene": r.get("scene", ""), "waited_seconds": waited}
			if r.get("main_scene_set", false):
				resp["main_scene_set"] = true
			send_response(r["peer_id"], r["id"], resp)
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
			_handle_game_forward(peer_id, id, "godotiq:exec", params, EXEC_TIMEOUT_MS)
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
		"set_main_scene":
			_handle_set_main_scene(peer_id, id, params)
		"reload_script":
			_handle_reload_script(peer_id, id, params)
		_:
			_send_error(peer_id, id, "UNKNOWN_METHOD", "Unknown method: %s" % method)


# --- Editor-side handlers ---

func _handle_ping(peer_id: int, id: String) -> void:
	send_response(peer_id, id, {
		"editor_version": Engine.get_version_info().get("string", "unknown"),
		"game_running": _game_running,
		"addon_version": ADDON_VERSION,
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
		"game_running": _game_running,
		"project_path": ProjectSettings.globalize_path("res://"),
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


func _handle_reload_script(peer_id: int, id: String, params: Dictionary) -> void:
	var path: String = str(params.get("path", ""))
	if path.is_empty() or not path.ends_with(".gd"):
		_send_error(peer_id, id, "INVALID_PATH", "Path must be a non-empty .gd file path")
		return
	var script = load(path)
	if script == null or not (script is GDScript):
		send_response(peer_id, id, {"reloaded": false, "error": "Failed to load script: %s" % path})
		return
	var err: int = script.reload()
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
	var errors := _check_scripts_valid(unique_paths)
	if errors.size() > 0:
		_send_error(
			peer_id, id, "SCRIPT_ERRORS",
			"Cannot start game: %d script(s) have errors. Use godotiq_check_errors for details." % errors.size()
		)
		return

	# Step 4: Auto-set main scene if empty
	var main_scene_set: bool = false
	if not is_current and resolved_path != "":
		var current_main: String = ProjectSettings.get_setting("application/run/main_scene", "")
		if current_main == "":
			_set_main_scene_internal(resolved_path)
			main_scene_set = true

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
			"main_scene_set": main_scene_set,
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
			"main_scene_set": main_scene_set,
		}


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
		elif res is GDScript and not res.can_instantiate():
			errors.append({"file": path, "error": "Script has compilation errors"})
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
	undo_redo.create_action(action_name)

	var results: Array = []
	var any_succeeded := false

	for op_data in operations:
		if not (op_data is Dictionary):
			results.append({"status": "error", "error": "Invalid operation format"})
			continue
		var result := _execute_node_op(op_data, scene_root, undo_redo)
		results.append(result)
		if result["status"] == "ok":
			any_succeeded = true

	if any_succeeded:
		undo_redo.commit_action()
		_godotiq_action_history.append({
			"action": action_name,
			"operations": results.size(),
			"timestamp": Time.get_ticks_msec(),
		})
		if _godotiq_action_history.size() > MAX_HISTORY_SIZE:
			_godotiq_action_history = _godotiq_action_history.slice(
				_godotiq_action_history.size() - MAX_HISTORY_SIZE
			)

	send_response(peer_id, id, {
		"results": results,
		"scene_modified": any_succeeded,
		"undo_available": any_succeeded,
		"action_name": action_name,
	})


func _execute_node_op(op_data: Dictionary, scene_root: Node, ur) -> Dictionary:
	var op: String = str(op_data.get("op", ""))
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
		_:
			return {"op": op, "status": "error", "error": "Unknown operation: %s" % op}


func _find_node_by_name_or_path(name_or_path: String, scene_root: Node) -> Node:
	var node := scene_root.get_node_or_null(NodePath(name_or_path))
	if node != null:
		return node
	return _find_by_name_recursive(scene_root, name_or_path)


func _op_move(op_data: Dictionary, scene_root: Node, ur) -> Dictionary:
	var node_name: String = str(op_data.get("node", ""))
	var node := _find_node_by_name_or_path(node_name, scene_root)
	if node == null:
		return {"op": "move", "node": node_name, "status": "error", "error": "Node not found: %s" % node_name}

	var pos: Array = op_data.get("position", [0, 0, 0])
	if not (pos is Array) or pos.size() < 2:
		return {"op": "move", "node": node_name, "status": "error", "error": "position must be an array of at least 2 numbers"}
	if node is Node3D:
		if pos.size() < 3:
			return {"op": "move", "node": node_name, "status": "error", "error": "Node3D position requires [x, y, z]"}
		var old_pos := (node as Node3D).position
		var new_pos := Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
		ur.add_do_property(node, "position", new_pos)
		ur.add_undo_property(node, "position", old_pos)
	elif node is Node2D:
		var old_pos := (node as Node2D).position
		var new_pos := Vector2(float(pos[0]), float(pos[1]))
		ur.add_do_property(node, "position", new_pos)
		ur.add_undo_property(node, "position", old_pos)
	elif node is Control:
		var old_pos := (node as Control).position
		var new_pos := Vector2(float(pos[0]), float(pos[1]))
		ur.add_do_property(node, "position", new_pos)
		ur.add_undo_property(node, "position", old_pos)
	else:
		return {"op": "move", "node": node_name, "status": "error", "error": "Node does not support position"}

	return {"op": "move", "node": node_name, "status": "ok"}


func _op_rotate(op_data: Dictionary, scene_root: Node, ur) -> Dictionary:
	var node_name: String = str(op_data.get("node", ""))
	var node := _find_node_by_name_or_path(node_name, scene_root)
	if node == null:
		return {"op": "rotate", "node": node_name, "status": "error", "error": "Node not found: %s" % node_name}

	if not (node is Node3D):
		return {"op": "rotate", "node": node_name, "status": "error", "error": "Rotate only supports Node3D"}

	var rot: Array = op_data.get("rotation", [0, 0, 0])
	if not (rot is Array) or rot.size() < 3:
		return {"op": "rotate", "node": node_name, "status": "error", "error": "rotation requires [x, y, z]"}
	var n3d: Node3D = node
	var old_rot := n3d.rotation_degrees
	var new_rot := Vector3(float(rot[0]), float(rot[1]), float(rot[2]))
	ur.add_do_property(node, "rotation_degrees", new_rot)
	ur.add_undo_property(node, "rotation_degrees", old_rot)
	return {"op": "rotate", "node": node_name, "status": "ok"}


func _op_scale(op_data: Dictionary, scene_root: Node, ur) -> Dictionary:
	var node_name: String = str(op_data.get("node", ""))
	var node := _find_node_by_name_or_path(node_name, scene_root)
	if node == null:
		return {"op": "scale", "node": node_name, "status": "error", "error": "Node not found: %s" % node_name}

	if not (node is Node3D):
		return {"op": "scale", "node": node_name, "status": "error", "error": "Scale only supports Node3D"}

	var sc: Array = op_data.get("scale", [1, 1, 1])
	if not (sc is Array) or sc.size() < 3:
		return {"op": "scale", "node": node_name, "status": "error", "error": "scale requires [x, y, z]"}
	var n3d: Node3D = node
	var old_scale := n3d.scale
	var new_scale := Vector3(float(sc[0]), float(sc[1]), float(sc[2]))
	ur.add_do_property(node, "scale", new_scale)
	ur.add_undo_property(node, "scale", old_scale)
	return {"op": "scale", "node": node_name, "status": "ok"}


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
	return {"op": "set_property", "node": node_name, "status": "ok", "property": property}


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
	elif type_name != "":
		if not ClassDB.class_exists(type_name) or not ClassDB.can_instantiate(type_name):
			return {"op": "add_child", "status": "error", "error": "Cannot instantiate type: %s" % type_name}
		new_node = ClassDB.instantiate(type_name)
	else:
		return {"op": "add_child", "status": "error", "error": "Must provide 'scene' or 'type'"}

	var child_name: String = str(op_data.get("name", "NewNode"))
	new_node.name = child_name

	ur.add_do_method(parent, "add_child", new_node)
	ur.add_do_method(self, "_set_owner_recursive", new_node, scene_root)
	ur.add_do_reference(new_node)
	ur.add_undo_method(parent, "remove_child", new_node)

	# Set position after adding if provided
	var pos = op_data.get("position", null)
	if pos is Array and pos.size() >= 2:
		if new_node is Node3D and pos.size() >= 3:
			ur.add_do_property(new_node, "position", Vector3(float(pos[0]), float(pos[1]), float(pos[2])))
		elif new_node is Node2D or new_node is Control:
			ur.add_do_property(new_node, "position", Vector2(float(pos[0]), float(pos[1])))

	return {"op": "add_child", "node": child_name, "parent": parent_name, "status": "ok"}


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
	return {"op": "delete", "node": node_name, "status": "ok"}


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
	return {"op": "duplicate", "node": node_name, "new_name": dup_name, "status": "ok"}


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
	return {"op": "reparent", "node": node_name, "new_parent": new_parent_name, "status": "ok"}


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
		var anchors: Array = op_data["anchors"]
		if not (anchors is Array) or anchors.size() < 4:
			return {"op": "set_anchors", "node": node_name, "status": "error", "error": "anchors requires [left, top, right, bottom]"}
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

	var result: Dictionary = {"op": "set_anchors", "node": node_name, "status": "ok", "anchors": new_anchors}
	if preset_name != "":
		result["preset"] = preset_name
	return result


func _convert_value(value, reference_value):
	if reference_value is Vector3 and value is Array and value.size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	elif reference_value is Vector2 and value is Array and value.size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	elif reference_value is Color:
		if value is Array and value.size() >= 3:
			var a: float = float(value[3]) if value.size() >= 4 else 1.0
			return Color(float(value[0]), float(value[1]), float(value[2]), a)
		elif value is String:
			return Color(value)
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
	var timeout_ms: int = params.get("timeout_ms", 5000)

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
	var blocked_patterns: Array = [
		"DirAccess.remove",
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

	# Compile the script
	var script := GDScript.new()
	script.source_code = "@tool\nextends Node\n\n" + code
	var err: int = script.reload()
	if err != OK:
		send_response(peer_id, id, {
			"status": "COMPILE_ERROR",
			"result": "",
			"error": "Compilation failed (error %d). Check GDScript syntax." % err,
		})
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


func _handle_save_scene(peer_id: int, id: String, _params: Dictionary) -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		_send_error(peer_id, id, "NO_SCENE", "No scene is currently open in the editor")
		return

	EditorInterface.save_scene()

	var scene_path: String = scene_root.scene_file_path

	send_response(peer_id, id, {
		"saved": true,
		"scene_path": scene_path,
		"scene_name": scene_root.name,
	})


func _handle_editor_screenshot(peer_id: int, id: String, params: Dictionary) -> void:
	# Ensure 3D viewport is active — without this, screenshot may capture Script tab
	EditorInterface.set_main_screen_editor("3D")

	var scale: float = params.get("scale", 0.25)
	var quality: float = clampf(params.get("quality", 0.5), 0.1, 1.0)
	var fmt: String = params.get("format", "webp")

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
			"scale": scale, "quality": quality, "fmt": fmt,
		}
		return

	# No camera move — capture current viewport texture immediately
	_do_editor_screenshot(peer_id, id, viewport_3d, camera, original_transform, false, scale, quality, fmt)


func _do_editor_screenshot(peer_id: int, id: String, viewport_3d: SubViewport, camera: Camera3D, original_transform: Transform3D, restore_camera: bool, scale: float, quality: float, fmt: String) -> void:
	var img := viewport_3d.get_texture().get_image()
	if img == null:
		if restore_camera and camera != null:
			camera.global_transform = original_transform
		_send_error(peer_id, id, "CAPTURE_FAILED", "Failed to capture editor viewport image")
		return

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

	# Resolve parent node
	var parent_str: String = str(params.get("parent", ""))
	var parent: Node = scene_root
	if parent_str != "":
		parent = _find_node_by_name_or_path(parent_str, scene_root)
		if parent == null:
			_send_error(peer_id, id, "PARENT_NOT_FOUND", "Parent node not found: %s" % parent_str)
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
	if params.has("grid"):
		return _expand_build_grid(params["grid"])
	if params.has("line"):
		return _expand_build_line(params["line"])
	if params.has("scatter"):
		var scatter: Dictionary = params["scatter"]
		return scatter.get("items", [])
	if params.has("nodes"):
		return params["nodes"]
	return []


func _expand_build_grid(grid: Dictionary) -> Array:
	var scene_path: String = str(grid.get("scene", ""))
	var prefix: String = str(grid.get("prefix", "Node"))
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
					spec["position"] = [ox + col * spacing, oy + row * spacing, oz]
				else:  # "xz" default
					spec["position"] = [ox + col * spacing, oy, oz + row * spacing]

			result.append(spec)
	return result


func _expand_build_line(line: Dictionary) -> Array:
	var scene_path: String = str(line.get("scene", ""))
	var prefix: String = str(line.get("prefix", "Node"))
	var points: Array = line.get("points", [])
	var spacing: float = float(line.get("spacing", 1.0))
	var align_to_path: bool = line.get("align_to_path", false)
	var type_name: String = str(line.get("type", ""))

	if points.size() < 2 or spacing <= 0:
		return []

	var result: Array = []
	var index: int = 0

	# Place first node at start point with rotation from first segment
	var first_pt: Array = points[0]
	var first_spec: Dictionary = {"name": "%s_%d" % [prefix, index], "position": first_pt}
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
				"position": [pos.x, pos.y, pos.z],
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
	var final_pos := Vector3(float(final_pt[0]), float(final_pt[1]), float(final_pt[2]))
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
			"position": [final_pos.x, final_pos.y, final_pos.z],
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
	var node_name: String = str(spec.get("name", "BuildNode"))
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

func _handle_game_forward(peer_id: int, id: String, msg_type: String, params: Dictionary, timeout_ms: int) -> void:
	if not _game_running:
		_send_error(peer_id, id, "GAME_NOT_RUNNING", "No game session is running")
		return
	if debugger == null:
		_send_error(peer_id, id, "NO_DEBUGGER", "Debugger plugin not available")
		return
	var req_key := "%d:%s" % [peer_id, id]
	_pending_game_requests[req_key] = {
		"peer_id": peer_id,
		"request_id": id,
		"method": msg_type,
		"timeout_at": Time.get_ticks_msec() + timeout_ms,
	}
	debugger.send_to_game(msg_type, [JSON.stringify(params)])


func handle_game_response(response_type: String, data: Array) -> void:
	# Find matching pending request by method
	var matched_id := ""
	for req_id in _pending_game_requests:
		var entry: Dictionary = _pending_game_requests[req_id]
		if entry["method"] == response_type:
			matched_id = req_id
			break
	if matched_id == "":
		return  # no matching request — stale or duplicate
	var entry: Dictionary = _pending_game_requests[matched_id]
	_pending_game_requests.erase(matched_id)

	var result: Dictionary = {}
	if response_type == "godotiq:screenshot" and data.size() >= 4:
		result = {
			"image": data[0],
			"format": data[1],
			"width": data[2],
			"height": data[3],
		}
	elif data.size() >= 1 and data[0] is String:
		var parsed = JSON.parse_string(data[0])
		if parsed is Dictionary:
			result = parsed
		else:
			result = {"raw": data[0]}
	else:
		result = {"data": data}
	send_response(entry["peer_id"], entry["request_id"], result)


# --- Game lifecycle callbacks ---

func on_game_started() -> void:
	_game_running = true
	send_event("game_started", {})


func on_game_stopped() -> void:
	_game_running = false
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

func _handle_check_errors(peer_id: int, id: String, params: Dictionary) -> void:
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
		if res == null:
			basic_errors[path] = {"file": path, "line": 0, "error": "Failed to load script"}
		elif res is GDScript:
			if not res.can_instantiate():
				basic_errors[path] = {"file": path, "line": 0, "error": "Script has parse errors (cannot instantiate)"}
			var reload_err = res.reload()
			if reload_err != OK and not basic_errors.has(path):
				basic_errors[path] = {"file": path, "line": 0, "error": "Script reload failed (error %d)" % reload_err}
		checked += 1
		if checked % 10 == 0:
			await get_tree().process_frame
	# Merge Logger entries — Logger entries replace basic errors for the same file
	var final_errors: Array = []
	if _has_logger:
		var logger_entries := _get_script_errors()
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
	else:
		final_errors = basic_errors.values()
	# Deduplicate by file+line+message
	var seen := {}
	var deduped: Array = []
	for err in final_errors:
		var key := "%s|%d|%s" % [err.file, err.line, err.error]
		if not seen.has(key):
			seen[key] = true
			deduped.append(err)
	_checking_errors = false
	send_response(peer_id, id, {
		"errors": deduped,
		"total": deduped.size(),
		"scripts_checked": checked,
		"scope": scope,
	})


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
