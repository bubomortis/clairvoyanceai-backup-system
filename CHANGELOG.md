# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Install idempotency / preflight probe (`scripts/backup-preflight.ps1`).** A new **read-only** script that detects an existing install by probing **live** state — the engine scripts parse, `config.json` is valid, the DPAPI passphrase file actually unseals *on this machine*, and the "Clairvoyance Nightly Backup" SYSTEM task exists — and prints a parseable `VERDICT` (`NOT_INSTALLED` / `PARTIAL` / `COMPLETE` / `DUPLICATE`; exit codes 0–4; optional `-Json` and `-CheckUpdate`). Modeled on the Persona-Sync (`clvsync`) `status`-as-idempotency-gate pattern, so "install when the system is already in place" is handled by a deterministic probe instead of prose. Wired into `AGENTS.md` rule #4 and a new Build-Runbook **Step 1a** that branches on the verdict (COMPLETE → stop; PARTIAL → resume at the reported first-unmet invariant; DUPLICATE → stop and ask; NOT_INSTALLED → full install).
- **Destructive-step guards.** Step 7 now **hard-refuses re-sealing** an existing passphrase (re-sealing a different key permanently orphans every existing AES `_secrets.7z`); Step 9 checks for an existing SYSTEM task before registering (prevents duplicate nightly races); config/state writes are specified as merge-preserving + atomic (temp + rename) so a re-install cannot clobber `config.json` or `backup_state.json` (the GFS tier cursors).
- **`.backup-install.json` install manifest** — written atomically at go-live (Step 12) as an advisory version stamp that `backup-preflight.ps1` reads and cross-checks against live probes (a stale manifest surfaces as drift, never a false COMPLETE).
- **Separate `§Update` and `§Rotate` runbook paths.** Update refreshes only repo-sourced scripts and never re-seals or re-registers; Rotate is the sole sanctioned way to re-key the passphrase, preserving the old archives + key through their retention window.

### Changed
- **Re-synced `docs/Companion-Scripts.md` to the shipping scripts.** The companion note (the nominal "canonical, byte-identical" source) had drifted a version behind `scripts/*.ps1` — it predated both the B2 secret-scrub and B4 restore-passphrase changes already listed below. Its fenced blocks are now byte-identical to `scripts/*.ps1` again (verified), and it now includes all four scripts, adding `backup-preflight.ps1`.

### Fixed
- **Abort-window guard aborted every off-hours run (`backup.ps1`).** `abortAfterLocalTime` built the deadline as `Get-Date -Hour/-Minute`, i.e. *today* at HH:MM, then threw if the current time was already past it. For the 03:00 nightly this was fine (03:0x < 03:45), but any run started **after** the cutoff — e.g. an attended/supervised evening run at 23:31 — tripped instantly (`23:31 > today-03:45`) and aborted before the secrets stage, producing no archive. Fixed to compute the deadline as the **first occurrence of the cutoff at or after the run's start** (rolling to the next day when needed), so the nightly's ~45-minute overrun guard is byte-identical while off-hours runs proceed to their next cutoff. Added a **minimum-window floor** (`minAbortWindowMinutes`, default 20): if the computed deadline is within the floor of the start, it rolls forward instead — so a late-starting nightly (machine asleep → Task Scheduler catch-up near the cutoff) runs to completion rather than aborting mid-run and yielding no backup that night. The abort path was verified to unwind through the `finally` that clears the fleet-gating pause flag, so an abort never strands it.
- **Manifest nesting bug in `backup.ps1` (manifest-nest-fix).** `$mainMan = @(Scan-Secrets $mainMan)` re-wrapped a comma-guarded array in `@()`, nesting it into a single-element array. That collapsed `$mainMan.Count` to 1, which (a) made the Staff-continuity assertion (F14) see none of the real paths and log a **false** `protected-paths FAIL` with `ok=false` even though the files were in the archive, and (b) serialized `MANIFEST.json` as `{"value":[...],"Count":N}` instead of a bare array. Fixed by assigning the comma-guarded return directly (no `@()` wrap); the identical latent pattern at the `Get-SecretFilesLive` caller was normalized too.
- **`restore.ps1` tolerates legacy nested manifests.** Every archive produced with the bug above carries a `{"value":[...],"Count":N}` `MANIFEST.json`, so manifest-driven `-Mode Verify` / `-Mode InPlace` restore would have iterated a single null-fielded entry instead of the real files. `restore.ps1` now unwraps that shape before use (backward-compatible — bare-array manifests are untouched), keeping those archives restorable.
- **Preflight distinguishes a foreign/corrupt seal from a missing one — and recovery from rotation.** `backup-preflight.ps1` now flags a passphrase file that is present but does **not** unseal on this machine (the seal is machine-bound DPAPI — expected after an OS rebuild or a copied/transported tool dir) and, instead of the misleading generic "resume/re-seal," recommends the correct action: for **recovery / transport with the same passphrase**, delete the stale machine-bound seal and **re-seal the *same* passphrase** (safe — archives are keyed to the passphrase, not the blob, so nothing is orphaned); reserve **§Rotate** for actually *changing* the passphrase. The Step 7 guard message, the generated `RECOVERY.md`, and the runbook (Step 7 + §Rotate) now carry the same recovery-vs-rotation distinction, so a bare-metal recovery or a move to another computer is never misrouted into a re-key. (`sealForeign` is also exposed in the probe's `-Json` output.)

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
