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

## For adopters

- Keep the tool directory and scripts **admin-only** (the runbook's final lockdown step does this).
- Store the encryption passphrase in a password manager; it is **not recoverable** if lost.
- Verify script integrity before running: the `scripts/*.ps1` files are byte-identical to the fenced blocks in `docs/Companion-Scripts.md` — compare them if you have any doubt about provenance.
- Provided **as-is, without warranty**.
