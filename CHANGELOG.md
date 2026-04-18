# Changelog

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
