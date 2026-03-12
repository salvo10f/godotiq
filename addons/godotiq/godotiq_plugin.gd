@tool
extends EditorPlugin
## GodotIQ editor plugin — lifecycle manager for the addon.
## Creates and wires the WebSocket server, debugger plugin, and runtime autoload.

const AUTOLOAD_NAME := "GodotIQRuntime"
const RUNTIME_PATH := "res://addons/godotiq/godotiq_runtime.gd"

var _server  # WebSocket server node (godotiq_server.gd)
var _debugger  # EditorDebuggerPlugin (godotiq_debugger.gd)


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


func _exit_tree() -> void:
	# 1. Remove autoload singleton
	remove_autoload_singleton(AUTOLOAD_NAME)

	# 2. Remove and null debugger plugin
	if _debugger:
		remove_debugger_plugin(_debugger)
		_debugger = null

	# 3. Free and null server node
	if _server:
		_server.queue_free()
		_server = null

