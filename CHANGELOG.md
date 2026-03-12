# Changelog

All notable changes to GodotIQ will be documented in this file.

## [0.1.0] - 2026-03-12

### Initial Release

First public release of GodotIQ — the definitive MCP for AI-assisted Godot development.

**35 tools across 9 categories:**

- **Bridge** (18 tools) — Runtime control: screenshot, scene_tree, run, input, node_ops, script_ops, file_ops, exec, state_inspect, perf_snapshot, save_scene, camera, watch, undo_history, build_scene, check_errors, verify_motion, nav_query
- **Spatial** (3 tools) — 3D intelligence: scene_map, placement, spatial_audit
- **Code** (4 tools) — Static analysis: dependency_graph, signal_map, impact_check, validate
- **Animation** (2 tools) — animation_info, animation_audit
- **Flow** (1 tool) — trace_flow
- **Assets** (2 tools) — asset_registry, suggest_scale
- **Memory** (2 tools) — project_summary, file_context
- **UI** (1 tool) — ui_map
- **Navigation** (1 tool) — nav_query

**Key features:**

- Three-layer parser architecture (raw parser, scene resolver, project index)
- WebSocket bridge to Godot editor via lightweight GDScript addon
- Token optimization with 3 detail levels (brief/normal/full)
- Smart object placement with Marker3D detection and constraint solving
- Signal flow tracing across multiple files
- Convention validation with auto-fix suggestions
- PRO tier with Polar.sh license validation
- Cross-platform support (macOS, Linux, Windows)
- CLI with `install-addon` subcommand
- 1100+ automated tests
