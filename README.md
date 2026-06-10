# GodotIQ

Intelligent MCP server for Godot 4. Spatial intelligence, code analysis, and **38 tools**.

**Version:** 0.5.8
**Repository:** https://github.com/salvo10f/godotiq

## Install

```bash
pip install godotiq==0.5.8
```

For AI clients, no manual install is required. Use `uvx` in your MCP config so the
client auto-installs GodotIQ on first use:

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

For Pro, add `"GODOTIQ_LICENSE_KEY": "YOUR_POLAR_LICENSE_KEY"` to the same `env`
block. Do not wrap `uvx` with the Unix-only `env` command; this config works on
Windows, macOS, and Linux.

Install the Godot addon into a project:

```bash
uvx godotiq install-addon /path/to/your/godot/project
```

Or clone and install the Godot addon directly from `godot-addon/addons/godotiq/`.

## Pro tier

The full suite of analysis tools (dependency graphs, impact checks, scene/spatial mapping, signal/flow tracing) ships as an optional Pro bundle. Community mode shows rich previews of every Pro tool so you can see what you'd unlock before upgrading.

Upgrade to Pro: https://godotiq.com/pro

Pro activation uses a signed-receipt model — no network I/O on the hot path once activated. Commerce is powered by polar.sh.

## Documentation

- Full docs: https://godotiq.com/docs
- Issue tracker: https://github.com/salvo10f/godotiq/issues

## License

MIT — see [LICENSE](LICENSE).
