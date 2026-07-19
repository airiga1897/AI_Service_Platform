# Operator Backup With age

This runbook documents encrypted backups of `operator/`: the age key model,
local storage rules, remote standby copy, and helper scripts.

`age` is used as the file encryption tool. It uses a public recipient to
encrypt backup archives and a private identity to decrypt them later.

## Operator Machine Prerequisites

Install `age` as a normal Windows CLI tool so it is available from PowerShell
and other shells through `PATH`.

Verify the tools:

```powershell
age --version
age-keygen --version
```

The operator machine has already been prepared with the Windows CLI install
path, so a new PowerShell session should resolve both commands.

## Identity Location

Create the private identity outside this repository. The current operator-local
path is:

```powershell
New-Item -ItemType Directory -Force D:\Projects\Ai_SP\Secure
age-keygen -o D:\Projects\Ai_SP\Secure\operator-backup-age-identity.txt
```

`age-keygen` prints a public recipient in this form:

```text
Public key: age1...
```

The public `age1...` recipient may be stored in docs or configuration. The
private identity file must not be stored in git, `operator/`, any VPS, or inside
the backup archive it protects.

Store the public recipient in the operator-local env file:

```dotenv
AI_SP_OPERATOR_BACKUP_AGE_RECIPIENT=age1...
```

The default path is:

```text
D:\Projects\Ai_SP\Secure\operator-backup.env
```

PowerShell backup helpers parse this file as key-value text. They do not execute
it as a script.

## Storage Rules

- Keep `D:\Projects\Ai_SP\Secure\operator-backup-age-identity.txt` outside
  the repository.
- Save a separate copy in a password manager, offline recovery medium, or the
  operator-machine-only secure material backup directory documented below.
- Do not upload the private identity to the standby orchestration candidate,
  backup-role VPS nodes, cloud storage, or any encrypted operator backup
  archive.
- Remote storage is acceptable for encrypted `*.age` operator backups only when
  the private identity stays separate.
- Treat any line matching `AGE-SECRET-KEY-*` as a secret.

## Encrypted Backup Storage

Encrypted `operator/` backups are created on the operator machine. The raw
archive is temporary, lives only on the operator machine, and must be deleted
after encryption.

Local encrypted artifacts are stored under:

```text
D:\Backup\Projects\AI_SP\operator\
```

Use timestamped filenames:

```text
operator-backup-YYYYMMDDTHHMMSSZ.tar.gz.age
operator-backup-YYYYMMDDTHHMMSSZ.tar.gz.age.sha256
```

The first remote copy goes to the current standby orchestration candidate,
resolved from `platform_role,orchestration.candidate_aliases`. Today that node
is `vps5`, but backup helpers must treat it as the standby orchestration role,
not as a hardcoded host name.

Remote standby storage path:

```text
/opt/backups/ai-service-platform/operator/
```

A future redundancy step should also copy the encrypted artifacts to the active
`platform_role,backup` node, using the same remote path. That backup-role copy
is additive and does not replace the standby orchestration copy.

Only encrypted `.age` artifacts and their `.sha256` files may leave the operator
machine. The private identity must never be copied to remote storage.

## Local Secure Material Backup

The private identity and operator backup env file are backed up separately from
`operator/`. This backup is local/offline only and must not be uploaded to any
VPS:

```text
D:\Backup\Projects\AI_SP\secure\
```

Use the PowerShell helper:

```powershell
.\tools\operator_backup\backup_secure_material.ps1
```

By default it archives `D:\Projects\Ai_SP\Secure` into timestamped local files:

```text
secure-material-YYYYMMDDTHHMMSSZ.zip
secure-material-YYYYMMDDTHHMMSSZ.zip.sha256
```

The helper requires both `operator-backup-age-identity.txt` and
`operator-backup.env`, keeps the newest 10 archives by default, and has no
remote upload mode. `operator-backup.env` should contain only the public
recipient line shown above. Inspect what it would do without creating an
archive:

```powershell
.\tools\operator_backup\backup_secure_material.ps1 -WhatIf
```

## Smoke Test

Replace `age1...` with the real public recipient printed by `age-keygen`:

```powershell
"backup-test" | age -r age1... -o .\backup-test.txt.age
age -d -i D:\Projects\Ai_SP\Secure\operator-backup-age-identity.txt .\backup-test.txt.age
Remove-Item .\backup-test.txt.age
```

Expected decrypt output:

```text
backup-test
```

After the test, `backup-test.txt.age` should be removed and the private identity
should still exist only under `D:\Projects\Ai_SP\Secure`.

## Backup Helpers

Use the helper scripts to archive `operator/`, encrypt the archive with the
public recipient, write `.age` and `.sha256` artifacts to the local backup
directory, delete the raw archive, and copy the encrypted artifacts to the
standby orchestration candidate.

PowerShell:

```powershell
.\tools\operator_backup\backup_operator.ps1
```

By default this uses `.\operator\nodes.csv`, `.\operator\state.csv`,
`.\operator`, `D:\Backup\Projects\AI_SP\operator`, and
`StrictHostKeyChecking=accept-new` for standby upload.

Emergency local-only mode is available when there is temporarily no standby
orchestration candidate:

```powershell
.\tools\operator_backup\backup_operator.ps1 `
  -NodesFile .\operator\nodes.csv `
  -StateFile .\operator\state.csv `
  -LocalOnly
```

`-LocalOnly` still creates the encrypted local `.age` archive, writes the
matching `.sha256`, and applies local rotation. It does not require
`candidate_aliases` in `state.csv` and does not upload to remote standby
storage. Normal runs without `-LocalOnly` remain strict and fail when standby
orchestration is absent.

Backup rotation is enabled by default. The helper keeps the newest 30
timestamped `.age` archives and matching `.sha256` files locally and on the
standby orchestration candidate. Override it with `-KeepLatest N`, or use
`-KeepLatest 0` to disable rotation for a run.

WSL/Linux:

```bash
bash tools/operator_backup/backup_operator.sh \
  --nodes-file ./operator/nodes.csv \
  --state-file ./operator/state.csv \
  --operator-dir ./operator
```

The helpers must not include the private identity in the archive and must not
require the private identity on any VPS. Backup-enabled rollout/bootstrap
scripts call them before local operator mutations unless the operator passes the
explicit skip flag.

For `rollout_from_state`, the backup happens before local state normalization
or HAProxy route file changes. For fresh `bootstrap_from_windows` runs through
`root_password`, the backup happens after the remote bootstrap succeeds and
before local key files or the real `nodes.csv` are changed. That bootstrap
backup uses a temporary sanitized snapshot where the successfully bootstrapped
alias already has `root_password` cleared, so the encrypted archive does not
retain a root password that should now be retired.

Restore is a separate operator action: download the encrypted archive, verify
the checksum, decrypt it locally with the private identity, then inspect and
restore selected files.
