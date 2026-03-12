# GodotIQ

**The only Godot MCP that understands your game, not just your files.**

GodotIQ is a Model Context Protocol (MCP) server for Godot 4.x that gives AI agents (Claude Code, Cursor, Windsurf) spatial intelligence, code understanding, and runtime control. 35 tools across 9 categories — from smart object placement to signal flow tracing to automated UI mapping.

Other Godot MCPs are API wrappers. GodotIQ is an intelligence layer.

---

## What It Does

```
Before GodotIQ:
  Agent: "I'll move this shelf to (2, 0, 0)"
  Result: Inside a wall. 10 iterations to fix.

After GodotIQ:
  Agent calls placement → knows empty slots, walls, navmesh, nearby objects
  Agent calls node_ops(validate=true) → validated placement, first try
  Agent calls camera + screenshot → visually confirms result
  Done.
```

### Key Capabilities No Other MCP Has

- **Spatial Intelligence** — `scene_map`, `placement`, `spatial_audit`. Understands 3D space: distances, walls, navmesh, empty slots, scale consistency
- **Signal Flow Tracing** — `trace_flow`. "What happens when the player accepts an order?" → complete chain across 8 files with failure points
- **Code Understanding** — `dependency_graph`, `signal_map`, `impact_check`. Knows who calls who, what breaks if you change a function
- **Smart Placement** — `placement` finds designer-intended Marker3D slots first (95% confidence), falls back to grid search with constraint solving
- **Runtime UI Mapping** — `ui_map`. Maps every button, label, and input with screen positions, text content, touch target validation
- **Visual Verification** — `camera` + `screenshot` (editor viewport). Agent looks at what it changed before moving on
- **Convention Enforcement** — `validate` checks and auto-fixes GDScript conventions after every edit
- **Project Memory** — `project_summary`, `file_context`. Agent re-primes instantly after context compaction

### 35 Tools in 9 Categories

| Category | Tools | Addon Required |
|----------|-------|---------------|
| **Bridge** (runtime) | screenshot, scene_tree, run, input, node_ops, script_ops, file_ops, exec, state_inspect, perf_snapshot, save_scene, camera, watch, undo_history, nav_query, build_scene, check_errors, verify_motion | YES |
| **Spatial** (3D intelligence) | scene_map, placement, spatial_audit | Optional |
| **Code** (analysis) | dependency_graph, signal_map, impact_check, validate | NO |
| **Animation** | animation_info, animation_audit | NO |
| **Flow & Debug** | trace_flow | NO |
| **Assets** | asset_registry, suggest_scale | NO |
| **Memory** | project_summary, file_context | NO |
| **UI** | ui_map | YES |
| **Navigation** | nav_query | YES |

17 tools work from filesystem alone (no Godot running). 18 tools need the lightweight GDScript addon.

---

## Setup

### 1. Install GodotIQ

**Direct install:**

```bash
pip install godotiq
```

**For AI clients (recommended):** No manual install needed. Configure the MCP client to use `uvx` which auto-installs on first use (see step 3).

### 2. Install the Godot Addon

```bash
godotiq install-addon /path/to/your/godot/project
```

This copies:
- The GDScript addon files to `<project>/addons/godotiq/`
- `GODOTIQ_RULES.md` to the project root (AI assistant rules for Godot development)

Use `--dry-run` to preview what will be copied.

Then enable the addon in Godot via Project Settings → Plugins → GodotIQ → Enable.

The addon is pure GDScript (~500 lines, no compilation). It starts a WebSocket server on port 6007 for bidirectional communication with the MCP server.

### 3. Configure Your AI Client

Create `.mcp.json` in your Godot project root:

```json
{
  "mcpServers": {
    "godotiq": {
      "command": "uvx",
      "args": ["godotiq"],
      "env": {
        "GODOTIQ_PROJECT_ROOT": "/path/to/your/godot/project"
      }
    }
  }
}
```

Then launch Claude Code from your project directory:

```bash
cd /path/to/your/godot/project
claude
```

Claude Code reads `.mcp.json` automatically and connects to GodotIQ with 35 tools available.

### 4. (Optional) Project Configuration

Create `.godotiq.json` in your Godot project root for project-specific settings:

```json
{
  "version": 2,
  "project": {
    "name": "My Game",
    "engine": "godot_4",
    "type": "3d"
  },
  "disabled_tools": [],
  "protected_files": ["project.godot", ".godot/**", "*.import"],
  "conventions": {
    "class_name_suffix": "Class",
    "signal_bus": "Events",
    "require_type_hints": true
  },
  "asset_origins": {
    "meshy": {
      "path_patterns": ["assets/models/printers/**"],
      "default_scale": [0.3, 0.3, 0.3]
    }
  },
  "server": {
    "default_detail": "normal",
    "screenshot_default_scale": 0.25
  }
}
```

---

## Architecture

```
godotiq/
├── src/godotiq/
│   ├── server.py              # MCP server (FastMCP, stdio transport)
│   ├── config.py              # .godotiq.json configuration loader
│   ├── session.py             # Project session management
│   ├── parsers/               # .tscn, .gd file parsers (zero external deps)
│   │   ├── tscn_parser.py     # Godot scene format parser
│   │   ├── gd_parser.py       # GDScript parser (signals, deps, functions)
│   │   ├── scene_resolver.py  # Instance expansion, world-space transforms
│   │   └── project_index.py   # Full project scan, cross-reference maps
│   ├── cache/                 # Hash-based file cache
│   └── tools/                 # 9 categories, 35 tools
│       ├── bridge/            # Runtime: screenshot, run, input, node_ops, exec...
│       ├── spatial/           # scene_map, placement, spatial_audit
│       ├── code/              # dependency_graph, signal_map, impact_check, validate
│       ├── animation/         # animation_info, animation_audit
│       ├── flow/              # trace_flow
│       ├── assets/            # asset_registry, suggest_scale
│       ├── memory/            # project_summary, file_context
│       ├── ui/                # ui_map
│       └── navigation/        # nav_query
├── godot-addon/
│   └── addons/godotiq/
│       ├── plugin.cfg
│       ├── godotiq_plugin.gd      # EditorPlugin entry point
│       ├── godotiq_server.gd      # WebSocket server (editor-side)
│       ├── godotiq_runtime.gd     # Autoload (game-side, screenshots + input)
│       └── godotiq_debugger.gd    # EditorDebuggerPlugin (error capture)
├── tests/                     # 1100+ automated tests
│   ├── fixtures/              # Real .tscn/.gd files from Godot projects
│   └── test_*/                # Test suites per category
└── .godotiq.json              # Example project configuration
```

### Communication Stack

```
AI Agent ←(stdio)→ Python MCP Server ←(WebSocket:6007)→ GDScript Addon in Godot Editor
                   (intelligence layer)                    (runtime bridge)
                                                              ↕
                                                    EngineDebugger (IPC)
                                                              ↕
                                                    Running Game (autoload)
```

- **Python → Editor**: WebSocket for bidirectional real-time communication
- **Editor → Game**: EngineDebugger native IPC for screenshots, input simulation, state inspection
- **Intelligence layer**: All parsing, spatial reasoning, dependency analysis, convention validation runs in Python — works without Godot open

### Three-Layer Parser Architecture

1. **Layer 1 — Raw Parser**: Reads single .tscn/.gd file, extracts structure
2. **Layer 2 — Scene Resolver**: Expands instances recursively, calculates world-space transforms
3. **Layer 3 — Project Index**: Scans all files, builds cross-reference maps (signal wiring, autoloads, asset usage)

---

## Token Optimization

Every tool accepts `detail: "brief" | "normal" | "full"`:

- **brief** → 5-15 lines, key facts only. Use for routine checks.
- **normal** → Default. Structured data for most operations.
- **full** → Complete dump with metadata. Use for deep debugging.

This cuts response sizes 50-80% for routine operations, saving context window space.

---

## Development

```bash
# Run all tests
pytest tests/ -v

# Run specific category
pytest tests/test_tools/ -v
pytest tests/test_parsers/ -v

# Run with coverage
pytest tests/ --cov=godotiq -v
```

### Test Stats
- 1100+ automated tests
- Real .tscn/.gd fixtures from production Godot projects
- Parser tests, tool tests, integration tests, config tests

---

## Comparison

| Capability | GodotIQ (35 tools) | GDAI (27 tools, $20) | tomyud1 (32 tools, free) |
|---|---|---|---|
| Spatial intelligence | ✅ scene_map + placement + validation | ❌ | ❌ |
| Signal flow tracing | ✅ trace_flow | ❌ | ❌ |
| Code understanding | ✅ deps + signals + impact | ❌ | ❌ |
| Convention validation | ✅ auto-fix | ❌ | ❌ |
| Project memory | ✅ survives compaction | ❌ | ❌ |
| UI mapping | ✅ ui_map | ❌ | ❌ |
| Visual verification | ✅ camera + editor screenshot | ❌ (editor screenshot only) | ❌ |
| Token optimization | ✅ 3 detail levels | ❌ | ❌ |
| Works without addon | ✅ 17 tools | ❌ | ❌ |
| Open source | ✅ | ❌ (C++ binary) | ✅ |
| Telemetry | Zero | PostHog | Zero |
| Automated tests | 1100+ | Unknown | 0 |

---

## License

MIT
