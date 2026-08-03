# Changelog

## [0.5.16] - 2026-08-03

Emergency compatibility release. `mcp` 2.0.0 (released 2026-07-28) removed the `mcp.server.fastmcp` module, and godotiq's dependency was uncapped (`mcp>=1.12.4`): every FRESH install of godotiq ≤0.5.15 now resolves mcp 2.0.0 and the server dies at startup with `ModuleNotFoundError: No module named 'mcp.server.fastmcp'` — while `godotiq --version` keeps working (it never imports the server), so the failure masquerades as a client connection problem. Reported by a customer (uvx on a new device, Windows 11, Claude Desktop, 2026-08-03) and reproduced end-to-end in a clean venv. Workaround on older versions until you upgrade: `uvx --with "mcp>=1.12.4,<2" godotiq`.

### Fixed

- **`mcp` dependency capped: `>=1.12.4,<2`.** mcp 2.0 renamed FastMCP to `MCPServer` and removed the old import path outright (not deprecated); upstream's own migration guide tells dependents to keep a `<2` upper bound until they have migrated, and 1.x stays in maintenance mode with security fixes. The 1.12.4 floor is unchanged. Verified: with the cap, a clean install resolves mcp 1.29.0 and every godotiq import path works. Migration to mcp 2.x is tracked as future work — upstream declares decorators, result wrapping, `Image`, `lifespan=` and `ctx.request_context.lifespan_context` unchanged, so the real work is nine import renames, the in-memory test helpers and camelCase→snake_case protocol fields (plus revalidating the private `_tool_manager` access, which still exists in 2.0 but remains private API).
- **The startup crash now diagnoses itself.** If `mcp.server.fastmcp` cannot be imported anyway (`--no-deps` installs, hand-altered environments, module shadowing — a normal resolver can no longer get there past the cap), the server prints a `[godotiq] FATAL` line to stderr naming the installed mcp version and the exact fix command, ahead of the traceback.

### Internal

- New guard test `tests/test_dependency_constraints.py` pins the declared constraint: the `mcp` requirement must exclude 2.x and keep admitting the 1.12.4 floor — removing either bound turns the suite red.
- `AGENTS.md`/`CLAUDE.md` dependency docs were stale (`mcp>=1.0.0`, predating 0.5.14's floor raise) — aligned to the real constraint, website content spec rows included.

## [0.5.15] - 2026-07-04

First release driven by a measured behavioral baseline instead of impressions: every item traces to a finding from the ShipBench v0 runs (0.5.13 = 6/9, 0.5.14 = 8/9 tasks passed; 9+9 real agent runs against a live editor). Two independent code reviews of this delta each caught one real defect before the tag — both fixed and regression-tested.

**After upgrading, re-install the addon in your projects** (`pip install -U godotiq`, then `godotiq install-addon <project>` and restart the Godot editor): the add_child fix and the new node_ops operations live in the addon.

### Fixed

- **`add_child` inline `properties` are applied for real and verified per-property (P0).** `node_ops add_child` with `properties: {...}` answered `status: ok, verified: true` while silently discarding every property — the node landed on disk bare (reproduced deterministically on 0.5.13 AND 0.5.14; caused 2 of the 3 baseline T-UI failures and the T-3D "0 geometries" scene). Properties are now validated and converted BEFORE any undo/redo registration — a property that cannot apply fails that op with no node added (`PROPERTY_NOT_FOUND`/`PROPERTY_IS_NULL` teaching errors, parity with `set_property`; `properties["name"]` teaches the top-level `name` field) — and read back one by one after commit: `actual_properties` reports what stuck, a mismatch (e.g. a clamping setter like `ProgressBar.value`) downgrades the op to `unverified` with `unverified_properties`, while the node's presence still counts in `scene_modified`. 5 editor-headless contract tests, red on 0.5.14's addon.
- **The `bundle_unavailable` hint points at the actual cause when the license key is missing.** State machine: Pro receipt within grace + NO key configured → bundle download → HTTP 401 → the hint said "Re-run with network access", sending operators to check the network when the problem was the missing key. Keyed on `bundle_error_detail: download_http_401` + `license_key_configured: false`, the hint now says the receipt is still valid but no key is configured: set `GODOTIQ_LICENSE_KEY` in the MCP client's env block and restart the client. With a key configured the 401 keeps the generic hint (a worker-side rejection is a different failure).

### Added

- **`node_ops` op `set_project_setting`** — whitelisted ProjectSettings writes with synchronous save and read-back. `application/run/main_scene` first among them (the measured need: baseline agents hand-rolled ProjectSettings GDScript through `exec` to set it), plus `application/config/name` and window size/stretch. `main_scene` must point at an existing `res://*.tscn` (`SCENE_NOT_FOUND` teaches saving first); non-whitelisted settings error with the allowed list and the `exec` alternative; results carry `verified` and `undoable: false` (project.godot is not part of the scene undo history).
- **`node_ops` op `assign_resource`** — fills typed resource slots (shape/mesh/texture/script) from a built-in type (`{"type": "RectangleShape2D", "properties": {"size": [32, 32]}}` — each inline resource property is read back, never accepted silently) or a `res://` path. Teaching pre-flight errors: `RESOURCE_TYPE_MISMATCH` (the property declares the Resource class it takes), `RESOURCE_NOT_FOUND`, `RESOURCE_PROPERTY_NOT_FOUND`/`RESOURCE_PROPERTY_REJECTED`, and `RESOURCE_PROPERTIES_INVALID` — malformed `properties` payloads and the path+properties combination are refused loud (applying properties to a loaded `res://` resource would mutate every scene sharing that file; caught by independent review before tag). Property-op semantics under the instance-internal guard (editable-children overrides allowed). The `PROPERTY_IS_NULL` errors from `set_property` and `add_child` now teach this op instead of the `godotiq_exec` workaround.
- **`godotiq_validate` warns on incomplete scene nodes (Pro).** New `incomplete_node` rule: Sprite2D/Sprite3D/TextureRect without `texture`, CollisionShape2D/CollisionShape3D without `shape`, MeshInstance3D without `mesh` — nodes that render or collide as nothing (the baseline failure mode where an agent shipped a sprite without ever attempting a texture). Instanced nodes and overrides are skipped (their properties may live in the source scene). `validate` now also accepts a `.tscn` target (previously "not a .gd script") and reports `total_scenes_checked`; the warning teaches `assign_resource`. Disableable like every rule via `conventions.disabled_rules`.

### Internal

- **ShipBench is now release gate §4.8**: every release runs the 3-task × 3-run behavioral benchmark against the published wheel and compares with the previous release. A regression opens an investigation of the failing runs, not an automatic rollback (n=3 is noisy by design). The bench runner gained `--resume-summary` to continue interrupted runs without re-paying completed ones.

## [0.5.14] - 2026-07-03

R0 "Perception and contract" — the highest-leverage fixes from the July 2026 full-product audit: the model now actually SEES screenshots (MCP ImageContent instead of base64-in-JSON), the behavioral contract always reaches the model (MCP server instructions), the most frequent dead-end errors teach the next step, and existing-but-invisible capabilities are documented. Everything is additive or opt-out; no Pro bundle change (zero-delta).

**After upgrading, re-install the addon in your projects** (`pip install -U godotiq`, then `godotiq install-addon <project>` and restart the Godot editor): the teaching errors live in the addon.

### Added

- **Screenshots are delivered as real MCP image blocks the model can see.** `godotiq_screenshot` and `godotiq_explore` grow a `delivery` parameter: `"image"` (the new default) returns `[metadata JSON, image block, ...]` — the model receives pixels, not a base64 text blob, so visual verification is real instead of hallucinated. `"legacy"` returns the exact pre-0.5.14 dict (base64 inside `result["image"]` / `screenshots[]`) for clients that cannot render MCP images; the env var `GODOTIQ_IMAGE_DELIVERY` sets the global default and an explicit argument wins. For explore, the i-th image block pairs with `screenshots[i]` in the metadata. Invalid modes or corrupt image data never fail the call — they degrade to the legacy dict with a `delivery_warning`. MIME types are normalized (`jpg`→`image/jpeg`; the SDK helper alone would emit the nonexistent `image/jpg`).
- **The CORE behavioral contract ships as MCP server `instructions`.** Hosts inject server instructions into the system context at session start, so the contract now arrives even when convention files (CLAUDE.md, .cursorrules, ...) are truncated or skipped. Extraction is shared with `install-addon` (new `godotiq.rules` module — one source of truth) and the loader is fail-safe: a broken rules source degrades to no instructions, never a startup failure.
- **Errors that teach (addon).** All 12 node-lookup failure sites in `node_ops` now return `code: "NODE_NOT_FOUND"`, a `did_you_mean` list (up to 5 near-match paths, bigram-similarity ranked — catches `Playr`→`Player` typos) and a hint pointing at `scene_tree(detail='brief')`. `set_property` finally distinguishes its two failure modes: a property that EXISTS but is null (e.g. a fresh `CollisionShape2D.shape`) reports the honest `PROPERTY_IS_NULL` with `property_class`/`property_type` and the working `godotiq_exec` workaround, instead of the misleading "Property not found"; a truly missing property reports `PROPERTY_NOT_FOUND` with `valid_properties` (first 15 editor-visible names, most-derived class first) and `did_you_mean` on near matches. `rotate`/`scale` on non-Node3D keep their error and gain the true 2D workaround hint (`set_property("rotation_degrees", ...)` / `set_property("scale", [x, y])`). Covered by new editor-headless contract tests on a real Godot 4.6.
- **`godotiq_ping` reports `rules_freshness`** — the GODOTIQ_RULES.md staleness state (ok/outdated/missing/... with versions and the install-addon hint) that previously lived only in stderr logs, so the model can self-diagnose stale rules.
- **Hidden capabilities documented** (pinned by a new docs-contract test): `node_ops` `set_anchors` (16 Control presets), `build_scene` `grid.axis` (`"xz"` default 3D ground plane, `"xy"` for 2D), `input` `click_at`/`click_at_world` (3D-only)/`mouse_motion`, `camera` vs `explore` distinction, when to prefer `watch` over repeated `state_inspect`, `perf_snapshot` reading thresholds, `run` scene-resolution modes and the `main_scene_empty` signal.

### Changed

- **`detail` defaults to `"brief"` on the 4 costliest-output tools**: `asset_registry`, `scene_map`, `scene_tree`, `validate`. Their full payloads can emit 50k–140k chars; if you relied on the extended output, pass `detail="normal"` (or `"full"`) explicitly. All other tools keep `"normal"`.
- **`mcp` dependency floor raised from `>=1.0.0` to `>=1.12.4`** — mixed-content tool returns on the public call path and FastMCP `instructions` require it (probe matrix: 1.2.0 lacks instructions, 1.6.0 is the functional minimum, 1.12.4 is the prudent floor). The floor is pinned by an in-process client-session test.
- **The 3D-only spatial stack now says so**: `scene_map`, `spatial_audit`, `placement`, `suggest_scale`, `explore`, `nav_query`, `camera` and `screenshot(viewport="editor")` docstrings carry an explicit "3D-only: on 2D scenes returns incomplete or misleading data" disclaimer, and the `node_ops` advice "ALWAYS validate:true" is now scoped to 3D (spatial validation returns BLOCKED on 2D scenes). Runtime 2D guardrails remain a separate plan.
- `godotiq_screenshot` and `godotiq_explore` no longer emit `structuredContent` (their return annotation had to drop `-> dict` to support mixed content; the TextContent JSON payload is unchanged in legacy mode).
- README: activating a Pro key now spells out the mandatory full MCP-client restart per client, with the `godotiq_ping` verification step.

## [0.5.13] - 2026-06-13

Hotfix for Pro entitlement activation receipts rejected as `not_yet_valid` on otherwise-correct customer machines.

### Fixed

- **Fresh Pro receipts now tolerate normal client/Worker clock skew.** The Worker now backdates receipt `nbf` by 30 seconds when issuing activation and refresh receipts, and the client verifies freshly received signed receipts with a matching bounded skew allowance. This fixes the race where the Worker emitted `nbf == iat` and the Python client checked `int(time.time())` strictly, causing valid receipts to be rejected before they could be cached.
- **Activation retry behavior is safer around this receipt race.** A receipt whose `iat` is only slightly ahead of the local whole-second clock is accepted and persisted, while genuinely future receipts remain rejected as `not_yet_valid`.

## [0.5.12] - 2026-06-12

Third round of the externally driven feedback loop: a full 38-tool sweep on a fresh Godot 4 project confirmed the 0.5.10/0.5.11 fixes and surfaced what remained — every claim reproduced against the code before fixing. The theme: read what today's Godot actually writes, and never promise what a tool does not do.

### Fixed

- **`animation_info` and `animation_audit` read Godot 4.4+ `libraries/` property-path serialization.** Godot 4.4 changed how AnimationPlayer serializes its libraries: from the dict form `libraries = {"": ExtResource(...)}` to per-property paths `libraries/ = ExtResource(...)` / `libraries/<name> = ...`. The extraction only handled the dict form, so on any scene saved by a current editor the 0.5.11 external-library fix never engaged — 0 animations reported plus a bogus `empty_player` warning (the re-reported customer symptom; the exact reproduction pair now lives in the test suite). Both forms are handled in both tools, for ExtResource and inline SubResource libraries, named or default. On a (hand-written) cross-form name clash the newer serialization wins deterministically, and the `&""` StringName spelling of the default library name in dict form is stripped correctly now too.
- **The `.tscn` parser merges `metadata/_groups` into `node.groups`.** Nodes grouped through metadata — a common pattern for tool-driven workflows that cannot write the header `groups=[...]` attribute — were invisible to every group consumer: `placement` could not find such markers and `spatial_audit`'s `empty_markers` check never fired on them. Plain lists, `PackedStringArray(...)` and `&"StringName"` items are normalized and deduplicated against header groups; `node.metadata["_groups"]` is preserved untouched. Empty containers (`PackedStringArray()`, `[]`) can never produce a phantom group name, and non-string items are skipped rather than stringified.

### Docs

- **`validate` no longer claims compilation checking.** The injected rules said "validate (Pro: conventions + compilation)"; the implementation is conventions-only by design (six rules, severity warning/info — it cannot emit errors). The rules, the degraded-mode example (which showed an impossible "2 errors" teaser), the README ("auto-fixes" — validate is read-only) and the Community teaser text now describe exactly what validate does, and route compilation evidence to `check_errors` for both tiers — externally verified to match the editor LSP line-for-line. Bridge tools listed under "no addon needed" are now marked as requiring the addon.

### Internal

- Public/Pro animation helper parity is enforced by a test (the two copies drifted once before; bundle-side, gated to lockstep versions), and the Pro metadata-groups tests skip on hosts older than 0.5.12 instead of failing the advisory CI.

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
