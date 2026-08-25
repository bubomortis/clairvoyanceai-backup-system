# Security Policy

This project is a backup system that handles sensitive material — an encryption passphrase, a secrets-splitting mechanism, and a privileged (SYSTEM) scheduled task. Please treat security issues accordingly.

## Reporting a vulnerability

**Do not open a public issue for a security vulnerability.** Public disclosure before a fix puts adopters at risk.

Instead, report it privately using GitHub's **[Private vulnerability reporting](https://github.com/bubomortis/clairvoyanceai-backup-system/security/advisories/new)** (Security tab → "Report a vulnerability"). Include:

- what the issue is and where (file / script / step in the runbook),
- how to reproduce it,
- the impact you foresee (e.g. secret exposure, privilege escalation, data loss),
- any suggested fix.

Please allow a reasonable window for a fix before any public disclosure.

## Scope

This repository ships **documentation and PowerShell source** intended to be authored locally and run by the adopter on their own machine. There is no hosted service. The security-relevant surface is:

- `scripts/*.ps1` and the identical fenced source in `docs/Companion-Scripts.md`,
- the `config.example.json` schema,
- the procedure in `docs/Build-Runbook.md` (passphrase sealing, SYSTEM task, ACL lockdown, secrets-set selection).

Reports about the *inherent, documented* trade-offs — the unencrypted-by-default main archive, machine-bound DPAPI passphrase, single-destination model, or the ~1-second inline-passphrase window during test/extract — are already disclosed in the **Risks & limitations** section of the README and are by design, not vulnerabilities. Novel issues beyond those are in scope.

## Threat model notes for two defences in the engine

These record *why* two rules in `scripts/backup.ps1` are shaped the way they are. Both are stated as
prohibitions at the point of use; the reasoning lives here so it is auditable without bulking out the
code. See also `docs/Design-History.md` for the non-security derivations.

### 1. Elevated binary resolution — why absolute paths, never PATH

The nightly task runs as **SYSTEM**. A bare `& toolname` resolves through the PATH of an elevated
process. If any directory on that PATH is writable by a non-administrator, planting a binary of that
name is **arbitrary code execution as SYSTEM, on a timer, every night**.

On a default install this is reachable rather than theoretical: the Clairvoyance root inherits
`Authenticated Users: Modify` from the drive root, so a shared tools directory created under it is
user-writable by default. Adding such a directory to the machine PATH is what turns the exposure
from latent to live.

**Corollary — execution and ingestion are separate rules.** The rule governs what the script *runs*.
It does not govern what it *reads*. Deriving an executed path from a user-writable file (for example
a tools manifest) restores the escalation by another route: read a path, then execute it. Manifest
data may be used **descriptively** — version strings and paths printed into a recovery document —
and must never choose which binary runs or gate a security decision.

**Do not "fix" this by hardening the tools directory.** It holds app-generated launchers written in
*user* context and is the write target of the manifest generator, which must run in user context to
see the user PATH. Locking it to `Users:RX` would break manifest generation and risk the app's own
writes — trading a low-severity ingestion concern for a self-inflicted outage. The correct
mitigation is to treat the file's **content** as untrusted, not the directory as trusted.

### 2. Recovery-document line injection — why ingested text is sanitised

`RECOVERY.md` is generated partly from manifest string fields and is read **by a human under
pressure, mid-restore**, when they are disposed to follow instructions rather than audit them.

A CR/LF in any ingested string field allowed an attacker to author **arbitrary additional lines** in
that document. The working proof-of-concept was a fabricated `## STEP 7 — MANDATORY BEFORE RESTORE`
heading carrying a plausible `irm | iex` command, placed directly above the genuine rebuild step.
Found 2026-07-26 during adversarial review; the defect was live at the time and is fixed.

**The injected text never needs to execute. It needs to be believed.** This is why the sanitiser is
applied at every *display* site and why the rule in the source is written as a prohibition against
the permissive reading — an earlier version of that comment described altering recovery-document
text as "a nuisance", which, applied faithfully, would have licensed exactly this defect.

## For adopters

- Keep the tool directory and scripts **admin-only** (the runbook's final lockdown step does this).
- Store the encryption passphrase in a password manager; it is **not recoverable** if lost.
- Verify script integrity before running: the `scripts/*.ps1` files are byte-identical to the fenced blocks in `docs/Companion-Scripts.md` — compare them if you have any doubt about provenance.
- Provided **as-is, without warranty**.
