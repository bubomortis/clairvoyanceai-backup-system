# Clairvoyance Backup System — Build Runbook

*A portable, environment-agnostic procedure for building a daily, versioned, verified backup of a Clairvoyance install. An executing Clairvoyance Staff member follows this to interview the user and generate the whole system. **Contains no environment-specific identifiers** — every path/name/host is gathered by interview.*

**Companion scripts — self-contained, no file transfer needed.** The full source of the three config-driven scripts (`backup.ps1`, `restore.ps1`, `evaluate-workspaces.ps1`) is in the companion note **"Clairvoyance Backup System — Companion Scripts"** (in the GitHub repo this is **`docs/Companion-Scripts.md`**; the same three scripts are also provided verbatim as **`scripts/*.ps1`**), which should be shared alongside this runbook. In **Step 5 the executing AI reads that note and writes the three scripts to disk itself** (extract each fenced block → write `<TOOL_DIR>\<name>.ps1` → substitute `<TOOL_DIR>`/`<WORKSPACES_ROOT>` → verify it parses). **The user never builds scripts by hand from the markdown** — the note is fenced source purely so it stays human-auditable and trustless (nothing is downloaded from a stranger; your own AI authors the files locally). A trustless adopter needs nothing but this runbook + that companion note.

> **⚠️ Executing Staff: warn the user BEFORE you start — this is an attended, interactive build (~30–60 min), not a one-click install.** Tell them plainly at the outset: (1) there's an **upfront interview** they must answer — the system is generated from their answers and can't proceed without them; (2) they need to **stay at the machine for the entire build and approve permissions as each step runs** — this runbook triggers many discrete actions (file writes, PowerShell, robocopy, 7-Zip, `schtasks`, ACL changes) plus **UAC elevation** prompts; (3) **some prompts only offer "Allow Once"** (no remember/always option), so approvals recur and **an unapproved prompt stalls the build until they return** — they can't walk away. Be accurate about pre-granting: broader harness permissions **reduce** the clicks but do **not** enable an unattended build — the **"Allow Once"-only prompts aren't covered by pre-granted/broad permissions**, so some dialogs appear regardless; the user must be present either way. Get their acknowledgement before beginning Step 2.

---

## 0. What this builds
- A **daily** backup of: the Clairvoyance app-data folder, all workspaces, and chosen dependency folders → a destination the user picks (local disk or SMB share).
- **GFS retention** (Daily / Weekly / Monthly / Annual) with physical duplicates and **missed-period substitution** (a missed Sunday/month-end is back-filled by the next run).
- **Two archives per version:** an unencrypted `_main.7z` and an **AES-256 `_secrets.7z`** (credentials + any workspaces the user elects to encrypt).
- **Efficiency:** a persistent robocopy `/MIR` mirror (delta copy) + a size/mtime **hash cache**; **incremental** weekly "artifacts" archive for large/regenerable dirs; share-side tier copies; upload + deep verify.
- **Least privilege:** the nightly job runs as a **SYSTEM scheduled task** invoking `backup.ps1`; a **Clairvoyance Archivist** staff member only monitors/logs/alarms.
- **Recovery:** each archive carries a `MANIFEST` + `RECOVERY.md`; `restore.ps1` does verify / in-place / bare-metal.

## 0a. What the engine does automatically (efficiency + security)
The companion scripts (`backup.ps1`/`restore.ps1`) already implement the following — **no configuration or user action required**; this list is for transparency so you can see what the engine does under the hood before you trust it. (These come from a prior efficiency + security audit; the tags are internal reference IDs.)

**Efficiency — keeps nightly runs small, fast, and self-verifying:**
- **Delta mirroring:** a *persistent* robocopy `/MIR` mirror on your staging disk — only changed files are copied each night, not the whole dataset.
- **Hash cache:** SHA-256 manifest with a size/mtime cache, so unchanged files are not re-hashed — with a **monthly forced full re-hash** to catch silent bit-rot the cache would otherwise trust.
- **Incremental artifacts:** the weekly large/regenerable "artifacts" archive only adds new/changed files (indexed), instead of re-archiving everything.
- **Tuned compression + verification:** multi-threaded 7-Zip with per-tier compression levels; every archive is integrity-tested and a random sample is extracted **from the destination copy** and hash-checked (deep-verify).
- **Guarded window:** an abort-window check stops a run that would overrun into your reboot/maintenance window rather than leaving it half-done.
- **Staff-continuity coverage assertion (F14):** after the manifest is built, the run checks that the Staff-member files (`profiles/staff.json`, `agent-sessions.json`, custom `neurons/personas/`, and the Home workspace's `.Clairvoyance/staff/` memory — configured via `protectedPaths`) are actually in the archive. If any is missing (e.g. a future exclude silently clipped it), the run logs a **FAIL** stage and sets `ok=false` so the monitor alarms — **without aborting**, so you never lose a night's backup over the check.

**Security — protects the passphrase, the secrets, and the restore path:**
- **Passphrase never on disk in clear / never on the command line (F3, F11b):** read from a machine-bound **DPAPI**-sealed file, passed to 7-Zip via **stdin**, and the environment variable is cleared before any child process runs.
- **Secrets isolation (F4, F8):** secret files/dirs are excluded from the plaintext mirror/main archive and gathered separately into the AES-256 archive; the full path-map manifest lives **only inside the encrypted** archive.
- **Secret leak scan (F7):** before compressing, the plaintext set is scanned for token/key patterns and **warns** if anything sensitive would land in the unencrypted archive.
- **Hardened execution (F9, F10, F13):** the system `robocopy.exe` path is pinned (no PATH hijack while elevated), temp dirs are swept, and the passphrase is redacted from all logs.
- **Safe restore (F2):** in-place restore validates every target against allowed roots and rejects UNC/`..`/device-path traversal.
- **Retention for secrets (F12):** the encrypted secrets archives prune on their own (shorter) schedule.

Two hardening items **do** require a decision and appear as steps: the **folder lockdown** (Step 12) and the **optional SMB-signing** election (interview Q12 → Step 12).

## 1. Prerequisites (Windows 10/11)
- PowerShell 5.1+ · **7-Zip** installed (note its `7z.exe` path) · `robocopy` (built-in).
- A backup **destination** reachable as a path (local drive or `\\server\share`).
- The Clairvoyance app running (to hire the Archivist) · **local administrator** rights (SYSTEM task, `/B` open-file copy, folder lockdown).

## 1a. Preflight — detect an existing install (idempotency gate; RUN BEFORE the interview)

**Do this before Step 2 — never assume a fresh machine.** Re-running the build over a live install can re-seal the passphrase (**orphaning every existing AES `_secrets.7z`**), duplicate the SYSTEM task, or overwrite a tuned `config.json` / `backup_state.json`. Detect first, with a **probe**, not a glance.

1. **Author `backup-preflight.ps1`** using the Step 5a/5b/5c procedure for that one script (pick `<TOOL_DIR>`, write it from the companion source, verify it parses). It is **read-only** — it mutates nothing, seals nothing, and never touches the task.
2. **Run it** against the intended tool dir:
   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File <TOOL_DIR>\backup-preflight.ps1 -ToolDir <TOOL_DIR>
   ```
   Add `-TaskName "<name>"` if a non-default task name was used, `-Json` for machine-readable output, or `-CheckUpdate` to compare the installed version against the latest GitHub release. The probe checks **live** state — the engine scripts parse, `config.json` is valid, the passphrase file actually **DPAPI-unseals on this machine**, and the "Clairvoyance Nightly Backup" SYSTEM task exists — and prints a `VERDICT` (exit code: 0 COMPLETE · 1 NOT_INSTALLED · 2 PARTIAL · 3 DUPLICATE · 4 probe error).
3. **Branch on the verdict:**
   - **COMPLETE** → a valid install is already here. **STOP — do not re-run this runbook.** To refresh the scripts use **§Update**; to change the passphrase use **§Rotate** (both below). Never re-seal or re-register as a side effect.
   - **PARTIAL** → resume at the reported **first-unmet invariant** *only* (e.g. scripts + config + seal present but no task → skip straight to Step 9). Never restart from Step 1; never re-seal an existing valid passphrase.
   - **DUPLICATE** → ambiguous state (e.g. two same-named SYSTEM tasks). **STOP and ask the user** which is canonical — never guess.
   - **NOT_INSTALLED** → proceed to Step 2 for a full install.

## 2. Interview the user (ask, record answers)
1. **Backup destination** root path.
2. **Instance name** — default the PC hostname; if multiple Clairvoyance installs share one PC, ask for a nickname (destination subfolder = this name).
3. **Frequency** (default daily) and **time** `HH:MM`, pinned to **local machine time** or a **named timezone**.
4. **Staging directory** — a fast local disk with room for ~one uncompressed copy of the daily set (the persistent mirror lives here). *Ask explicitly.*
5. **Temp directory** — for archive assembly (default: a `work` folder under the tool dir).
6. **Copy method:** `robocopy /B` (default; needs elevation, best open-file consistency) · **VSS snapshot** · **brief app-close** · **tar**.
7. **Versioning (GFS)** — offer these defaults, allow full override: **Daily 7 · Weekly 12 (last-day-of-week = Sunday, changeable) · Monthly 12 · Annual keep-all**. Secrets tiers prune shorter (e.g. Monthly 3 / Annual 2).
8. **Source roots** — the Clairvoyance app-data dir, the workspaces root, any dependency dirs. Electron caches are auto-excluded; confirm additional excludes.
9. **Secrets set** — confirm the default sensitive files (auth/token/credential stores, connector tokens, `rclone.conf`, etc.); add any others. These always go to the **encrypted** archive.
10. **Per-workspace AES election** — for **each** workspace, ask: encrypt it into the AES secrets archive, or leave it in the plaintext main archive? **⚠️ Explain the risk first:** *encrypting a workspace means if the passphrase is ever lost, that data is unrecoverable. Default = no (workspaces stay in the plaintext main archive, protected by destination access-control).* Only encrypt workspaces holding genuinely sensitive content.
11. **Orchestrator registry** — which Staff run automated pipelines (they must pause during backup).
12. **Optional SMB-signing hardening (default = NO).** Ask whether to require SMB signing on this machine's SMB client (`RequireSecuritySignature`). It hardens SMB against tampering/MITM. **⚠️ PROMINENT WARNING — read this to the user before they answer:** *"Saying **yes** may break your network shares if any of them use **guest / anonymous logins** (very common on NAS boxes — e.g. Unraid, or any public/guest SMB share). Guest sessions cannot be SMB-signed, so requiring signing makes Windows reject them — and it fails with a **misleading 'error 67 / network name cannot be found'**, not an obvious auth error. This includes your backup destination if you reach it as a guest share. It takes effect at the **next reboot**, so the breakage can appear later and seem unrelated. Only say yes if **every** SMB share you use (backup destination and otherwise) is reached with a **real authenticated account**, not guest."* Default **NO**. If yes, record the election for Step 12 and note the revert command.

## 3. Proactive workspace scan (do BEFORE finalizing excludes)
> **⚠️ Ordering:** this step runs `evaluate-workspaces.ps1`, but the scripts are not written to disk until **Step 5b**. Author that one script first — do the Step 5a/5b/5c procedure for `evaluate-workspaces.ps1` now (pick `<TOOL_DIR>`, write the file from the companion source, verify it parses), then run it here. The other two scripts can still wait until Step 5.

Run `evaluate-workspaces.ps1 -Root <workspaces-root>`; it prints each workspace's top-level directory sizes and flags **LARGE** dirs. For each large dir, ask the user: **full daily** / **exclude** (if regenerable) / **route to the weekly Artifacts tier** (large but worth keeping less often). Record into per-workspace tuning (`excludeDirs` / `excludeFiles` / `artifactDirs`). This keeps the nightly daily set small and inside the backup window.
- **Regenerable = exclude.** Common culprits, often multiple GB: Python **virtual environments** (`venv` / `.venv` / `site-packages` — includes big CUDA/cuDNN/NVIDIA DLLs), **downloaded model blobs** (`models`, HuggingFace caches, Whisper/etc.), `node_modules`, tool binaries, `downloads`. These re-create from `requirements.txt`/package manifests or re-download — don't back them up.
- **⚠️ Re-scan periodically — "full daily" decisions go stale.** A workspace that was tiny at setup can grow into a multi-GB pipeline later (e.g. someone adds a `venv` + models). If its daily set outgrows the backup window, the SYSTEM task's execution-time-limit will **kill the run mid-compression** (a partial/failed backup). Re-run this scan when workspaces grow, and when excluding an already-mirrored large dir, also delete it from the **staging mirror** (the main archive is built from the mirror, so config excludes alone won't shrink it until the stale copy is removed).

## 4. Generate `config.json`
Fill a `config.json` from the interview: `instanceName`, `backupRoot`, `sevenZip`, `copyMethod`, `stagingDir`, `tempDir`, `passphraseFile`, `pauseFlag`, `lastRunFile`, `lastDayOfWeek`, `abortAfterLocalTime`, `deepVerifySample`, `retention`, `secretsRetention`, `sources[]` (name/path/category/excludeDirs/excludeFiles), `workspacesRoot`, `workspaceDefaults` + `workspaceTuning` (per-workspace excludeDirs/excludeFiles/artifactDirs/**encrypt**), `secretsSet`, `secretScanPatterns`, `protectedPaths` (Staff-continuity assertion — see `config.example.json`), `orchestrators[]`.

**Use [`config.example.json`](../config.example.json) as the structural template** — it shows the exact nesting, types, and object shapes (`retention`/`secretsRetention` maps, the `sources[]` entries, per-workspace `workspaceTuning`, `secretsSet` glob patterns, `orchestrators[]`), with placeholder paths (`<TOOL_DIR>`, `<WORKSPACES_ROOT>`, `\\SERVER\Backup\Clairvoyance`) to replace with the interview values. Copy it, substitute, and drop the `_comment*` annotation keys (the engine ignores unknown keys, but they are there only to explain the fields).

## 5. Install scripts + create Home notes

**YOU (the executing Staff member) build the script files to disk — the user never assembles anything by hand.** The Companion Scripts note holds the three scripts as fenced code blocks *only* so the source is human-auditable and trustless (nothing is downloaded from a stranger; it is authored locally from a note the user can read). Turning that note into working files is **your** job, done programmatically with your file tools — do not ask the user to copy-paste out of the markdown.

**5a. Pick the tool directory `<TOOL_DIR>`.** Choose (and confirm with the user) a stable path on a **local fixed disk** that both **Clairvoyance and the SYSTEM scheduled task can reach and execute from**. It must **not** be a UNC/network share, a OneDrive/synced folder, or a temp/cache dir (the SYSTEM task and the lockdown in Step 12 depend on a stable local ACL'able location). Create the directory now.

**5b. Materialize each script from the note (programmatic, not manual).** For each of the three fenced ```` ```powershell ```` blocks in the Companion Scripts note — `backup.ps1`, `restore.ps1`, `evaluate-workspaces.ps1` — read the note, extract the block's exact contents, and **write it to `<TOOL_DIR>\<name>.ps1` with your file-write tool.** Then substitute the placeholders in the param defaults with the interview values: `<TOOL_DIR>` → the Step 5a path, `<WORKSPACES_ROOT>` → the workspaces root from Step 2 (or leave them and always invoke with explicit `-ConfigPath`/`-Root`).

**5c. Verify each written file** before moving on: it must **parse** (e.g. `powershell -NoProfile -Command "[void][System.Management.Automation.Language.Parser]::ParseFile('<TOOL_DIR>\<name>.ps1',[ref]$null,[ref]$null)"` returns no errors) and its body must **match the note** (compare line count / hash of the extracted block against the file, ignoring the placeholder-substituted lines). Only then are the scripts "installed."

**5d. Create the Home notes:** **Backup Control** (governance: active/paused/disabled + `pause_until`), **Backup Log** (append-only run log), **Backup Pause Board** (coordination), and the **Archivist operating procedure** doc (human-facing reference; the Archivist's own in-role orientation is its *staff memory*, seeded in Step 6).

## 6. Hire the Clairvoyance Archivist
Hire a Staff member named "Clairvoyance Archivist" (a cheap model is fine — this is deterministic orchestration), in the **Home** workspace, top-level. Its role: **monitor** the SYSTEM backup's result, append to the Backup Log, alarm on failure. It does **not** execute the backup or touch the passphrase.

> **If you can't hire Staff** (the executing agent lacks recruitment capability, or the user declines): the backup itself does **not** depend on the Archivist — the SYSTEM task runs and writes `last-run.json` regardless. Monitoring is a convenience layer. Skip this step and Step 9's monitor schedule, and instead tell the user to check `last-run.json` (and the destination tiers) after the first run, or wire a simpler alert. Note the gap in the Backup Control note so it's a conscious decision, not a silent omission.

**Seed its staff memory so it stays in-role during interactive chats — not just scheduled runs.** The monitor role in the schedule prompt (Step 9) and any separate procedure doc orient it only when the *scheduler* invokes it; when a human converses with it directly it instead loads its **staff memory** (`<app-data>\.Clairvoyance\staff\clairvoyance-archivist\index.md`), and an empty memory makes it drift back to generic-assistant behavior (answering off-topic questions as if it were general staff). Write two things into that staff dir:
- **`index.md`** — the always-loaded index. Open it with identity, not just notes: *"You are the Clairvoyance Archivist. Your **sole focus is the backup system**; you are its dedicated monitor and the authority on it. Treat **every** question as backup-related **unless it explicitly says otherwise**. You monitor — you never run `backup.ps1` or touch the passphrase."* Then add an `IF asked anything about the backup system → read [[backup-system-authority]]` route.
- **`backup-system-authority.md`** — the full working knowledge so it is the standing authority: architecture, file locations, every `config.json` field, the three scripts and what they do, the SYSTEM task + monitor schedule, all mechanisms (GFS/retention, secrets-split/AES/DPAPI, staging mirror + hash cache, deep-verify, missed-period substitution, pause flag), the security F-tags, the known bugs/gotchas, and current state.

This durable memory — not the schedule prompt alone — is what keeps the Archivist behaving as the backup authority in conversation. (The "Archivist operating procedure" doc from Step 5 is human-facing reference; the staff memory is what the Archivist itself loads.)

## 7. Seal the passphrase (DPAPI, user-run)
> **⚠️ HARD REFUSE re-sealing — this is the one irreversible step.** Before sealing, check whether a sealed passphrase file **already exists** at `<passphraseFile>`. **If it does, DO NOT overwrite it** — the existing AES `_secrets.7z` archives are keyed to the current passphrase, so re-sealing a *different* one permanently orphans every existing encrypted backup, and re-sealing the *same* one is pointless. This is not a skippable prompt: stop, and only proceed to re-key through **§Rotate** (which re-encrypts the archives under the new key). The preflight in Step 1a already reports the seal state; guard here too (belt-and-suspenders) since the runbook can be entered mid-way:
> ```
> if(Test-Path -LiteralPath "<passphraseFile>"){ throw "passphrase already sealed at <passphraseFile> — refusing to re-seal (would orphan existing _secrets.7z). Use the Rotate path to re-key." }
> ```

The user runs, in PowerShell — **typing the passphrase at the masked prompt, never pasting it into the command** (a `$` in a double-quoted string expands as a variable and exposes it):
```
Add-Type -AssemblyName System.Security; $sec = Read-Host -AsSecureString "Backup secrets passphrase"
[Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes([Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))), $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)) | Set-Content -LiteralPath "<passphraseFile>" -Encoding ASCII
```
Store the same passphrase in a password manager. It is **machine-bound** (LocalMachine DPAPI) so a SYSTEM task can read it; on a bare-metal rebuild you re-seal from the password manager.

## 8. §9a — Orchestrator pause-compliance onboarding
For each orchestrator in the registry: (a) **audit** whether it checks the backup pause flag before starting automated work; (b) **remediate** — add the pause-contract to its workspace `CLAUDE.md` ("before any automated run, check for the `BACKUP_IN_PROGRESS` flag; if present, do not start; wait until cleared"); (c) **drill** — set the flag, confirm it holds, clear it, confirm it resumes; (d) **record** compliance. A non-compliant orchestrator doesn't break the backup (crash-consistent copy) but is flagged.

## 9. Create the SYSTEM scheduled task
**Check before you register** (idempotency): if a task named "Clairvoyance Nightly Backup" already exists (`Get-ScheduledTask -TaskName "Clairvoyance Nightly Backup" -ErrorAction SilentlyContinue`), do **not** blindly create a second one — a duplicate means two SYSTEM backups race nightly. Update the existing task in place, or unregister-then-register the single canonical task. If the preflight reported **DUPLICATE**, resolve that with the user first.

Elevated: register a task **RunAs SYSTEM, RunLevel Highest**, at the chosen time, action = `powershell.exe -File <tool>\backup.ps1 -ConfigPath <tool>\config.json -Mode Live`, execution-time-limit slightly under the reboot/window. Set the Archivist's Clairvoyance schedule to fire shortly after (monitor role). **Create both disabled** until validated.

**Config / state writes are merge-preserving, never truncate-and-rewrite.** When updating an existing `config.json` (re-install / retune), read-modify-write and preserve unknown keys, and never touch `backup_state.json` (it holds the GFS tier cursors + `lastFullRehash` — clobbering it silently resets retention/tiering). Write via temp-file + rename (atomic) so a mid-write crash can't corrupt either file.

## 10. Validate
Run one supervised backup to a **test destination folder** (use `backup.ps1 -RunDate <today>` to bypass the abort-window guard for a daytime run; `-SkipSecrets` if you don't want to involve the passphrase). Confirm: tiers created; secrets archive AES-encrypted; `restore.ps1 -Mode Verify` passes on **both** `_main.7z` and `_secrets.7z` (secrets needs the passphrase via `RESTORE_SECRETS_PASS`); and confirm a **time-boxed run** (note the elapsed time vs the task time-limit from Step 9). Then remove the test folder.

**Confirm single-file recoverability SAFELY.** ⚠️ **`restore.ps1 -Mode InPlace` is WHOLE-ARCHIVE — it restores *every* file to its original live location, overwriting current data.** Do **not** run it to "test recovery" on a live machine (it will revert live files to the backup's point-in-time). To validate you can recover a file, use **`-Mode Extract -Dest <scratch>`** (writes only to the scratch dir), then diff/hash one extracted file against its live copy — or, on a live box, rename one file aside, copy its extracted counterpart back, and verify the hash. Reserve `-Mode InPlace` for a genuine disaster-recovery or a throwaway test machine.

## 11. Verify the SYSTEM task can reach the destination
**Do this before enabling — especially if the first run will be unattended.** The nightly task runs as the **SYSTEM/machine account**, not as you. If the destination is a network share whose ACLs grant only *your* user (common on a NAS), SYSTEM cannot write to it and the backup fails at upload — silently, if the first run is unattended. Prove SYSTEM can write there *before* go-live:

- Run a write test **as SYSTEM** (not as your interactive user), e.g. `PsExec -s -accepteula powershell -Command "New-Item -ItemType File '\\<server>\<share>\Clairvoyance\<instance>\_systest.txt'; Remove-Item '...'"`, **or** run the task itself once against a real destination with `backup.ps1 -RunDate <today>` (bypasses the abort-window guard) and confirm the tiers land on the share.
- If SYSTEM cannot write: either grant the **machine account** (`DOMAIN\<PC>$` / the NAS's equivalent) write + a Backup Operator-style right on the share, **or** change the task to run as a **dedicated service account** that has share access, instead of SYSTEM.

Only proceed once a SYSTEM-context write to the real destination succeeds.

## 12. Lock down + go-live

**First, write the install manifest** `<TOOL_DIR>\.backup-install.json` (do this *before* the ACL lockdown, while the folder is still writable). It records what was installed so `backup-preflight.ps1` has a version stamp to read (and cross-check against live probes on the next run). Write it **atomically** (temp + rename):
```powershell
$m = [ordered]@{
  schemaVersion = 1
  version       = "<release-tag e.g. 0.2.0>"      # the repo version these scripts came from
  installedAt   = (Get-Date).ToString('o')
  taskName      = "Clairvoyance Nightly Backup"
  components    = [ordered]@{ scripts = $true; config = $true; seal = $true; task = $true }
  sealFingerprint = "<first 16 hex of SHA-256 of the sealed .secretkey bytes>"   # NON-secret: hash of the already-encrypted blob
}
$tmp = "<TOOL_DIR>\.backup-install.json.tmp"
($m | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $tmp -Encoding UTF8
Move-Item -LiteralPath $tmp -Destination "<TOOL_DIR>\.backup-install.json" -Force
```
The manifest is **advisory** — the preflight always re-verifies each component against live state, so a stale/lying manifest surfaces as drift rather than a false COMPLETE. Never store the passphrase or its plaintext here.

Then re-ACL the tool directory to **SYSTEM + Administrators only** (remove Authenticated Users) and **transfer ownership to Administrators** (so a standard token can't re-grant). **Do this LAST** — it locks the folder from non-elevated editing. Then **enable** both scheduled tasks. (Enabling only arms them; the first backup runs at the next scheduled time.)

**Optional SMB-signing hardening — apply ONLY if the user elected YES in interview Q12.** Skip entirely otherwise (this is the safe default; it is **not** required for the backup to work).
```powershell
Set-SmbClientConfiguration -RequireSecuritySignature $true -Force   # takes effect at next reboot
```
> ⚠️ **If network shares stop working after this** (guest/public SMB shares failing, typically as a misleading "error 67 / network name cannot be found" after the next reboot), **revert it** — this is the recovery step:
> ```powershell
> Set-SmbClientConfiguration -RequireSecuritySignature $false -Force
> ```
> `EnableSecuritySignature` can stay `$true` (opportunistic signing when the server supports it — harmless, does not block guest). Reverting the *requirement* does **not** affect the backup, which uses an authenticated session to its destination.

## 13. Recovery reference
- `restore.ps1 -Archive <_main.7z> -Mode Verify` — integrity-check vs manifest (no writes).
- `... -Mode InPlace -Force -ConfigPath <config>` — **WHOLE-ARCHIVE** restore to original locations (overwrites every file present in the archive), **validated** against allowed roots (rejects UNC/traversal). Use only for genuine recovery — see the Step 10 warning. For a single file, use `-Mode Extract -Dest <scratch>` and copy the one file back.
- Secrets: `-Archive <_secrets.7z>` with the passphrase (env `RESTORE_SECRETS_PASS`).
- Each archive's embedded `RECOVERY.md` has the clean-install rebuild steps.

## §Update — refresh the scripts on an existing install (NOT a re-install)
Upgrading an already-installed system must **not** re-run this runbook (that re-hits the mutating steps). Update touches **only repo-sourced files** and never re-seals the passphrase or re-registers the task:
1. Run `backup-preflight.ps1 -CheckUpdate`; proceed only if it reports **COMPLETE** and an update is available.
2. Re-author `backup.ps1`, `restore.ps1`, `evaluate-workspaces.ps1`, `backup-preflight.ps1` from the new companion source, substitute placeholders, and **verify each parses** before replacing the live files (keep `.bak` copies). The tool dir may need a temporary ACL grant if it was locked in Step 12; restore the lockdown after.
3. Do **not** touch `config.json`, `backup_state.json`, `.secretkey`, or the scheduled task. Bump `version` in `.backup-install.json` (atomic write, as in Step 12).
4. Run one supervised `backup.ps1 -RunDate <today>` and confirm `last-run.json` `ok=true`.

## §Rotate — change the passphrase (the ONLY sanctioned way to replace the seal)
Re-sealing is otherwise refused (Step 7) because the AES archives are keyed to the current passphrase. To genuinely re-key: (1) with the **old** passphrase, `restore.ps1 -Mode Extract` any secrets you must preserve to a scratch dir; (2) seal the **new** passphrase; (3) re-encrypt — the simplest safe path is to let the next backups build fresh `_secrets.7z` under the new key and **retain the old encrypted archives + the old passphrase** until retention ages them out (older archives stay decryptable only with the old key). Never delete the old passphrase while archives encrypted under it are still within their retention window.
