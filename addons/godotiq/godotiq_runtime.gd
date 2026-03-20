extends Node
## GodotIQ game runtime autoload — executes screenshot and performance
## snapshot requests relayed from the editor via EngineDebugger.
## Registered as "GodotIQRuntime" autoload by godotiq_plugin.gd.
## NO @tool — this runs in the game process, not the editor.

var _input_in_progress: bool = false

# --- Watch system state ---
var _watches: Dictionary = {}
var _watch_events: Array = []
var _watch_sample_timer: float = 0.0
var _watch_sample_interval: float = 0.5
var _watch_active: bool = false


func _ready() -> void:
	print("[GodotIQ] Runtime _ready() — debugger active: ", EngineDebugger.is_active())
	if not EngineDebugger.is_active():
		print("[GodotIQ] Debugger not active, freeing runtime")
		queue_free()
		return
	EngineDebugger.register_message_capture("godotiq", _on_debugger_message)
	print("[GodotIQ] Message capture registered")


func _process(delta: float) -> void:
	if not _watch_active or _watches.is_empty():
		return
	_watch_sample_timer += delta
	if _watch_sample_timer >= _watch_sample_interval:
		_watch_sample_timer = 0.0
		_sample_watched_nodes()


func _on_debugger_message(message: String, data: Array) -> bool:
	match message:
		"screenshot":
			var params = {}
			if data.size() > 0 and data[0] is String:
				var parsed = JSON.parse_string(data[0])
				if parsed is Dictionary:
					params = parsed
			elif data.size() > 0 and data[0] is Dictionary:
				params = data[0]
			_take_screenshot(params)
			return true
		"query_perf":
			var perf_params = {}
			if data.size() > 0 and data[0] is String:
				var parsed_perf = JSON.parse_string(data[0])
				if parsed_perf is Dictionary:
					perf_params = parsed_perf
			elif data.size() > 0 and data[0] is Dictionary:
				perf_params = data[0]
			_send_perf_snapshot(perf_params)
			return true
		"input":
			var input_params = {}
			if data.size() > 0 and data[0] is String:
				var parsed_input = JSON.parse_string(data[0])
				if parsed_input is Dictionary:
					input_params = parsed_input
			elif data.size() > 0 and data[0] is Dictionary:
				input_params = data[0]
			_simulate_input(input_params)
			return true
		"exec":
			var exec_params = {}
			if data.size() > 0 and data[0] is String:
				var parsed_exec = JSON.parse_string(data[0])
				if parsed_exec is Dictionary:
					exec_params = parsed_exec
			elif data.size() > 0 and data[0] is Dictionary:
				exec_params = data[0]
			_execute_code(exec_params)
			return true
		"query_state":
			var state_params = {}
			if data.size() > 0 and data[0] is String:
				var parsed_state = JSON.parse_string(data[0])
				if parsed_state is Dictionary:
					state_params = parsed_state
			elif data.size() > 0 and data[0] is Dictionary:
				state_params = data[0]
			_query_state(state_params)
			return true
		"query_nav":
			var nav_params = {}
			if data.size() > 0 and data[0] is String:
				var parsed_nav = JSON.parse_string(data[0])
				if parsed_nav is Dictionary:
					nav_params = parsed_nav
			elif data.size() > 0 and data[0] is Dictionary:
				nav_params = data[0]
			_handle_nav_query(nav_params)
			return true
		"watch":
			var watch_params = {}
			if data.size() > 0 and data[0] is String:
				var parsed_watch = JSON.parse_string(data[0])
				if parsed_watch is Dictionary:
					watch_params = parsed_watch
			elif data.size() > 0 and data[0] is Dictionary:
				watch_params = data[0]
			_handle_watch(watch_params)
			return true
		"query_ui_map":
			var ui_map_params = {}
			if data.size() > 0 and data[0] is String:
				var parsed_ui_map = JSON.parse_string(data[0])
				if parsed_ui_map is Dictionary:
					ui_map_params = parsed_ui_map
			elif data.size() > 0 and data[0] is Dictionary:
				ui_map_params = data[0]
			_handle_ui_map(ui_map_params)
			return true
		"explore_camera":
			var explore_params = {}
			if data.size() > 0 and data[0] is String:
				var parsed_explore = JSON.parse_string(data[0])
				if parsed_explore is Dictionary:
					explore_params = parsed_explore
			elif data.size() > 0 and data[0] is Dictionary:
				explore_params = data[0]
			_handle_explore_camera(explore_params)
			return true
	return false


func _with_request_id(payload: Dictionary, params: Dictionary) -> Dictionary:
	var result: Dictionary = payload.duplicate(true)
	var request_id: String = str(params.get("_request_id", ""))
	if not request_id.is_empty():
		result["request_id"] = request_id
	return result


func _send_json_result(channel: String, payload: Dictionary, params: Dictionary = {}) -> void:
	EngineDebugger.send_message(channel, [JSON.stringify(_with_request_id(payload, params))])


func _take_screenshot(params: Dictionary):
	await get_tree().process_frame

	var viewport := get_viewport()
	if viewport == null:
		_send_json_result("godotiq:screenshot_result", {
			"error": "No viewport available",
		}, params)
		return

	var tex := viewport.get_texture()
	if tex == null:
		_send_json_result("godotiq:screenshot_result", {
			"error": "Viewport texture not available",
		}, params)
		return

	var img := tex.get_image()
	if img == null:
		_send_json_result("godotiq:screenshot_result", {
			"error": "Failed to capture viewport image",
		}, params)
		return

	var scale: float = clampf(params.get("scale", 0.5), 0.1, 1.0)
	var quality: float = clampf(params.get("quality", 0.5), 0.1, 1.0)
	var fmt: String = params.get("format", "webp")
	var region: Array = params.get("region", [])

	# Apply region crop before scaling
	if region.size() == 4:
		var rx: int = clampi(int(region[0]), 0, img.get_width())
		var ry: int = clampi(int(region[1]), 0, img.get_height())
		var rw: int = clampi(int(region[2]), 1, img.get_width() - rx)
		var rh: int = clampi(int(region[3]), 1, img.get_height() - ry)
		img = img.get_region(Rect2i(rx, ry, rw, rh))

	var w := img.get_width()
	var h := img.get_height()

	if scale < 1.0:
		img.resize(int(w * scale), int(h * scale))
		w = img.get_width()
		h = img.get_height()

	var buffer: PackedByteArray
	match fmt:
		"png":
			buffer = img.save_png_to_buffer()
		"jpg":
			buffer = img.save_jpg_to_buffer(quality)
		_:
			fmt = "webp"
			buffer = img.save_webp_to_buffer(true, quality)

	var b64 := Marshalls.raw_to_base64(buffer)
	_send_json_result("godotiq:screenshot_result", {
		"image": b64,
		"format": fmt,
		"width": w,
		"height": h,
	}, params)


func _send_perf_snapshot(params: Dictionary = {}) -> void:
	var result := {
		"fps": Engine.get_frames_per_second(),
		"draw_calls": RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME
		),
		"triangles": RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME
		),
		"objects": RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME
		),
		"texture_mem": RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED
		),
		"buffer_mem": RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_BUFFER_MEM_USED
		),
		"video_mem": RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_VIDEO_MEM_USED
		),
		"total_nodes": get_tree().get_node_count(),
		"orphan_nodes": Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT),
	}
	_send_json_result("godotiq:perf_result", result, params)


func _simulate_input(params: Dictionary):
	if _input_in_progress:
		_send_json_result("godotiq:input_result", {
			"success": false,
			"error": "Another input simulation is already in progress",
		}, params)
		return

	_input_in_progress = true

	var commands: Array = params.get("commands", [])
	var track_effects: bool = params.get("track_side_effects", false)

	var state_before: Dictionary = {}
	if track_effects:
		state_before = _snapshot_scene_state()

	var results: Array = []
	var all_ok: bool = true

	for cmd in commands:
		var cmd_result := await _execute_input_command(cmd)
		results.append(cmd_result)
		if not cmd_result.get("ok", false):
			all_ok = false
			if not params.get("continue_on_error", false):
				break

	var side_effects: Array = []
	if track_effects:
		var state_after := _snapshot_scene_state()
		side_effects = _diff_states(state_before, state_after)

	var signal_received: bool = false
	var signal_data: Dictionary = {}
	var wait_for: String = params.get("wait_for", "")
	if not wait_for.is_empty() and wait_for.begins_with("signal:"):
		var signal_spec := wait_for.substr(7)
		var parts := signal_spec.split(".")
		if parts.size() == 2:
			var wait_timeout_ms: int = params.get("wait_for_timeout_ms", 5000)
			var target_node := get_tree().root.get_node_or_null(parts[0])
			if target_node == null:
				target_node = get_tree().root.get_node_or_null("/root/" + parts[0])
			if target_node != null and target_node.has_signal(parts[1]):
				var sig_result := await _wait_for_signal_or_timeout(target_node, parts[1], wait_timeout_ms / 1000.0)
				signal_received = sig_result["received"]
				signal_data = sig_result

	_input_in_progress = false

	_send_json_result("godotiq:input_result", {
		"success": all_ok,
		"commands_executed": results.size(),
		"commands_total": commands.size(),
		"results": results,
		"side_effects": side_effects,
		"signal_received": signal_received,
		"signal_data": signal_data,
	}, params)


func _wait_for_signal_or_timeout(target: Node, signal_name: String, timeout: float) -> Dictionary:
	var received := false
	var timed_out := false

	var result_data: Array = []
	var callback := func(args = null):
		received = true
		if args != null:
			result_data.append(args)

	if target.has_signal(signal_name):
		target.connect(signal_name, callback, CONNECT_ONE_SHOT)

	var elapsed := 0.0
	var step := 0.05
	while not received and elapsed < timeout:
		await get_tree().create_timer(step).timeout
		elapsed += step

	if not received:
		timed_out = true
		if target.is_connected(signal_name, callback):
			target.disconnect(signal_name, callback)

	return {"received": received, "timed_out": timed_out}


func _execute_input_command(cmd: Dictionary) -> Dictionary:
	if cmd.has("wait_ms"):
		var wait_time: float = cmd["wait_ms"] / 1000.0
		await get_tree().create_timer(wait_time).timeout
		return {"type": "wait", "ms": cmd["wait_ms"], "ok": true}

	if cmd.has("actions"):
		var actions: Array = cmd["actions"]
		var hold_ms: int = cmd.get("hold_ms", 70)

		for action_name in actions:
			if InputMap.has_action(action_name):
				Input.action_press(action_name)
			else:
				return {"type": "action", "actions": actions, "ok": false, "error": "Unknown action: %s" % action_name}

		await get_tree().create_timer(hold_ms / 1000.0).timeout

		for action_name in actions:
			if InputMap.has_action(action_name):
				Input.action_release(action_name)

		return {"type": "action", "actions": actions, "hold_ms": hold_ms, "ok": true}

	if cmd.has("key"):
		var key_name: String = cmd["key"]
		var hold_ms: int = cmd.get("hold_ms", 70)
		var key_code := _key_name_to_code(key_name)
		if key_code == KEY_NONE:
			return {"type": "key", "key": key_name, "ok": false, "error": "Unknown key: %s" % key_name}

		var event_down := InputEventKey.new()
		event_down.keycode = key_code
		event_down.pressed = true
		Input.parse_input_event(event_down)

		await get_tree().create_timer(hold_ms / 1000.0).timeout

		var event_up := InputEventKey.new()
		event_up.keycode = key_code
		event_up.pressed = false
		Input.parse_input_event(event_up)

		return {"type": "key", "key": key_name, "hold_ms": hold_ms, "ok": true}

	if cmd.has("mouse_motion"):
		var motion_data: Dictionary = cmd["mouse_motion"]
		var rel_x: float = float(motion_data.get("relative_x", 0))
		var rel_y: float = float(motion_data.get("relative_y", 0))
		var event := InputEventMouseMotion.new()
		event.relative = Vector2(rel_x, rel_y)
		Input.parse_input_event(event)
		return {"type": "mouse_motion", "relative_x": rel_x, "relative_y": rel_y, "ok": true}

	if cmd.has("tap"):
		var target_name: String = cmd["tap"]
		var target_node := _find_ui_node(target_name)
		if target_node == null:
			return {"type": "tap", "target": target_name, "ok": false, "error": "UI node '%s' not found" % target_name}

		var rect: Rect2 = target_node.get_global_rect()
		var center := rect.get_center()

		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		press.position = center
		press.global_position = center
		Input.parse_input_event(press)

		await get_tree().create_timer(0.05).timeout

		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_LEFT
		release.pressed = false
		release.position = center
		release.global_position = center
		Input.parse_input_event(release)

		return {"type": "tap", "target": target_name, "position": [center.x, center.y], "ok": true}

	return {"type": "unknown", "ok": false, "error": "Unrecognized command format"}


func _find_ui_node(target_name: String) -> Control:
	return _find_control_recursive(get_tree().root, target_name)


func _find_control_recursive(node: Node, target_name: String) -> Control:
	if node is Control and node.is_visible_in_tree():
		# Exact name match
		if node.name == target_name:
			return node
		# Case-insensitive name match
		if str(node.name).to_lower() == target_name.to_lower():
			return node
		# Match by button text (for programmatically created buttons without explicit names)
		if node is BaseButton and "text" in node:
			var btn_text: String = str(node.text).strip_edges()
			if btn_text != "" and btn_text.to_lower() == target_name.to_lower():
				return node
	# Recurse ALL children — including CanvasLayer children
	for i in range(node.get_child_count()):
		var child: Node = node.get_child(i)
		var found: Control = _find_control_recursive(child, target_name)
		if found != null:
			return found
	return null


func _key_name_to_code(key_name: String) -> Key:
	var normalized := key_name.strip_edges()
	if normalized.is_empty():
		return KEY_NONE

	match normalized.to_upper():
		"ARROWUP":
			normalized = "Up"
		"ARROWDOWN":
			normalized = "Down"
		"ARROWLEFT":
			normalized = "Left"
		"ARROWRIGHT":
			normalized = "Right"
		"SPACEBAR":
			normalized = "Space"
		"PAGE UP":
			normalized = "PageUp"
		"PAGE DOWN":
			normalized = "PageDown"
		"DEL":
			normalized = "Delete"
		"ESC":
			normalized = "Escape"
		"RETURN":
			normalized = "Enter"
		"CONTROL":
			normalized = "Ctrl"

	if OS.has_method("find_keycode_from_string"):
		var os_keycode := OS.find_keycode_from_string(normalized)
		if os_keycode != KEY_NONE:
			return os_keycode

	match normalized.to_upper():
		"SPACE": return KEY_SPACE
		"ENTER": return KEY_ENTER
		"ESCAPE": return KEY_ESCAPE
		"TAB": return KEY_TAB
		"BACKSPACE": return KEY_BACKSPACE
		"UP": return KEY_UP
		"DOWN": return KEY_DOWN
		"LEFT": return KEY_LEFT
		"RIGHT": return KEY_RIGHT
		"SHIFT": return KEY_SHIFT
		"CTRL": return KEY_CTRL
		"ALT": return KEY_ALT
		"DELETE": return KEY_DELETE
		"PAGEUP": return KEY_PAGEUP
		"PAGEDOWN": return KEY_PAGEDOWN
		"HOME": return KEY_HOME
		"END": return KEY_END
		"INSERT": return KEY_INSERT
		"F1": return KEY_F1
		"F2": return KEY_F2
		"F3": return KEY_F3
		"F4": return KEY_F4
		"F5": return KEY_F5
		_:
			if normalized.length() == 1:
				return normalized.to_upper().unicode_at(0)
	return KEY_NONE


func _snapshot_scene_state() -> Dictionary:
	var state: Dictionary = {}
	var root := get_tree().root
	for child in root.get_children():
		if child == self:
			continue
		if child.get_script() == null:
			continue
		var node_state: Dictionary = {}
		for prop in child.get_property_list():
			if prop["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE:
				var val = child.get(prop["name"])
				if val is int or val is float or val is String or val is bool:
					node_state[prop["name"]] = val
				elif val is Array:
					node_state[prop["name"]] = val.size()
				elif val is Dictionary:
					node_state[prop["name"]] = val.size()
		if not node_state.is_empty():
			state[child.name] = node_state
	return state


func _diff_states(before: Dictionary, after: Dictionary) -> Array:
	var changes: Array = []
	for node_name in after.keys():
		if not before.has(node_name):
			continue
		var before_props: Dictionary = before[node_name]
		var after_props: Dictionary = after[node_name]
		for prop_name in after_props.keys():
			if before_props.has(prop_name) and before_props[prop_name] != after_props[prop_name]:
				changes.append({
					"node": node_name,
					"property": prop_name,
					"from": before_props[prop_name],
					"to": after_props[prop_name],
				})
	return changes


func _execute_code(params: Dictionary) -> void:
	var code: String = params.get("code", "")
	var timeout_ms: int = params.get("timeout_ms", 5000)

	if code.is_empty():
		_send_json_result("godotiq:exec_result", {
			"status": "ERROR",
			"result": "",
			"error": "No code provided",
		}, params)
		return

	var trimmed := code.strip_edges()
	if not trimmed.begins_with("func run():") and not trimmed.begins_with("func run() ->"):
		_send_json_result("godotiq:exec_result", {
			"status": "BLOCKED",
			"result": "",
			"error": "Code must start with 'func run():' or 'func run() -> Type:'",
		}, params)
		return

	# Safety: blocked patterns — keep in sync with godotiq_server.gd and Python exec_code._BLOCKED_PATTERNS
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
			_send_json_result("godotiq:exec_result", {
				"status": "BLOCKED",
				"result": "",
				"error": "Blocked pattern found: %s" % pattern,
			}, params)
			return

	var script := GDScript.new()
	script.source_code = "@tool\nextends RefCounted\n\n" + code
	var err := script.reload()
	if err != OK:
		_send_json_result("godotiq:exec_result", {
			"status": "COMPILE_ERROR",
			"result": "",
			"error": "Compilation failed (error %d: %s)" % [err, error_string(err)],
		}, params)
		return

	var obj = script.new()
	if obj == null:
		_send_json_result("godotiq:exec_result", {
			"status": "ERROR",
			"result": "",
			"error": "Failed to instantiate script",
		}, params)
		return

	var result = obj.run()
	var result_str: String
	if result != null:
		result_str = str(result)
	else:
		result_str = "null"

	_send_json_result("godotiq:exec_result", {
		"status": "OK",
		"result": result_str,
		"error": "",
	}, params)


func _query_state(params: Dictionary) -> void:
	var queries: Array = params.get("queries", [])
	if queries.is_empty():
		_send_json_result("godotiq:state_result", {
			"results": [],
			"error": "No queries provided",
		}, params)
		return

	var results: Array = []
	for query in queries:
		results.append(_resolve_state_query(query))

	_send_json_result("godotiq:state_result", {
		"results": results,
	}, params)


func _resolve_state_query(query: Dictionary) -> Dictionary:
	var node: Node = null

	if query.has("autoload"):
		var autoload_name: String = query["autoload"]
		node = get_tree().root.get_node_or_null(autoload_name)
		if node == null:
			node = get_tree().root.get_node_or_null("/root/" + autoload_name)
	elif query.has("node"):
		var node_path: String = query["node"]
		node = get_tree().root.get_node_or_null(node_path)
		if node == null:
			node = _find_node_recursive(get_tree().root, node_path.get_file())

	if node == null:
		var identifier: String = query.get("autoload", query.get("node", "unknown"))
		return {
			"node": identifier,
			"found": false,
			"error": "Node not found",
		}

	var properties: Array = query.get("properties", [])
	var prop_values: Dictionary = {}

	for prop_name in properties:
		prop_values[prop_name] = _get_property_safe(node, prop_name)

	return {
		"node": node.name,
		"found": true,
		"class": node.get_class(),
		"properties": prop_values,
	}


func _get_property_safe(node: Node, prop_name: String) -> Variant:
	if prop_name.ends_with("()"):
		var parts := prop_name.split(".")
		if parts.size() == 2:
			var obj_prop: String = parts[0]
			var method: String = parts[1].replace("()", "")
			var obj = node.get(obj_prop)
			if obj != null and obj.has_method(method):
				return obj.call(method)
			elif obj is Array and method == "size":
				return obj.size()
			elif obj is Dictionary and method == "size":
				return obj.size()
			return "ERROR: cannot call %s on %s" % [method, obj_prop]

	if ":" in prop_name:
		return _serialize_value(node.get_indexed(prop_name))

	if "." in prop_name and not prop_name.ends_with("()"):
		var parts := prop_name.split(".")
		var current = node
		for part in parts:
			if current == null:
				return "ERROR: null in chain at '%s'" % part
			if current is Object:
				current = current.get(part)
			else:
				return "ERROR: cannot access '%s'" % part
		return _serialize_value(current)

	var val = node.get(prop_name)
	return _serialize_value(val)


func _serialize_value(val) -> Variant:
	if val == null:
		return null
	if val is int or val is float or val is String or val is bool:
		return val
	if val is Vector3:
		return [snapped(val.x, 0.001), snapped(val.y, 0.001), snapped(val.z, 0.001)]
	if val is Vector2:
		return [snapped(val.x, 0.01), snapped(val.y, 0.01)]
	if val is Color:
		return [val.r, val.g, val.b, val.a]
	if val is Array:
		if val.size() > 20:
			return {"type": "Array", "size": val.size(), "preview": str(val).left(200)}
		return str(val)
	if val is Dictionary:
		if val.size() > 20:
			return {"type": "Dictionary", "size": val.size(), "keys": str(val.keys()).left(200)}
		var result: Dictionary = {}
		for key in val.keys():
			result[str(key)] = _serialize_value(val[key])
		return result
	if val is NodePath:
		return str(val)
	if val is Resource:
		var res_path: String = "inline"
		if val.resource_path:
			res_path = val.resource_path
		return {"type": val.get_class(), "path": res_path}
	if val is Object:
		return {"type": val.get_class(), "id": val.get_instance_id()}
	return str(val)


func _find_node_recursive(node: Node, target_name: String) -> Node:
	if node.name == target_name:
		return node
	for child in node.get_children():
		var found := _find_node_recursive(child, target_name)
		if found:
			return found
	return null


# --- Navigation query ---

func _handle_nav_query(params: Dictionary) -> void:
	var world := get_tree().root.get_world_3d()
	if world == null:
		_send_json_result("godotiq:nav_result", {
			"error": "No World3D available",
		}, params)
		return

	var map_rid: RID = world.get_navigation_map()
	var from_pos := Vector3.ZERO
	var to_pos := Vector3.ZERO

	# Resolve from position
	if params.has("from_node"):
		var from_node := _find_node_recursive(get_tree().root, str(params["from_node"]))
		if from_node == null or not (from_node is Node3D):
			_send_json_result("godotiq:nav_result", {
				"error": "from_node '%s' not found or not Node3D" % str(params["from_node"]),
			}, params)
			return
		from_pos = (from_node as Node3D).global_position
	elif params.has("from_position"):
		var fp: Array = params["from_position"]
		if fp.size() >= 3:
			from_pos = Vector3(float(fp[0]), float(fp[1]), float(fp[2]))

	# Resolve to position
	if params.has("to_node"):
		var to_node := _find_node_recursive(get_tree().root, str(params["to_node"]))
		if to_node == null or not (to_node is Node3D):
			_send_json_result("godotiq:nav_result", {
				"error": "to_node '%s' not found or not Node3D" % str(params["to_node"]),
			}, params)
			return
		to_pos = (to_node as Node3D).global_position
	elif params.has("to_position"):
		var tp: Array = params["to_position"]
		if tp.size() >= 3:
			to_pos = Vector3(float(tp[0]), float(tp[1]), float(tp[2]))

	# Snap to navmesh
	var closest_from := NavigationServer3D.map_get_closest_point(map_rid, from_pos)
	var closest_to := NavigationServer3D.map_get_closest_point(map_rid, to_pos)
	var from_on_nav: bool = from_pos.distance_to(closest_from) < 0.5
	var to_on_nav: bool = to_pos.distance_to(closest_to) < 0.5

	# Get path
	var optimize: bool = params.get("optimize", true)
	var path: PackedVector3Array = NavigationServer3D.map_get_path(
		map_rid, closest_from, closest_to, optimize
	)

	# Calculate distance
	var total_distance: float = 0.0
	var i: int = 0
	while i < path.size() - 1:
		total_distance += path[i].distance_to(path[i + 1])
		i += 1
	var direct_distance: float = from_pos.distance_to(to_pos)

	var efficiency: float = 0.0
	if total_distance > 0.001:
		efficiency = direct_distance / total_distance
	elif direct_distance < 0.001:
		efficiency = 1.0

	# Serialize path points (cap at 50)
	var path_points: Array = []
	var step: int = 1
	if path.size() > 50:
		step = int(ceil(float(path.size()) / 50.0))
	var idx: int = 0
	while idx < path.size():
		var p: Vector3 = path[idx]
		path_points.append([snapped(p.x, 0.01), snapped(p.y, 0.01), snapped(p.z, 0.01)])
		idx += step
	# Always include last point
	if path.size() > 0:
		var last: Vector3 = path[path.size() - 1]
		var last_arr: Array = [snapped(last.x, 0.01), snapped(last.y, 0.01), snapped(last.z, 0.01)]
		if path_points.size() == 0 or path_points[path_points.size() - 1] != last_arr:
			path_points.append(last_arr)

	_send_json_result("godotiq:nav_result", {
		"reachable": path.size() > 1,
		"distance": snapped(total_distance, 0.01),
		"direct_distance": snapped(direct_distance, 0.01),
		"efficiency_ratio": snapped(efficiency, 0.01),
		"path_points": path_points,
		"waypoint_count": path.size(),
		"from_on_navmesh": from_on_nav,
		"to_on_navmesh": to_on_nav,
		"from_position": [snapped(from_pos.x, 0.01), snapped(from_pos.y, 0.01), snapped(from_pos.z, 0.01)],
		"to_position": [snapped(to_pos.x, 0.01), snapped(to_pos.y, 0.01), snapped(to_pos.z, 0.01)],
	}, params)


# --- Watch system ---

func _handle_watch(params: Dictionary) -> void:
	var action: String = params.get("action", "")

	match action:
		"start":
			var watch_list: Array = params.get("watches", [])
			var interval_ms: int = params.get("sample_interval_ms", 500)
			_watch_sample_interval = interval_ms / 1000.0
			if _watch_sample_interval < 0.05:
				_watch_sample_interval = 0.05

			for w in watch_list:
				var node_name: String = w.get("node", "")
				var properties: Array = w.get("properties", [])
				if node_name.is_empty() or properties.is_empty():
					continue

				var node: Node = _find_node_recursive(get_tree().root, node_name)
				if node == null:
					node = get_tree().root.get_node_or_null(node_name)
				if node == null:
					node = get_tree().root.get_node_or_null("/root/" + node_name)

				if node == null:
					_watch_events.append({
						"t": snapped(Time.get_ticks_msec() / 1000.0, 0.001),
						"node": node_name,
						"error": "Node not found",
					})
					continue

				var initial_values: Dictionary = {}
				for prop in properties:
					initial_values[prop] = _get_watch_value(node, prop)

				_watches[node_name] = {
					"node": node,
					"properties": properties,
					"last_values": initial_values,
				}

			_watch_active = true
			_send_json_result("godotiq:watch_result", {
				"action": "start",
				"watches_active": _watches.size(),
				"sample_interval_ms": int(_watch_sample_interval * 1000),
			}, params)

		"stop":
			_watches.clear()
			_watch_active = false
			_send_json_result("godotiq:watch_result", {
				"action": "stop",
				"watches_active": 0,
			}, params)

		"read":
			var events_copy: Array = _watch_events.duplicate()
			_send_json_result("godotiq:watch_result", {
				"action": "read",
				"events": events_copy,
				"events_total": events_copy.size(),
				"watches_active": _watches.size(),
			}, params)

		"clear":
			_watch_events.clear()
			_send_json_result("godotiq:watch_result", {
				"action": "clear",
				"events_cleared": true,
				"watches_active": _watches.size(),
			}, params)

		_:
			_send_json_result("godotiq:watch_result", {
				"error": "Unknown action: %s. Use start/stop/read/clear." % action,
			}, params)


func _sample_watched_nodes() -> void:
	var now: float = snapped(Time.get_ticks_msec() / 1000.0, 0.001)
	var to_remove: Array = []

	for node_name in _watches.keys():
		var watch: Dictionary = _watches[node_name]
		var node: Node = watch["node"]

		if not is_instance_valid(node):
			_watch_events.append({
				"t": now,
				"node": node_name,
				"error": "Node freed",
			})
			to_remove.append(node_name)
			continue

		var properties: Array = watch["properties"]
		var last_values: Dictionary = watch["last_values"]

		for prop in properties:
			var current_val = _get_watch_value(node, prop)
			var last_val = last_values.get(prop)
			if str(current_val) != str(last_val):
				_watch_events.append({
					"t": now,
					"node": node_name,
					"property": prop,
					"from": _serialize_watch_value(last_val),
					"to": _serialize_watch_value(current_val),
				})
				last_values[prop] = current_val

	for name in to_remove:
		_watches.erase(name)

	# Cap events to prevent memory issues
	if _watch_events.size() > 1000:
		_watch_events = _watch_events.slice(_watch_events.size() - 500)


func _get_watch_value(node: Node, prop_name: String) -> Variant:
	# Handle method calls like "pending_orders.size()"
	if prop_name.ends_with("()"):
		var parts: Array = prop_name.split(".")
		if parts.size() == 2:
			var obj = node.get(parts[0])
			var method_name: String = parts[1].replace("()", "")
			if obj != null:
				if obj is Array and method_name == "size":
					return obj.size()
				elif obj is Dictionary and method_name == "size":
					return obj.size()
				elif obj.has_method(method_name):
					return obj.call(method_name)
		return null
	# Sub-path like "position:x"
	if ":" in prop_name:
		return node.get_indexed(prop_name)
	return node.get(prop_name)


func _serialize_watch_value(val) -> Variant:
	if val == null:
		return null
	if val is int or val is float or val is String or val is bool:
		return val
	if val is Vector3:
		return [snapped(val.x, 0.01), snapped(val.y, 0.01), snapped(val.z, 0.01)]
	if val is Vector2:
		return [snapped(val.x, 0.01), snapped(val.y, 0.01)]
	return str(val)


# --- UI Map ---

func _handle_ui_map(params: Dictionary) -> void:
	var root_name: String = params.get("root", "")
	var include_invisible: bool = params.get("include_invisible", false)
	var max_depth: int = params.get("max_depth", 10)
	var detail: String = params.get("detail", "normal")

	var root_node: Node = null
	if root_name.is_empty():
		root_node = get_tree().root
	else:
		root_node = get_tree().root.get_node_or_null(root_name)
		if root_node == null:
			root_node = get_tree().root.get_node_or_null("/root/" + root_name)
		if root_node == null:
			root_node = _find_node_recursive(get_tree().root, root_name)

	if root_node == null:
		_send_json_result("godotiq:ui_map_result", {
			"error": "Root node '%s' not found" % root_name,
		}, params)
		return

	var layout: Array = []
	_walk_ui_tree(root_node, layout, 0, max_depth, include_invisible, detail)

	var interactive_count: int = 0
	var touch_too_small: Array = []
	var total_controls: int = _count_ui_controls(layout)

	_collect_ui_stats_flat(layout, touch_too_small)
	interactive_count = _count_interactive(layout)

	_send_json_result("godotiq:ui_map_result", {
		"root": str(root_node.name),
		"total_controls": total_controls,
		"interactive_elements": interactive_count,
		"touch_targets_too_small": touch_too_small,
		"layout": layout,
	}, params)


func _walk_ui_tree(node: Node, result: Array, depth: int, max_depth: int, include_invisible: bool, detail: String) -> void:
	if depth > max_depth:
		return

	if node is Control:
		var ctrl: Control = node as Control

		if not include_invisible and not ctrl.is_visible_in_tree():
			return

		var item: Dictionary = {
			"name": str(ctrl.name),
			"type": ctrl.get_class(),
			"visible": ctrl.is_visible_in_tree(),
		}

		var rect: Rect2 = ctrl.get_global_rect()
		item["rect"] = [
			int(rect.position.x), int(rect.position.y),
			int(rect.position.x + rect.size.x), int(rect.position.y + rect.size.y)
		]
		item["size"] = [int(rect.size.x), int(rect.size.y)]

		if ctrl is Label:
			item["text"] = (ctrl as Label).text.left(100)
		elif ctrl is BaseButton:
			item["interactive"] = true
			if ctrl is Button:
				item["text"] = (ctrl as Button).text.left(100)
			item["disabled"] = (ctrl as BaseButton).disabled
		elif ctrl is RichTextLabel:
			item["text"] = (ctrl as RichTextLabel).get_parsed_text().left(100)
		elif ctrl is LineEdit:
			item["text"] = (ctrl as LineEdit).text.left(100)
			item["interactive"] = true
			item["placeholder"] = (ctrl as LineEdit).placeholder_text.left(50)
		elif ctrl is TextEdit:
			item["text"] = (ctrl as TextEdit).text.left(100)
			item["interactive"] = true

		if ctrl is Slider:
			item["interactive"] = true
			item["value"] = (ctrl as Slider).value
		elif ctrl is SpinBox:
			item["interactive"] = true
			item["value"] = (ctrl as SpinBox).value

		if detail == "full":
			item["modulate"] = [ctrl.modulate.r, ctrl.modulate.g, ctrl.modulate.b, ctrl.modulate.a]
			item["mouse_filter"] = ctrl.mouse_filter
			if ctrl.get_script() != null:
				var script_res: Script = ctrl.get_script()
				var script_path: String = ""
				if script_res.resource_path:
					script_path = script_res.resource_path
				item["script"] = script_path

		var children: Array = []
		for child in node.get_children():
			_walk_ui_tree(child, children, depth + 1, max_depth, include_invisible, detail)

		if not children.is_empty():
			item["children"] = children

		result.append(item)

	elif node is CanvasLayer:
		var layer_item: Dictionary = {
			"name": str(node.name),
			"type": "CanvasLayer",
			"layer": (node as CanvasLayer).layer,
		}
		var children: Array = []
		for child in node.get_children():
			_walk_ui_tree(child, children, depth + 1, max_depth, include_invisible, detail)
		if not children.is_empty():
			layer_item["children"] = children
		result.append(layer_item)

	else:
		for child in node.get_children():
			_walk_ui_tree(child, result, depth + 1, max_depth, include_invisible, detail)


func _count_ui_controls(items: Array) -> int:
	var count: int = 0
	for item in items:
		if item is Dictionary:
			var item_type: String = item.get("type", "")
			if item_type != "CanvasLayer":
				count += 1
			if item.has("children"):
				count += _count_ui_controls(item["children"])
	return count


func _count_interactive(items: Array) -> int:
	var count: int = 0
	for item in items:
		if item is Dictionary:
			if item.get("interactive", false):
				count += 1
			if item.has("children"):
				count += _count_interactive(item["children"])
	return count


func _collect_ui_stats_flat(items: Array, touch_too_small: Array) -> void:
	for item in items:
		if item is Dictionary:
			if item.get("interactive", false):
				var size: Array = item.get("size", [0, 0])
				if size.size() >= 2:
					var min_px: int = 48
					if size[0] < min_px or size[1] < min_px:
						touch_too_small.append({
							"node": item.get("name", ""),
							"size": size,
							"min_recommended": [min_px, min_px],
						})
			if item.has("children"):
				_collect_ui_stats_flat(item["children"], touch_too_small)


# --- Explore camera ---

func _handle_explore_camera(params: Dictionary) -> void:
	var action: String = params.get("action", "")
	var scene_root := get_tree().root
	if scene_root == null:
		_send_json_result("godotiq:explore_camera_result", {
			"error": "No scene tree root available",
			"code": "NO_SCENE_ROOT",
		}, params)
		return

	match action:
		"create":
			# Clean up any existing drone camera first (use free() not queue_free()
			# to avoid name deduplication when the new drone is added immediately)
			var existing = scene_root.get_node_or_null("GodotIQ_DroneCam")
			if existing:
				existing.free()

			# Store reference to current camera before switching
			var original_cam: Camera3D = get_viewport().get_camera_3d()
			var original_cam_path := ""
			if original_cam:
				original_cam_path = str(scene_root.get_path_to(original_cam))

			# Create drone
			var drone := Camera3D.new()
			drone.name = "GodotIQ_DroneCam"
			drone.set_meta("original_camera_path", original_cam_path)
			drone.fov = float(params.get("fov", 70.0))
			scene_root.add_child(drone)
			drone.make_current()

			_send_json_result("godotiq:explore_camera_result", {
				"status": "created",
				"original_camera": original_cam_path,
			}, params)

		"move":
			var drone = scene_root.get_node_or_null("GodotIQ_DroneCam")
			if drone == null:
				_send_json_result("godotiq:explore_camera_result", {
					"error": "GodotIQ_DroneCam not found",
					"code": "DRONE_NOT_FOUND",
				}, params)
				return

			var pos: Array = params.get("position", [0, 0, 0])
			drone.global_position = Vector3(float(pos[0]), float(pos[1]), float(pos[2]))

			if params.has("look_at"):
				var target_arr: Array = params["look_at"]
				var target := Vector3(float(target_arr[0]), float(target_arr[1]), float(target_arr[2]))
				var dist: float = drone.global_position.distance_to(target)
				if dist > 0.001:
					var direction: Vector3 = (target - drone.global_position).normalized()
					if abs(direction.dot(Vector3.UP)) > 0.99:
						drone.look_at(target, Vector3.FORWARD)
					else:
						drone.look_at(target, Vector3.UP)
			elif params.has("rotation"):
				var rot: Array = params["rotation"]
				drone.rotation_degrees = Vector3(float(rot[0]), float(rot[1]), float(rot[2]))

			if params.has("fov"):
				drone.fov = float(params["fov"])

			_send_json_result("godotiq:explore_camera_result", {
				"status": "moved",
				"position": [drone.global_position.x, drone.global_position.y, drone.global_position.z],
				"rotation": [drone.rotation_degrees.x, drone.rotation_degrees.y, drone.rotation_degrees.z],
			}, params)

		"destroy":
			var drone = scene_root.get_node_or_null("GodotIQ_DroneCam")
			if drone == null:
				_send_json_result("godotiq:explore_camera_result", {
					"status": "destroyed",
				}, params)
				return

			var original_path: String = drone.get_meta("original_camera_path", "")
			if original_path != "":
				var original_cam = scene_root.get_node_or_null(original_path)
				if is_instance_valid(original_cam) and original_cam is Camera3D:
					original_cam.make_current()

			drone.queue_free()

			_send_json_result("godotiq:explore_camera_result", {
				"status": "destroyed",
			}, params)

		_:
			_send_json_result("godotiq:explore_camera_result", {
				"error": "Unknown action: %s" % action,
				"code": "UNKNOWN_ACTION",
			}, params)
