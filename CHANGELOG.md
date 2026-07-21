# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security
- **Secret scan now proactively scrubs instead of only warning (B2).** When `Scan-Secrets` finds a
  novel secret in the plaintext main set, `backup.ps1` now redacts it in the **archived copy** (the
  staging mirror — never the live source) and lets the backup proceed; the manifest hash/size for that
  file are updated in place so deep-verify stays consistent. A backup is never skipped over a detected
  secret. If an in-line scrub is impossible (write fails), that single file is **excluded** from the
  archive (logged `FAIL`, `ok=false`) so the secret cannot ship, rather than aborting the run. Files
  that cannot be scanned (oversized or binary) are now surfaced with counts instead of being silently
  treated as clean.
- **Restore no longer puts the passphrase on the command line (B4).** `restore.ps1` now lets 7-Zip
  prompt for the passphrase interactively (bare `-p`) during attended recovery, so it never appears in
  the process command line or shell history; `-Pass`/`RESTORE_SECRETS_PASS` remain for scripted
  validation as an explicit opt-in. (The unattended secrets self-test in `backup.ps1` keeps inline
  `-p` by design: no 7-Zip read mode accepts a stdin/file password and a SYSTEM task has no console,
  so this is the only way to verify the encrypted archive; the ~1s exposure is SYSTEM/admin-readable
  only, on a box that already runs the task as SYSTEM.)

## [0.1.0] - 2026-07-20

Initial public release of the scrubbed, shareable build materials for the
Clairvoyance Versioning Backup System.

### Added
- **Staff-continuity coverage assertion (F14).** After the manifest is built, `backup.ps1` verifies that Staff-member files are actually present in the archive — the definition (`profiles/*/staff.json`), conversation history (`profiles/*/agent-sessions.json`), custom personas (`neurons/personas/`), and the Home workspace's `.Clairvoyance/staff/` memory — configured via a new `protectedPaths` glob list (PowerShell `-like` matching). A miss logs a `protected-paths` **FAIL** stage and sets `ok=false` (so the monitor alarms), but **does not abort the run** — a coverage regression is loud without ever costing a night's backup. Per-workspace staff memory is reported for visibility. Documented in `config.example.json`, the runbook (§0a + Step 4), and the README.
- Initial build documentation: `docs/Build-Runbook.md` (interview-driven, trustless authoring) and `docs/Companion-Scripts.md` (annotated, byte-accurate source of the three scripts with `<TOOL_DIR>` / `<WORKSPACES_ROOT>` placeholders).
- `scripts/backup.ps1`, `scripts/restore.ps1`, `scripts/evaluate-workspaces.ps1` — the three scripts extracted verbatim from the Companion note, kept byte-identical to it.
- **Clairvoyance-assisted install path** — a README "Option A: Ask Clairvoyance to install it" copy-paste agent prompt, backed by an `AGENTS.md` agent contract (attended-only, explicit-approval gates, idempotency, trustless authoring).
- `config.example.json` — annotated example config showing the exact schema, nesting, and types with placeholder paths.
- `SECURITY.md` — private vulnerability-reporting policy.
- `.gitattributes` — normalizes line endings to LF.
- `LICENSE` — MIT.

### Changed
- Folded the **Risks & limitations** and **What it does not do** content into the README so the decision-critical information is front-and-center rather than one click away.
- Runbook agent-readability: fixed a Step 3 sequencing bug (author `evaluate-workspaces.ps1` before the scan uses it), referenced `config.example.json` from Step 4, added a fallback for agents that cannot hire Staff, and collapsed a duplicate top-level heading.
- Clarified that the "Clairvoyance Archivist" monitor is **optional** — the SYSTEM backup and `last-run.json` work without it.

### Removed
- `docs/Forum-Description.md` — its content was folded into the README (the standalone forum-post version is retained outside this repo).

[Unreleased]: https://github.com/bubomortis/clairvoyanceai-backup-system/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/bubomortis/clairvoyanceai-backup-system/releases/tag/v0.1.0
