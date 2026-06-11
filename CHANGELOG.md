# Changelog

## [0.5.11] - 2026-06-12

Driven by the second round of externally reported tool limitations, every claim re-verified against the code before fixing (docs/plans/customer-feedback-fixes-2026-06-11.md). The theme: analysis tools must neither invent issues nor stay silent about what they could not see.

### Fixed

- **`animation_info` and `animation_audit` finally see AnimationLibrary `.tres` files loaded via ExtResource.** The extraction chain only resolved inline `sub_resource` libraries, so a scene whose AnimationPlayer loads its library from a `.tres` file reported 0 animations — no orphan or broken-track detection, plus a bogus `empty_player` warning (the externally reported "0 animations" symptom; inline libraries were always fine). Both tools now follow `ext_resource` refs: animations defined inside the `.tres` carry full details (`source: "tres_library"`, additive `file` key), and animations the library itself references as external `.res`/`.tres` files surface by name (`source: "external"`) without requiring those files to exist or be parsable.
- **`animation_audit` no longer flags `autoplay`/`current_animation` animations as orphans** (Pro). The orphan check only collected `play()`/`travel()`/ANIM_MAP/AnimationTree references and never read the AnimationPlayer's own properties — an animation the engine plays by itself was reported as "never referenced".
- **`placement` honors `constraints.marker_group` — previously documented but never read.** An explicit marker group (string or list) now overrides the `object_type` inference; with no `near`/`near_position` at all, marker-first mode uses the group's free markers as the candidates instead of failing with the baffling `Reference 'None' not found in scene`. With no reference parameters whatsoever the error now says exactly what to provide; the `near` not-found message is byte-identical to before (Pro).

### Added

- **Real `.tres` resource parser** (`godotiq.parsers.tres_parser.parse_tres`), replacing the Sprint-0 `NotImplementedError` placeholder. Same text dialect as `.tscn`, so it reuses the existing parsing infrastructure and adds the `[resource]` section — this is what unlocks the external-AnimationLibrary fixes above.
- **`build_scene` grid auto-spacing is never silent anymore.** Every response for a grid without explicit `spacing` carries an additive `auto_spacing` key: `{"applied": true, value, source}` when tile_size/GLB bounds resolved it, `{"applied": false, reason}` with a specific reason otherwise (non-GLB scene, invalid `tile_size`, unreadable bounds, no session, zero size). The addon-side 1.0 fallback is unchanged — callers can now see why it kicked in. There is, and never was, a minimum tile count: 1x2 and 2x2 grids auto-space exactly like 3x3, now locked by tests against a real GLB.
- **`spatial_audit` detects real geometric overlap and declares its own coverage** (Pro). The overlap check previously compared instance-root positions at < 0.01m only, so two primitive boxes interpenetrating by a full meter reported "0 issues". Approximate world AABBs are now derived where data exists (primitive mesh sub_resources, world-scaled; GLB instance bounds) and interpenetration beyond a conservative threshold (20% of the smaller object's smallest dimension — adjacency never flags) is reported as severity `info` under the same `overlapping` check. Ancestor-descendant pairs are excluded. A new additive `coverage` block declares what each geometric check evaluated vs skipped (`evaluated`, `skipped_no_bounds`, active floating threshold) — treat 0 issues with low coverage as "not verified", not "verified clean". New optional `floating_threshold` parameter (default 100.0, unchanged) lets ground-level scenes lower the floating-objects bar; older Pro bundles safely receive the legacy call.

## [0.5.10] - 2026-06-11

Hotfix for the externally reported node_ops false-success family, reproduced live on 0.5.9 + Godot 4.6 (docs/plans/nodeops-false-success-2026-06-11.md). The theme: a mutation tool may never answer "ok, scene modified" unless the live editor tree actually shows the change.

### Fixed

- **node_ops can no longer be poisoned into permanent silent no-ops.** `_handle_node_ops` opened an UndoRedo action unconditionally but only committed it when a mutation succeeded — so one batch with every op failed (a typo'd node name) or a batch of only `get_property` reads left an orphaned open action that swallowed EVERY later node_ops batch, editor-wide, until restart: each one answered `ok` + `scene_modified: true` while changing nothing, live or on disk. The action is now created lazily on the first real do/undo registration and committed unconditionally once created, so no request can leave the manager open (and read-only batches no longer leave empty Ctrl+Z entries). Crash paths that could abandon a mid-built action are hardened too: `instantiate()` null-check in `add_child`, numeric validation of `position`/`rotation`/`scale`/`anchors`/sub-path values before any `float()` cast.
- **Every mutating operation is read back against the live tree after commit.** Previously only move/rotate/scale/set_property had a read-back, its `verified: false` did not change the op status, and `scene_modified` ignored it. Now rename (reports `actual_name` + `name_collision` when Godot deduplicates the requested name), delete (node really left the tree), add_child/duplicate (node present under the right parent, collision-aware), reparent (actual parent), and set_anchors (anchors re-read) are verified too. A failed read-back downgrades the op to the new additive status `"unverified"`, the response carries top-level `all_verified`, and `scene_modified`/`undo_available` are computed from observed effects only — "ok"/"error" semantics are unchanged on healthy paths.
- **Mutations on nodes inside instanced child scenes are guarded.** Edits to instance-internal nodes (owner != scene root) applied live, reported `verified: true`, saved "successfully" — and silently reverted on reload because the .tscn never serializes them. Mutating ops on such nodes now fail with `INSTANCE_INTERNAL_NODE` and a concrete hint. With Editable Children enabled, property ops (move/rotate/scale/set_property/set_anchors) and add_child/duplicate pass — those serialize as overrides — while delete/rename/reparent stay blocked (not serializable; the editor UI forbids them too).
- **save_scene tells the truth.** `EditorInterface.save_scene()`'s return value was ignored — and it returns OK even when ResourceSaver fails (verified live on a read-only directory), so write failures reported `saved: true`. The handler now captures the return code, confirms the file exists, and disambiguates the silent-failure case with a write probe when the file timestamp did not move: failures answer `saved: false` + `error_code` + an explicit "NOT written to disk" message (also recorded in `recent_errors`). The response carries an informational `file_mtime_changed`, and a new optional `expected_scene` parameter refuses with `SCENE_MISMATCH` when a different tab is active — closing the wrong-scene-persisted and changes-stranded-in-inactive-tab paths on the save side.
- **The Python wrapper forwards `scene` to the editor and surfaces unverified results.** The MCP tool accepted a `scene` argument but never sent it to the bridge, leaving the addon's preflight guard vacuous — batches landed on whatever tab was active. `godotiq_node_ops` now normalizes and forwards it (key omitted when absent; older addons ignore it), `godotiq_save_scene` gained `expected_scene`, a top-level `warning` is added whenever `all_verified` is false, and output truncation can never drop error/unverified entries from large batches anymore (they are preserved with their original `index`).

### Added

- **Editor-headless contract test suite for node_ops/save_scene** (`tests/test_node_ops_editor_contracts.py`): drives a real `--headless --editor` Godot over the websocket bridge — no mocks — encoding the live repro sequences as regressions: both poison triggers, instance-internal loss, rename collision, read-only save failure, `expected_scene` mismatch, and a happy path verified down to the parsed .tscn on disk. Runs in ~8s for 3 editor boots, skips cleanly without `GODOT_BIN`; a dedicated CI job downloads Godot 4.6 headless so GDScript contracts are now exercised on every push (previously CI ran zero GDScript lines).

## [0.5.9] - 2026-06-11

Driven by the verified Phase-5 dogfooding findings: the checker can no longer crash on (or blame itself for) user code, project-wide analysis really covers the whole project and says what it saw, the parser reads Godot 4.6's native node identity, and the injected rules fit every AI client's context budget.

### Fixed

- **Project/graph-scoped tools now see externally added files — and say what they covered.** `refresh_if_stale()` (0.5.8) only covered files known at session load, so a `.gd` created afterwards by another tool was invisible to `validate`, `signal_map`, `dependency_graph`, `impact_check` and `trace_flow` — a project "green" could silently skip new scripts (measured 17-of-20 coverage on a real run). Sessions now reconcile project scope before every dispatch (one bounded directory walk discovers adds/deletes — ~10 ms steady-state on a 500-script project, no reparse of fresh files), and every payload from these five tools carries coverage telemetry: `files_checked`, `project_files_discovered`, and `files_skipped` with reasons (`parse_failed`, `excluded_addon_dir`) — so a partial scan can never read as full coverage again.
- **The `.tscn` parser reads Godot 4.6's native `unique_id` node attribute.** Godot 4.6 stamps a stable per-node `unique_id` into every node header on editor saves; the parser populated `TscnNode.unique_id` from `unique_name_in_owner` — a body property that never appears in headers — so the field was silently always `None` on 4.6 files. The real header attribute is now parsed (the `%`-addressing `unique_name_in_owner` body property keeps flowing into node `properties`, untouched), scene resolution keeps the outer scene's id on instance nodes while grafted children keep their source scene's ids, and the parser documents that any future text-mode `.tscn` writer must round-trip header attributes like this one rather than dropping them.
- **`check_errors` no longer flags the addon itself when a project script declares its own `reload()`.** A non-static `func reload()` in any checked script (an FPS weapon, say) shadows the untyped `script_res.reload()` call — GDScript refuses the non-static call and yields null, and the old `int(null)` conversion crashed inside the addon's own check loop ("Invalid call. Nonexistent 'int' constructor.", reported against `godotiq_server.gd` itself), training users to accept a permanent 1-error project baseline. Script reloads now go through a GDScript-typed local, which binds the native `GDScript.reload()` — so shadowing scripts are genuinely compile-checked instead of skipped, and the checker can no longer crash on them. The same hardening covers `reload_script` and `run`'s pre-flight script validation, which died the same way (Nil-to-int assignment) on shadowing scripts. Reproduced headless red→green in the GDScript contract suite, byte-identical to the dogfood payload (file + line).

### Changed

- **`install-addon` injects a compact CORE rules block (~4.8k chars) into convention files instead of the full 43k document.** The monolith put every convention file over its consumer's budget — Claude Code warns at 40k, Codex silently truncates `AGENTS.md` at 32 KiB, legacy `.windsurfrules` cuts far lower — and the most operational sections (Mandatory Workflows, Error Recovery) sat physically last, first to be cut. The rules source now opens with a marked CORE tier (the ALWAYS/NEVER contract, the mandatory workflows as compressed decision trees, a compact error-recovery table — now including a `BLOCKED_EDITOR_OPEN` row — and a pointer to the full reference); `CLAUDE.md`, `AGENTS.md`, `.cursorrules`, `.windsurfrules` and `copilot-instructions.md` get only that block, while the full text keeps shipping as `GODOTIQ_RULES.md`, read on demand. Re-running `install-addon` on a project carrying the old 43k block upgrades it in place (markers); marker-less pre-existing files now get the block **prepended** (with a note) instead of appended, so it can never land beyond a truncation point. The `godotiq-rules-version` marker is now driven by `scripts/sync_version.py` (it had been hand-stamped `0.4.0` since 0.4.0 while the content kept changing), and CI enforces the new contract: core ≤ 5k chars, cardinal directives present, injected block ≤ 6k, core ≠ reference.

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
