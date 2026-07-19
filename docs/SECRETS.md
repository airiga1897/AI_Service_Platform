# Secrets

Real secrets must not be committed to this repository.

Use GitHub Environments, Ansible Vault, SOPS, or operator-local ignored files
for secret values. Example env files may document variable names, but values must
remain empty or use obvious placeholders.

Secret categories include:

- SSH credentials for VPS access;
- registry tokens when needed;
- database passwords;
- application secret keys;
- Sentry and provider API keys;
- TLS account credentials;
- SoftEther VPN users, server config, management passwords, and private keys.

## Operator Backup Encryption

The age private identity for operator backups is also a secret:

- `D:\Projects\Ai_SP\Secure\operator-backup-age-identity.txt`
- any line matching `AGE-SECRET-KEY-*`

Do not commit the private identity, place it under `operator/`, upload it to a
VPS, or include it in an operator backup archive.

The operator backup env file may contain the public age recipient only:

```dotenv
AI_SP_OPERATOR_BACKUP_AGE_RECIPIENT=age1...
```

Encrypted `*.age` operator backup artifacts may be stored remotely only when the
private identity is stored separately and remains unavailable to the remote
storage target.

Local secure material backups of `D:\Projects\Ai_SP\Secure` may be stored under
`D:\Backup\Projects\AI_SP\secure` on the operator machine. They must not be
uploaded to VPS nodes.

See [`OPERATOR_BACKUP.md`](OPERATOR_BACKUP.md) for the operator backup key model
and smoke-test commands.
