@tool
extends EditorPlugin
## GodotIQ editor plugin — lifecycle manager for the addon.
## Creates and wires the WebSocket server, debugger plugin, and runtime autoload.

const AUTOLOAD_NAME := "GodotIQRuntime"
const RUNTIME_PATH := "res://addons/godotiq/godotiq_runtime.gd"

var _server  # WebSocket server node (godotiq_server.gd)
var _debugger  # EditorDebuggerPlugin (godotiq_debugger.gd)
var _bottom_panel: Control


func _enter_tree() -> void:
	# 1. Create WebSocket server as child node
	_server = preload("res://addons/godotiq/godotiq_server.gd").new()
	add_child(_server)

	# 2. Create debugger plugin, wire cross-references, register it
	_debugger = preload("res://addons/godotiq/godotiq_debugger.gd").new()
	_debugger.server = _server
	_server.debugger = _debugger
	add_debugger_plugin(_debugger)

	# 3. Wire undo/redo manager for node operations
	_server.undo_redo = get_undo_redo()

	# 4. Register runtime autoload singleton
	add_autoload_singleton(AUTOLOAD_NAME, RUNTIME_PATH)

	# 5. Add bottom panel
	_bottom_panel = _create_bottom_panel()
	add_control_to_bottom_panel(_bottom_panel, "GodotIQ")

	# 6. Give server a reference to update the status label
	_server.status_label = _bottom_panel.get_node("StatusLabel")


func _exit_tree() -> void:
	# 1. Remove bottom panel
	if _bottom_panel:
		remove_control_from_bottom_panel(_bottom_panel)
		_bottom_panel.queue_free()
		_bottom_panel = null

	# 2. Remove autoload singleton
	remove_autoload_singleton(AUTOLOAD_NAME)

	# 3. Remove and null debugger plugin
	if _debugger:
		remove_debugger_plugin(_debugger)
		_debugger = null

	# 4. Free and null server node
	if _server:
		_server.queue_free()
		_server = null


func _create_bottom_panel() -> Control:
	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size = Vector2(0, 80)

	var title := Label.new()
	title.text = "GodotIQ v%s" % _server.ADDON_VERSION
	title.add_theme_font_size_override("font_size", 16)
	vbox.add_child(title)

	var status_label := Label.new()
	status_label.name = "StatusLabel"
	status_label.text = "Server: Starting..."
	vbox.add_child(status_label)

	var tools_label := Label.new()
	tools_label.name = "ToolsLabel"
	tools_label.text = "Tools: 35 registered"
	vbox.add_child(tools_label)

	return vbox

