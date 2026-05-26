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

Create the private identity outside this repository:

```powershell
New-Item -ItemType Directory -Force D:\Secure\AI_Service_Platform
age-keygen -o D:\Secure\AI_Service_Platform\operator-backup-age-identity.txt
```

`age-keygen` prints a public recipient in this form:

```text
Public key: age1...
```

The public `age1...` recipient may be stored in docs or configuration. The
private identity file must not be stored in git, `operator/`, any VPS, or inside
the backup archive it protects.

## Storage Rules

- Keep `D:\Secure\AI_Service_Platform\operator-backup-age-identity.txt` outside
  the repository.
- Save a separate copy in a password manager or offline recovery medium.
- Do not upload the private identity to `vps5`, other VPS nodes, cloud storage,
  or any encrypted operator backup archive.
- Remote storage is acceptable for encrypted `*.age` operator backups only when
  the private identity stays separate.
- Treat any line matching `AGE-SECRET-KEY-*` as a secret.

## Smoke Test

Replace `age1...` with the real public recipient printed by `age-keygen`:

```powershell
"backup-test" | age -r age1... -o .\backup-test.txt.age
age -d -i D:\Secure\AI_Service_Platform\operator-backup-age-identity.txt .\backup-test.txt.age
Remove-Item .\backup-test.txt.age
```

Expected decrypt output:

```text
backup-test
```

After the test, `backup-test.txt.age` should be removed and the private identity
should still exist only under `D:\Secure\AI_Service_Platform`.

## Future Backup Helper Boundary

A future helper may archive `operator/`, encrypt the archive with the public
recipient, and copy the encrypted `*.age` artifact to standby or remote storage.
That helper must not include the private identity in the archive and must not
require the private identity on any VPS.

Restore is a separate operator action: download the encrypted archive, decrypt
it locally with the private identity, then inspect and restore selected files.
