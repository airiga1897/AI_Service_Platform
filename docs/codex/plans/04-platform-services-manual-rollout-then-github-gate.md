# Platform Services: Manual Rollout, Fresh OS Reset, Then GitHub Gate

## Summary

This document fixes the rollout strategy for platform services. First, we
manually validate the full service rollout cycle from the control node
through Ansible. After all needed services are proven, we reinstall OS on all
VPS nodes and repeat the verified process through GitHub Actions with
Environment approvals.

## Terminology

`state.csv` stores desired state only:

```text
present
absent
purged
```

`plan` is never a `state.csv` value. It is only a runner/workflow command.

Current CLI runners stay unchanged:

```bash
tools/services/service.sh edge_haproxy plan
tools/services/service.sh edge_haproxy apply
```

Future GitHub workflow input must be named `command`, not `action`:

```text
command=plan|apply|absent|purge
```

The workflow will pass `inputs.command` as the second argument to the existing
service runner.

## Manual Validation Phase

Manual validation is temporary but intentional. It is used to discover and fix
real Ansible, Docker, network, volume, and config issues before we encode the
process into GitHub.

For every platform service:

1. Keep the service in `state.csv` as `absent` while preparing files.
2. Run sync and inspect the automatic service plan.
3. Change the service to `present` only when ready to start it.
4. Run sync again and inspect the service plan.
5. Run a dry check from the control node:

   ```bash
   tools/services/service.sh <service> apply --limit <alias> --check
   ```

6. Run the real apply explicitly:

   ```bash
   tools/services/service.sh <service> apply --limit <alias>
   ```

7. Run the acceptance checks for that service.
8. Document fixes found during the manual rollout.

Initial services:

- `edge_haproxy`;
- `vpn_edge`;
- later monitoring, backup, security and other platform services.

Destructive commands are explicit. Test `absent` only where safe. Test `purge`
only with explicit confirmation and only when service data can be destroyed.

## Fresh OS Reset Phase

After manual validation of all required services:

1. Reinstall OS on all VPS nodes.
2. Run bootstrap again from operator files.
3. Run sync, inventory generation and verify.
4. Keep manual fixes out of the servers; fold them back into scripts, Ansible
   roles or operator inputs first.

This phase proves the platform can be rebuilt from the repository plus ignored
operator-local state.

## GitHub-Gated Phase

After the fresh OS reset succeeds, implement GitHub Actions rollout for
platform services.

Future workflow inputs:

```text
service=edge_haproxy|vpn_edge|vpn_cascade|...
command=plan|apply|absent|purge
limit=vps1|vps2|vps3
check=true|false
```

Rules:

- `vpn_cascade` follows the same gated command model, but remains separate from
  public HAProxy routes and controlled routing enforcement.
- `command=plan` is read-only and may use a lighter gate.
- `command=apply|absent|purge` must use GitHub Environment approval for
  production-changing targets, for example `vps1-prod`.
- The workflow runs the service runner on the control node, not directly on
  every VPS.

Bootstrap, emergency sync and inventory repair may remain operator-local even
after GitHub-gated rollout exists.

## Acceptance Criteria

- All required services have passed manual apply and acceptance checks.
- All manual fixes have been moved into code, Ansible roles or operator files.
- Fresh OS reset can rebuild VPS nodes without manual server edits.
- GitHub workflow repeats the same verified runner commands.
- No documentation or workflow uses `state=plan`.
