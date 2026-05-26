# Operator Backup With age

This runbook documents the preparation step for encrypted backups of
`operator/`. Runtime backup helpers are intentionally out of scope here; this
page only defines the encryption key model, local storage rules, and smoke
tests.

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

## Storage Rules

- Keep `D:\Projects\Ai_SP\Secure\operator-backup-age-identity.txt` outside
  the repository.
- Save a separate copy in a password manager or offline recovery medium.
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

## Future Backup Helper Boundary

A future helper may archive `operator/`, encrypt the archive with the public
recipient, write `.age` and `.sha256` artifacts to the local backup directory,
delete the raw archive, and copy the encrypted artifacts to the standby
orchestration candidate.

That helper must not include the private identity in the archive and must not
require the private identity on any VPS.

Restore is a separate operator action: download the encrypted archive, verify
the checksum, decrypt it locally with the private identity, then inspect and
restore selected files.
