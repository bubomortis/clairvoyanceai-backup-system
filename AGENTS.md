# AGENTS.md — Clairvoyance Versioning Backup System

Instructions for an AI agent (Clairvoyance Staff or similar) asked to install, verify, or repair this backup system on a user's Windows machine.

## Authoritative procedure

`docs/Build-Runbook.md` is the single source of truth for installation. Read it in full and follow it exactly. This file only states the guardrails; it does not replace the runbook. If the runbook and a user's paraphrased request disagree, follow the runbook and raise the discrepancy.

`docs/Companion-Scripts.md` remains the canonical source of the installable scripts — an installing agent authors them from that text, so a trustless adopter needs nothing beyond it. `scripts/*.ps1` are verbatim extracts and may be used interchangeably. `tests/*.ps1` are **not** part of an install and are deliberately absent from the companion document.

| file | role |
|---|---|
| `scripts/backup.ps1` | the engine |
| `scripts/restore.ps1` | restore / verify / extract |
| `scripts/backup-preflight.ps1` | read-only install & idempotency probe |
| `scripts/evaluate-workspaces.ps1` | read-only workspace sizing helper |
| `scripts/backup-window.ps1` | shared quiesce-lease + health module, dot-sourced by the others |
| `scripts/Invoke-BackupHealthCheck.ps1` | scheduled health verdict; fails closed |
| `scripts/Invoke-StaffMemoryCoverageCheck.ps1` | read-only staff-memory coverage drift report |
| `tests/*.ps1` | standalone test harnesses; parameterised so they never touch production state |

### Placeholders

Every shipped script carries placeholders that **must** be substituted for the user's real paths before the script will run. A placeholder left in place is not a silent default — it is a path that does not exist.

| placeholder | meaning |
|---|---|
| `<TOOL_DIR>` | the permanent local tool directory (Step 5a) |
| `<WORKSPACES_ROOT>` | the root under which workspaces live |
| `<DATA_DIR>` | the Clairvoyance user-data directory |
| `<TOOLS_DIR>` | the shared external-tools directory, if the user has one |
| `<YOU>` | the user's Windows account name |
| `<PC>` | the machine name |

`<DATA_DIR>` and `<TOOLS_DIR>` are new in this release; installs written against the previous version will not have them.

## Hard rules (do not violate)

1. **Attended only.** Tell the user up front that this build requires them present to approve "Allow Once" permission prompts. Never attempt an unattended install.
2. **A prompt is not consent.** Stop and get the user's explicit approval, one step at a time, before: (a) sealing the AES-256 secrets passphrase (DPAPI), (b) creating the SYSTEM scheduled task (runs as SYSTEM, highest privileges), (c) any folder ACL lockdown.
3. **Lockdown is last.** Apply any `ArchivistBackup`-style ACL/ownership lockdown only as the final go-live step, after everything else is validated — never mid-build (it will lock the toolchain out).
4. **Idempotency first — run the probe, don't eyeball it.** Before mutating anything, author `backup-preflight.ps1` to the tool dir (per rule 5) and run it — it is READ-ONLY and detects an existing install by probing **live** state (the three engine scripts parse, `config.json` is valid, the passphrase file actually DPAPI-unseals *on this machine*, and the "Clairvoyance Nightly Backup" SYSTEM task exists), not a marker file. Branch on its verdict:
   - **COMPLETE** → a valid install is already in place. **STOP.** Do not re-run the installer, re-seal the passphrase, or re-register the task. To refresh scripts use the **Update** path (repo-sourced files only); to change the passphrase use the **Rotate** path (re-encrypts the secrets archives) — never as an install side effect.
   - **PARTIAL** → resume the runbook at the reported first-unmet invariant *only*; never restart from Step 1, never re-seal an existing valid passphrase.
   - **DUPLICATE** → ambiguous state (e.g. two same-named SYSTEM tasks). **STOP and ask the user** which is canonical; never guess.
   - **NOT_INSTALLED** → proceed with a full install.
   **Never re-seal an existing passphrase**: the AES secrets archives are keyed to it, so overwriting the seal permanently orphans every existing encrypted backup. Guard this at the seal step itself, not just here.
5. **Trustless authoring.** Author the scripts into the tool directory from this repo, substitute placeholders, and verify each parses (`[System.Management.Automation.Language.Parser]::ParseFile`, zero errors) before executing anything.
6. **SMB signing stays off by default.** The optional `RequireSecuritySignature` hardening breaks guest-login network shares; enable it only if the user explicitly asks and understands the risk.
7. **Never enable go-live silently.** Do a supervised validation run and show the user `last-run.json` before arming any real scheduled task. Get explicit approval to arm.
8. **Do not modify this source repository.** No commits, no pushes back to origin. Report every command and its result.

## Prerequisites to confirm

Windows 10/11 · PowerShell 5.1+ · 7-Zip · robocopy (built in) · a reachable backup destination (network share or fixed disk). Report any missing prerequisite and stop.

## Tool directory constraints

A permanent local directory on a fixed disk that both Clairvoyance and a SYSTEM scheduled task can reach and execute. No UNC path, no OneDrive-synced folder, no temp directory.

## Risk acknowledgements to surface

The main archive is unencrypted by default; the secrets archive is AES-256 with a DPAPI-sealed, machine-bound passphrase (losing it means the encrypted archive is unrecoverable). Single destination = no offsite copy unless the user adds one. `restore.ps1 -Mode InPlace` is whole-archive and will overwrite live locations — use `-Mode Extract` for single-file recovery. See the **Risks & limitations** section of `README.md` for the complete list.
