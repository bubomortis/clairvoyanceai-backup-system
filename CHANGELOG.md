# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Superseded reasoning moved out of the scripts and into documentation.** A comment earns its place in the source if a future editor would introduce a defect without it; everything else — why a change was undertaken, what was measured, what a previous version got wrong, and who found it — is release history. `scripts/backup.ps1` had reached 48.5% comments, with the constraints that actually prevent defects buried among paragraphs of postmortem. It is now 46.0%, and the published script surface overall is 34.2% (from 35.8%). **No functional change**: verified by comparing the code-token stream with comments and newlines dropped — 10,347 / 2,094 / 1,010 tokens identical in sequence and kind for `backup.ps1`, `restore.ps1` and `backup-window.ps1`.
  - Where history was load-bearing in disguise — an *"an earlier version said X, which was FALSE"* passage existing to stop someone re-weakening a rule — the intent is preserved as a one-line prohibition and only the narrative moved.

### Added

- **`docs/Design-History.md`** — derivations whose conclusions live in the code but whose workings do not: the pause-lease TTL sizing, the scan-coverage tolerance measurements, and why the log-note share mirror could not be owned by the monitor. Two figures are recorded as **withdrawn** rather than deleted, because both were re-quoted as fact after the reasoning behind them was superseded — which is the failure that document exists to prevent.
- **Threat-model sections in `SECURITY.md`** — elevated binary resolution (why absolute paths, never `PATH`, and why hardening the tools directory is the wrong fix), and the recovery-document line-injection defence with its proof-of-concept.

### Fixed

- **The shipped test suite could not run from a clone, and had not been able to since 0.3.0.** Three of the four tests in `tests/` failed immediately for anyone who was not the maintainer — two with `Illegal characters in path`, one with `checker not found`. The cause was a hardcoded absolute path being rewritten at packaging time into an angle-bracketed placeholder (`<TOOL_DIR>\…`), and `<`/`>` are illegal in a Windows path. **The most consequential instance was not in the tests at all**: `scripts/Invoke-BackupHealthCheck.ps1` dot-sourced `backup-window.ps1` by absolute path, and unlike the parameter defaults around it, **a dot-source cannot be overridden by a caller** — so the published script was unrunnable however it was invoked, not merely under test.
  - Subjects and sibling modules are now resolved **relative to the script**, which is correct in both layouts: the subject sits alongside in an installed tool directory, and in `..\scripts` from a clone. The three test files now carry no instance-specific content at all, so their installed and published copies are byte-identical. `Invoke-BackupHealthCheck.ps1` still carries absolute paths in its **parameter defaults**, which packaging continues to rewrite — and that is fine, because a caller can override a parameter. The distinction the fix turns on is that a **dot-source cannot be overridden**, so it was the one place an unresolvable path made the script unrunnable.
  - All four suites now run from a clone: **43 assertions, 0 failures** (8 + 6 + 17 + 12), with identical results from an installed copy.
  - This was invisible from the maintainer's seat by construction — the substitution that breaks it only happens on the way *out*, so every test passed locally while the published artifact was broken. Verification that never runs from a consumer's layout is not verification.

## [0.4.0] - 2026-08-24

### Added

- **Incremental secret scan.** The nightly secret-leak scan previously read **every** file in the staging mirror. It now reads only files whose *content* changed since a recorded verdict, and re-emits the stored outcome for the rest. Measured **~1.7x–2.1x** faster in steady state over repeated runs against real mirror data. Three properties are load-bearing and are documented as editing constraints at the top of the scan in `scripts/backup.ps1`:
  - **Reuse rests on the hash cache, not on a hash of the bytes being skipped.** "Content unchanged" is decided by the size + mtime key that `Hash-Cached` already uses. Before this change a stale cached hash was inert, because the scanner read every file regardless; it is now promoted into a read/skip decision. Anything that weakens that key widens the scanner's blind spot by the same amount.
  - **`scanned` still means "holds a valid verdict under the current rule set", not "read this run".** The coverage-delta assert compares it against the ledger's history, so redefining it silently invalidates every prior night's comparison. Fresh and cached counts are reported *separately* for exactly that reason.
  - **The verdict store is separate from the hash cache, deliberately.** The hash cache is persisted by the failure path, so a run that dies before the scan records fresh hashes for files it never scanned. Deriving skips from a hash-cache hit would make those files invisible to the scanner. "Hashed" and "scanned" are different facts and do not share a record.
- **Bounded staleness, two ways.** Any change to `secretScanPatterns` or `secretScanMaxFileKB` invalidates every stored verdict (the rule set is folded into a scan epoch), and the existing 28-day forced full re-hash also forces a full rescan — so no verdict can outlive it. **`doRehash`'s interval is therefore now a security parameter**, and a comment at its assignment says so: lengthening it for integrity-cost reasons lengthens the scanner's blind window by the same amount.
- **Reuse requires its control.** A random audit sample re-reads a fraction of skipped files and fails the run if a stored verdict is wrong. `secretScanAuditRate` set to **0 disables *reuse*, not the audit** — with no audit there is nothing that can falsify a stored verdict, so reuse becomes unfalsifiable and the run reads everything instead. Fail slow, never fail quiet.
- **Real-time antivirus timing notice** — Build Runbook **§0b**, with a pointer from the README's risks list. Documents the measured cold-vs-warm on-access scan cost (**~74.8 ms vs ~0.32 ms, ~237x**), the fact that **definition updates flush the verdict cache** so the cost cannot be scheduled around, and how to tell from your own logs whether a slow run is paying it. Mitigations — including an AV exclusion on the staging directory — are named as choices an operator may make and are **deliberately not implemented here**: turning off real-time protection for a directory holding a full plaintext copy of your data is a decision to reach against your own threat model, not to inherit from a backup tool.

### Fixed

- **`tests/Test-PreflightScriptInventory.ps1` can no longer report green without its discrimination control.** The control — which proves the *previous* probe wrongly passes the fixture the current one rejects — was gated behind an optional parameter, so the default invocation printed `11 passed, 0 failed` with the only test that proves anything silently skipped. That is the same defect the suite exists to catch, reproduced inside the suite: an instrument reporting fine while the thing it measures is absent. The old probe is now derived from git (`v0.2.0`, addressed by tag rather than commit SHA, because the 2026-08-22 history rewrite invalidated every prior SHA), and **failure to obtain it fails the suite instead of shrinking it**.

## [0.3.0] - 2026-08-22

### Added

- **Backup health check (`scripts/Invoke-BackupHealthCheck.ps1`) — the answer to "is anything actually watching this?"** A standalone, fail-*closed* verdict over `last-run.json`: six states (`OK | FAILED | STALE | DRYRUN | MISSING | UNREADABLE`), age checked **before** `ok` and beating it, because a stale `ok:true` is byte-identical to a fresh success and `stamp` was the only field separating them. Writes a dated note and appends one line per run to `health-verdicts.jsonl`, so a check that ran and passed is distinguishable from a check that never ran at all — the earlier silent-on-success design made those two states identical, which is why the cadence had to be hourly to compensate. `-Trigger scheduled|manual` is mandatory and defaults to `manual`: a manual run *anchors* a day without *covering* it, and the opposite default would silently mark days covered. Ships with `tests/Test-BackupHealthAlarm.ps1` and `tests/Test-BackupHealthGaps.ps1`, both fully parameterised so tests never touch production history.
- **Shared window/lease module (`scripts/backup-window.ps1`).** `Test-BackupQuiet` (fails **open** by design — quiescing wrong costs a slow backup) and `Get-BackupHealth` / `Test-BackupHealthy` (fail **closed** — health wrong costs believing you have backups you do not). The opposing postures are deliberate and documented at the point of contact; do not harmonise them. Also owns the pause-lease TTL, sized against the longest plausible *run* rather than the longest gap between log writes, so a hard kill cannot strand the flag indefinitely.
- **Staff-memory coverage drift (F17)** — `Assert-StaffMemoryCoverage` in `backup.ps1`, plus a read-only companion (`scripts/Invoke-StaffMemoryCoverageCheck.ps1`) that reports the same comparison **without** touching `ok`. Asserts the configured staff-memory sources still match what is on disk in *both* directions. New config keys `staffMemoryProjectsRoot` + `staffMemoryIgnore`, which **activate together or not at all**: a root set without an ignore list fires `ok=false` on run one and permanently, and a check that always fails is a check nobody reads.
- **Secret-scan coverage ledger (F18-C step 1).** One line per run in `secret-scan-counts.jsonl` next to `lastRunFile`, with `mode` mandatory so a DryRun line can never be misread as a live one. `scanned` is counted **explicitly, never by subtraction** — three paths leave a file unexamined without touching the oversized/binary counters, so `total - skipBig - skipBin` over-reports coverage, which is precisely the lie the ledger exists to catch. New `skipMissing` / `skipRead` counters and a `scanned + all skips == total` reconcile assertion hold it honest.
- **Secret-scan coverage delta assert (F18-C step 2).** `Assert-ScanDelta` compares each Live run against the previous Live run *and* against the best coverage in a rolling window, so a slow night-by-night ratchet downward is impossible — a single-step check can be walked down indefinitely one tolerable drop at a time. **Verdict is WARN-only and never sets `ok=false`.** Tolerances are configurable via `secretScanDelta`; the shipped defaults are **provisional, not empirical**, and the config comment says so.
- **Tier-promotion guard (F15).** A degraded run (`ok=false`) is still uploaded and still verified, but is **withheld** from Weekly/Monthly/Annual promotion, and the withholding is recorded in `last-run.json`. Without this, a single degraded night could become the permanent `annual: -1` archive.
- **Backup log note + share mirror (F16), single writer.** The note is written locally first, then copied to the share, then hash-verified there — so the direction cannot invert. Deliberately does **not** set `ok=false`: under F15 that would withhold tier promotion, and a markdown note failing to copy is not a reason to degrade a verified archive.
- **App-version stamping and restore-time mismatch guard.** `clairvoyanceExePath` is read as file metadata into `BACKUP-META.json` at backup time and compared at restore; unresolvable stamps as `unknown` and WARNs rather than aborting. `restore.ps1` gains a `BACKUP-META` `schemaVersion` guard and numeric version comparison, so `0.79.1` vs `0.79.1.0` is a match rather than a false patch-warn.
- **`.backup-install.json` install manifest** written atomically at go-live, and `Clean-ManifestText` line-injection defence applied at each *display* site rather than at ingestion.

### Fixed

- **Junction cycle wrote a runaway mirror (2026-08-15).** `robocopy` follows junction points unless told not to, and **has no `/XJD`** — the flag people reach for does not exist. A live junction nested six levels deep inside a workspace pointed back up its own tree; the mirror walked the cycle and wrote **637,742** files into the staging directory. Cycles are now detected and excluded before the copy, and every exclusion is logged with both endpoints and an explicit statement of why nothing is lost.
- **A single unopenable file killed the entire nightly (F19, 2026-08-14).** A file literally named `nul` — a reserved Windows device name — is enumerable but cannot be opened, so hashing it threw and aborted the whole run. **The measurement that decided the design: 7-Zip compresses such a directory with exit code 0 while storing zero bytes for it**, so a name-based blocklist would have passed a silently empty archive. The guard is on the *operation*, not on a list of names: unhashable files are skipped, counted, and logged individually (first ten by name, then suppressed), and the run continues.
- **Off-hours abort-window regression follow-up.** The abort window is now asserted at the phase boundaries it actually guards, and an abort unwinds through the `finally` that clears the pause flag, so aborting never strands the fleet-gating lease.

### Changed

- **Repository layout: `scripts/` gains four files and a new `tests/` directory appears.** `backup.ps1` grew from 360 to 1,527 lines and `restore.ps1` from 88 to 377 as the checks above landed; no function was removed or renamed.
- **Published scripts are ASCII-only.** The source files carry no byte-order mark, and PowerShell 5.1 reads a BOM-less non-ASCII `.ps1` as ANSI — so the few UTF-8 status glyphs in comments were replaced with ASCII markers rather than adding BOMs, keeping the tree uniformly BOM-less. **One of these appears in an emitted string**, so the disabled-schedule warning that `Invoke-BackupHealthCheck.ps1` writes into its note now reads `[!]` where it previously carried a coloured glyph.
- **`backup-preflight.ps1` checks the *installed* script set instead of a hardcoded list of three.** The probe asserted `"all 3 scripts present and parse-clean"` against a fixed array, so once the shipped set grew it could report a complete install while a required file was absent. It now derives the count from the set it actually checked, and — this is the part that matters — **an optional component that is installed drags in whatever it dot-sources.** `Invoke-BackupHealthCheck.ps1` hard dot-sources `backup-window.ps1` at load, so an install carrying the first without the second is one whose watchdog throws the moment it runs. Previously that install reported COMPLETE: the tool whose entire job is to say an install is broken said it was fine, which is the same "you believe you have backups you do not" failure this release exists to close, reached through the instrument meant to detect it.
  The optional components remain **optional** — their absence is a valid install and does not fail preflight. Requiring the module unconditionally would have been the smaller change and the wrong one: it fails a correct core-only install, and a check that fires on a healthy system is a check nobody reads. Covered by `tests/Test-PreflightScriptInventory.ps1`, whose control case asserts the *previous* probe wrongly passes the fixture the new one rejects.

## [0.2.0] - 2026-07-24

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

[Unreleased]: https://github.com/bubomortis/clairvoyanceai-backup-system/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/bubomortis/clairvoyanceai-backup-system/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/bubomortis/clairvoyanceai-backup-system/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/bubomortis/clairvoyanceai-backup-system/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/bubomortis/clairvoyanceai-backup-system/releases/tag/v0.1.0
