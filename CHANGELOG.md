# Changelog

## [0.5.8] - 2026-06-10

Hardening release driven by a verified dogfooding bug registry (8 bugs + 4 audit findings, each independently confirmed or refuted against source before fixing). The common theme: GodotIQ no longer silently misreports runtime or resource state — when something is not running, not attached, stale, or unknown, tools now say so explicitly instead of guessing.

### Fixed

- **`run` no longer reports bare success for a game the runtime tools can't reach.** The addon previously answered `success: true` as soon as the scene was playing, even when the GodotIQ runtime handshake never completed — so follow-up tools (`screenshot`, `input`, `state_inspect`, `exec` in game context) failed with misleading `GAME_NOT_RUNNING`/timeouts. `run` now waits for the runtime to attach and always reports a `runtime_attached` field (with a warning when false), and game-side tools answer an immediate, explicit `RUNTIME_NOT_ATTACHED` instead of hanging to a timeout. Verified end-to-end on a real editor: the not-attached rejection now returns in ~10ms instead of a 5s timeout.
- **`verify_project_runs` works again and is honest about launch state.** A wrapper bug (`session.root` → `AttributeError`) made the tool error out on every call; fixed. A launch that succeeds without runtime attach is now reported INCONCLUSIVE (never a false PASS), and the game is stopped on that path too (`stop_after` is honored on every early exit).
- **Signal analysis sees `emit_signal("name")` emissions.** The emission scanner only matched `.emit()`; signals emitted exclusively via `emit_signal(...)` (including `&"name"` StringName form, on any receiver) were invisible and could be flagged unused. The scanner is also now string-masked, multi-match, and multiline-aware: quoted mentions inside string literals no longer record phantom emissions, several emissions on one physical line are all recorded, calls spanning lines are detected, and commas/parens inside string arguments no longer miscount payload args.
- **Direct-disk scene writes are guarded while the Godot editor is open.** Writing/moving/deleting `.tscn`/`.scn` files behind a running editor's back risks stale-buffer overwrites and UID cache divergence. `file_ops` and `script_ops` now detect an editor on the same project (bridge-first, then a strict process scan) and refuse risky writes with `BLOCKED_EDITOR_OPEN` plus safe alternatives (bridge ops, which remain always allowed). Opt out via `.godotiq.json` `{"editor_guard": {"enabled": false}}`; dry runs are never blocked.
- **UID diagnostics label their source of truth.** `uid_to_path`/`path_to_uid` results now carry `resolution_source` (`tscn_text`, `disk_import_cache`, or `uid_file`) so a fresh-disk answer is never mistaken for the editor's live view, and an opt-in `check_uid_divergence` probes the editor's in-memory `ResourceUID` over the bridge, reporting `UID_CACHE_DIVERGENCE` (with a restart recommendation — never a blind reimport) when editor and disk disagree.
- **`input` exercises the real input pipeline.** Action commands previously used `Input.action_press()` (state-only — `_input` handlers never saw them). They now go through `parse_input_event` with real `InputEventAction`s by default (`via: "state"` keeps the legacy behavior), advance a configurable number of frames after press/release, validate action names up front, and report `delivery`/`pipeline_exercised`/`frames_advanced` so tests can't silently pass without the game reacting.
- **`check_errors` no longer invents line 0.** On Godot versions where script error lines are unavailable, errors now report `line: null` + `line_unavailable: true` with softened confidence notes ("may still be real"), instead of a fabricated line 0 that read like a false positive.
- **`validate(project)` no longer serves stale analysis after external edits.** Sessions now refresh known files mtime-gated before project-wide reads (`refresh_if_stale()`), per-file parse failures are tolerated and retried instead of breaking every code tool, and a failed scene re-parse serves the last good parse (self-healing on the next read) rather than evicting the scene forever.
- **`scene_map` flags scenes without a stable UID** with a `scene_no_stable_uid` advisory (severity info), so renames/moves that would orphan text references are visible before they bite. Verified against the real engine: a missing-UID child still loads and instantiates (worst case an engine warning + path fallback), so this stays an advisory, not an error.
- **`ping`/`editor_context` report live game state** (`is_playing_scene()`-backed) instead of a flag that could go stale on editor debug-session reuse, and both now include the editor `pid`.
- **`scene_tree`/`scene_map` docstrings state what they actually show** (the editor's edited scene / static `.tscn` files on disk — not the running game), pointing to `state_inspect`/`ui_map`/`exec(context=game)` for runtime inspection.

### Added

- **`wait_for_import` bridge command** (also exposed as `editor_context(wait_for_import=true, wait_timeout_ms=...)`): an explicit, opt-in wait until the editor's filesystem scan/import queue is idle, for agents that need the editor state settled before reading context. Includes grace frames so a scan triggered immediately before the wait is reliably observed (validated 20/20 on a live editor; without them the wait raced the deferred scan start 18/20). All bridge operations remain fire-and-forget by default — nothing new blocks.
- **Repeatable Wave-2 bridge smoke script** (`scripts/smoke_bridge_wave2.py`) driving the live editor+game stack through the public Python tools: not-attached contract path, then attach → screenshot → state_inspect → stop.

### Tests

- Test-first throughout: every fix above landed with regression tests (Python unit/integration plus headless GDScript contract tests for the addon-side behavior), including adversarial-review fixes for the fixes themselves. Full suite green at tag time; counts vary by environment (Godot-dependent contract tests skip without a local editor binary).

## [0.5.7] - 2026-06-04

### Fixed

- **`godotiq install-addon` no longer crashes on Windows with a `UnicodeDecodeError`.** The CLI read and wrote text files — the bundled `GODOTIQ_RULES.md` rules source and the per-assistant convention files (`CLAUDE.md`, `AGENTS.md`, `.cursorrules`, `.windsurfrules`, `.github/copilot-instructions.md`) — using the platform default encoding. On Windows that is the ANSI code page (cp1252), which cannot decode the UTF-8 rules file (it aborts on byte `0x9d`), so the addon install crashed before copying anything. Every text read/write in `cli.py` now passes `encoding="utf-8"` explicitly. Reported by a Windows user on Reddit.
- Hardened the rest of the shipped text I/O against the same locale-default failure mode: the `.godotiq.json` loader (`config.py`) and the release-artifact writer (`scripts/build_bundle.py`) now read/write as UTF-8 explicitly.

### Docs

- **Windows-safe MCP setup.** The README setup snippets used Unix-only shell idioms (`export VAR=…`, `VAR=value uvx …`). Added PowerShell equivalents and made explicit that the `.mcp.json` config is cross-platform: `command` is always `uvx` with the key in the JSON `env` block, so Windows users never need the Unix-only `env` command shim (which has no `cmd`/PowerShell equivalent). Reported alongside the install crash.

### Tests

- Added regression tests pinning UTF-8 file I/O in the addon installer (`test_cli.py`) and the config loader (`test_config.py`), plus a scaffolding guard (`test_scaffolding_int.py`) that fails if the MCP launch examples ever reintroduce a non-Windows-safe `env`-command shim.

## [0.5.6] - 2026-05-30

### Fixed

- **Pro `godotiq_placement` no longer crashes with `'WorldNode' object has no attribute 'name'`.** The bundle's placement wrapper read non-existent `WorldNode` attributes (`name`/`type`/`world_pos`/`groups`/`path`); it now reads the real contract (`node.name`/`node.type`/`world_position`/`node.groups`/`full_path`). The tool failed on every resolved scene since the Pro internals were extracted into the bundle.
- **Pro `godotiq_suggest_scale` no longer fails with `cannot import name '_find_focus_node'`.** The bundle imported the helper from the gutted public stub module; it now imports it from the Pro package. The tool failed on every call.
- Hardened two latent imports of the same shape (`_read_main_scene` in the Pro `explore` and placement-resolution paths) to import from the Pro package rather than the public stub, preventing an identical future breakage. No behavior change (the implementations are identical).
- **Pro `godotiq_placement` no longer suggests occupied Marker3D slots as empty.** The placement wrapper dropped `children_count` when flattening world nodes, so `compute_placement` (which skips markers with `children_count > 0`) treated every marker as empty (default `-1`). The wrapper now passes `children_count`, so designer slots that already contain an object are correctly excluded.

### Tests

- Added a real-implementation integration suite for the Pro spatial tools (no mocks) plus static guards that reject gutted-stub imports and bogus `WorldNode` attribute access, so these regressions are caught before a bundle is built.
- Added a public `WorldNode`/`TscnNode` attribute contract test (cross-boundary lock for the Pro bundle).
- Parametrized `tests/test_pro_bundle_real.py` off the hardcoded `0.4.0` bundle and made it fail (not skip) in CI when the delivered bundle is missing.
- Release pipeline now runs two gates: Pro-source tests before building the bundle, and a real-bundle verification after the sha256 pin and before the wheel build.

## [0.5.5] - 2026-05-18

### Fixed

- `godotiq auth reset --yes` now preserves the local `install_id` by default so support retries reuse the same Polar activation seat. Use `--new-install-id` only when intentionally rotating the device identity.
- Fresh activation failures now distinguish an unknown signing `kid` from a true `signature_mismatch`, making Worker key-rotation mistakes visible in `auth status --json`.
- Deterministic activation failures are cached for the current process so `auth status` does not call `/api/activate` twice and create duplicate seats when a receipt cannot be persisted.
- Worker `/api/activate` now reuses an existing Polar activation whose label matches the incoming `install_id` instead of creating another activation for the same machine.

### Added

- `auth status --json` includes a redacted `license_key_fingerprint` when `GODOTIQ_LICENSE_KEY` is configured, giving support enough information to spot stale or wrong MCP environment values without exposing the full key.

## [0.5.4] - 2026-05-03

### Added

- New `godotiq_read_debug_console` Community tool reads recent Godot Debugger/console errors as structured text, including runtime errors captured from the running game and script errors captured by the editor logger when available.
- New `godotiq_verify_project_runs` Community tool performs conservative Play-mode verification and returns `PASS`, `FAIL`, or `INCONCLUSIVE` after script preflight, launch, settle, and debug-console inspection.

### Changed

- Agent guidance now treats screenshots as expensive visual-only evidence. Prompts steer agents toward `state_inspect`, `read_debug_console`, `check_errors`, `verify_motion`, and `verify_project_runs` before screenshot/explore calls.
- Tool count updated to 38 total: 24 Community + 14 Pro.

### Documentation

- Added site update notes for the feedback-loop release, including changelog bullets, tool-count copy, positioning guidance, and post-release checks.
- Updated website content spec and public-facing README copy for the two new Community tools.

### Tests

- Added coverage for debug-console wrapper registration, Play verification verdicts, launch `success=false` handling, addon debug-console formatting, prompt guidance, tool counts, and mirror/version metadata.

## [0.5.3] - 2026-05-03

### Fixed

- License activation diagnostics now distinguish `network_unreachable`, `worker_5xx`, `invalid_license`, `signature_mismatch`, and `unexpected_response` instead of collapsing unrelated failures into `migration_required`. Existing `limit_reached` and `key_revoked` outcomes remain explicit.
- Receipt refresh now recovers automatically when the Worker returns `410` with no active seats by falling back to a fresh activation for the existing install ID.
- `godotiq auth status` human output no longer shows maintainer-only `dev_key: not set` noise, and only prints bundle error details when a real bundle error exists.

### Added

- New `godotiq auth reset --yes` command clears local license state without touching the Pro bundle cache, giving paying users a safe self-service recovery path.
- `godotiq auth status --json` now includes `godotiq_version` and `python_version` so support can diagnose customer environments without an extra round trip.

### Documentation

- Setup docs now call out the `uvx` environment boundary explicitly: Pro users must put `GODOTIQ_LICENSE_KEY` in the MCP server `env` block because shell exports may not reach the MCP-launched `uvx` process.
- MCP examples now use unmistakable placeholders such as `<REPLACE_WITH_YOUR_GODOT_PROJECT_PATH>` and explain how to omit the license key for Community tier.

### Agent Guidance

- Screenshot usage has been demoted to an expensive visual-only fallback. Prompt guidance now steers agents toward structured text tools first and requires verification evidence appropriate to the change instead of defaulting to screenshots.

### Tests

- Added regression coverage for license failure classification, activation fallback, `auth reset`, prompt screenshot demotion, and receipt status documentation sync.

## [0.5.2] - 2026-04-30

### Fixed

- `godotiq auth status` now invokes `ensure_pro_bundle()` before reading `pro_status()`. Under 0.5.0/0.5.1 the standalone CLI never booted the Pro bundle (only the MCP server did, in `server.py:_lifespan`), so `auth status` reported `bundle: community` / `reason: bundle_unavailable` for every paying user even when the bundle would have loaded fine inside the running MCP server. The `godotiq_ping` MCP tool was unaffected (the server-side bundle warmup ran before `license_diagnostic()` was called there). Operators using `auth status` to diagnose Pro entitlement now see the same bundle state the server would load. The exception path is defensively swallowed so the diagnostic always emits.

### Added

- `bundle_error_detail` field surfaced via `pro_loader.bundle_error_detail()` and included in `license_diagnostic()` (and therefore `godotiq auth status --json` and `godotiq_ping`). Carries a stable enum-keyed leaf for the precise reason a bundle load attempt failed: `download_http_<code>` (e.g. `download_http_401` for an expired/rejected receipt, `download_http_404` for no compatible bundle, `download_http_429` for rate-limit), `download_network` (connect/timeout), `hash_mismatch` (release misalignment between PyPI wheel and R2 bundle, or a hostile/corrupted response), `receipt_missing`, `content_length_invalid`, `content_length_mismatch`, `bundle_too_large`, `persist_failed`, `extract_failed`, `cached_bundle_unverified`, `download_unexpected`. Field is omitted from the diagnostic dict when the loader has not run or completed successfully — operators no longer need log access to distinguish a worker-side rejection from a release misalignment when triaging support tickets.

### Tests

- Test isolation hardening: 6 stub-test files (`test_stub_assets.py`, `test_stub_flow.py`, `test_stub_memory.py`, `test_stub_code.py`, `test_stub_spatial.py`, `test_stub_animation.py`) plus `test_stub_bridge_explore.py`, `test_community_tier.py`, `test_server.py::TestPingTool`, and `test_scaffolding_int.py::TestMcpServerPingToolRegistered` now declare `tmp_user_data_dir` and reset license/loader state in their fixtures. CI was unaffected by the prior gap (no residual receipt) but on developer machines a stale `within_grace` receipt under the real platformdirs `user_data` dir was flipping `is_pro()` to True and routing 73 community-mode assertions through the `license_error` branch — a flake source whose root cause was test-environment, not product, behavior.

## [0.5.1] - 2026-04-18

### Security

- Worker `/api/activate` no longer synthesizes a local `activation_id` when Polar returns 404 for an unknown key. The Worker now fails closed with `401 INVALID_LICENSE`, preventing signed Pro receipts from being issued to any string matching `LICENSE_KEY_RE`. No forgery was ever observed in production (see forensic review of 7-day Polar subrequest breakdown: 0 × 404 responses), but the latent hole is now sealed.

### Fixed

- Client reads `body["error_code"]` (the Worker's canonical field) instead of `body["error"]` (the human message) when classifying activation failures. Under 0.5.0, `403 LIMIT_REACHED` and `401 KEY_REVOKED` from the Worker both collapsed into `migration_required`, leaving paying customers at their activation seat limit with an unhelpful hint pointing at `GODOTIQ_LICENSE_KEY` instead of `godotiq.com/manage`. After this fix, `license_diagnostic()` and `godotiq_ping` surface the actual reason (`limit_reached`, `key_revoked`, ...) with the correct actionable message.

## [0.5.0] - 2026-04-15

### Security

- Rotated the leaked dev key; old hash and plaintext scrubbed from the tree (section 01).
- Signed Ed25519 receipts replace the unsigned `license_cache.json` (sections 07, 08).
- Worker-only Polar validation via `/api/activate` and `/api/receipt`; client no longer talks to Polar directly (sections 05, 06).
- Bundle re-verification against pinned SHA-256 + companion manifest on every load; extraction runs in per-process throwaway tempdirs with an `atexit` cleanup (section 09).
- Env fencing: prod builds ignore `GODOTIQ_POLAR_SANDBOX`, `GODOTIQ_POLAR_ORG_ID`, `GODOTIQ_BUNDLE_URL`, `GODOTIQ_ACTIVATE_URL`, `GODOTIQ_RECEIPT_URL` (section 04).
- Download-time defense: streaming read with a 50 MB size cap, Content-Length validation, and sha256 matched against the pinned allowlist before any archive is persisted (section 09).

### Infrastructure

- Single source of truth for version: `pyproject.toml` → `scripts/sync_version.py` propagates to `plugin.cfg`, `godotiq_server.gd`, `server.json`, and the `tests/test_version.py` fixture (section 11).
- URL unification: every canonical URL comes from `godotiq.urls`; an AST-enforced test keeps it honest (section 03).
- First CI (`ci.yml`) and release (`release.yml`) GitHub Actions workflows; PyPI publishing via Trusted Publishing (OIDC). Operator runbooks for signing-key rotation, mirror leak response, and PyPI OIDC fallback (section 13).
- Public mirror sync automation (`scripts/sync_public_mirror.py`) with allowlist-driven copy, README templating, and a leak-guard that blocks dev keys, Polar URLs, private repo names, and unpinned sha256 digests (section 12).
- `godotiq_ping` exposes `receipt` / `bundle` / `tool_count` fields so operators can diagnose license and bundle state without reading logs (section 10).

### Runtime deps

- Added `cryptography >= 42.0` (required by the new receipt verifier in `src/godotiq/receipt.py`).

### Breaking / Downgrade

> 0.5.0 is a one-way upgrade. The unsigned `license_cache.json` is renamed to `license_cache.json.legacy` on first successful activation. Downgrading to 0.4.x requires re-running with `GODOTIQ_LICENSE_KEY` set so 0.4.x repopulates the legacy cache file — the `.legacy` suffix is not read by 0.4.x.

## 0.4.1

- Fix: addon version sync — `plugin.cfg` and `ADDON_VERSION` now stay in sync with PyPI release
- Fix: `godotiq_ping` reports `pro_bundle` status alongside license tier; warns when license is Pro but bundle is not active

## 0.4.0

- Pro bundle distribution via Cloudflare Worker + R2
- 22 Community + 14 Pro dual-tier tool model
- Polar.sh license validation with disk cache and offline fallback
- Pro tool stubs with rich community previews
