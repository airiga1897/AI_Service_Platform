# Orchestration Standby And Manual Promotion

This runbook keeps orchestration failover explicit. There is no automatic
failover in v1: the operator prepares a candidate node and promotes it by
editing local `operator/state.csv` when needed.

## State Model

Add the standby VPS to `operator/nodes.csv`:

```csv
vps5,<vps5-host-or-ip>,ssh,
```

Keep it as an orchestration candidate while `vps3` remains active:

```csv
platform_role,orchestration,orchestration,vps3,vps5,,present
```

## Prepare Standby

`rollout_from_state` automatically prepares orchestration candidates after the
active orchestration sync. For example, when `vps5` is listed in
`candidate_aliases`, a normal rollout also refreshes the standby copy:

```powershell
.\tools\services\rollout_from_state.ps1
```

To skip this extra standby sync for an emergency or a known broken candidate:

```powershell
.\tools\services\rollout_from_state.ps1 -SkipStandbySync
```

WSL/Linux equivalent:

```bash
bash tools/services/rollout_from_state.sh --skip-standby-sync
```

The explicit helper remains available when only the standby should be refreshed:

```powershell
.\tools\bootstrap\prepare_orchestration_standby.ps1 -Alias vps5
```

WSL/Linux:

```bash
bash tools/bootstrap/prepare_orchestration_standby.sh --alias vps5
```

The helper validates that `vps5` exists in `nodes.csv` and is listed in
`candidate_aliases` for `platform_role,orchestration`. It then builds a temporary
promotion state, syncs operator files to `vps5`, prepares inventory there, and
verifies Ansible connectivity. The local `operator/state.csv` is not modified.

## Re-Bootstrap Candidate

If a standby candidate was already bootstrapped as a regular managed node, run
the bootstrap wrapper again after adding it to `candidate_aliases`. When
`root_password` is empty, the wrapper uses `operator/<alias>/admin_key`,
checks passwordless sudo, `/tmp`, required baseline commands, Ubuntu/apt support,
and package availability for management tools before making changes.

PowerShell:

```powershell
.\tools\bootstrap\bootstrap_from_windows.ps1 `
  -NodesFile .\operator\nodes.csv `
  -StateFile .\operator\state.csv `
  -Alias vps5
```

WSL/Linux:

```bash
bash tools/bootstrap/bootstrap_from_unix.sh \
  --nodes-file ./operator/nodes.csv \
  --state-file ./operator/state.csv \
  --alias vps5
```

If preflight fails, fix the reported prerequisite or reinstall the OS and run a
fresh root-password bootstrap. The wrapper keeps existing remote/local keys by
default; key regeneration remains explicit through `--regenerate-remote-keys`
and requires force for management-capable nodes.

The higher-level Windows bootstrap wrapper also understands this flow:

```powershell
.\tools\bootstrap\bootstrap_all_from_windows.ps1
```

It bootstraps nodes that still have `root_password`, and for existing remote
nodes referenced by `present` state rows it runs an admin-key re-bootstrap when
`operator/<alias>/admin_key` exists. This is intended to converge already
bootstrapped nodes without reinstalling the OS. Use `-SkipExistingRebootstrap`
when only fresh `root_password` bootstrap should run.

After adding a new orchestration candidate, run the higher-level wrapper before
preparing standby inventory:

```powershell
.\tools\bootstrap\bootstrap_all_from_windows.ps1
.\tools\bootstrap\prepare_orchestration_standby.ps1 -Alias vps5
```

The wrapper runs standby key preparation in one pass:

1. Ensure orchestration candidate keys exist for candidate aliases such as
   `vps5`.
2. Build an aggregate Ansible trust bundle from the base orchestration public
   key and every active/candidate orchestration public key that exists under
   `operator/<alias>/`.
3. Refresh the orchestration trust mesh on active and candidate orchestrators,
   including the current active node.
4. Re-bootstrap managed nodes with the same aggregate trust bundle.

The trust refresh appends missing public keys only. It does not remove, rotate,
or regenerate existing Ansible keys unless an explicit key-regeneration flow is
requested. During standby, active/candidate orchestrators and managed nodes may
therefore trust multiple orchestration Ansible public keys.

This lets the active orchestrator, standby candidates, and managed nodes verify
connectivity without replacing existing keys. It also lets a standby
orchestrator connect back to the old active orchestrator during
`prepare_orchestration_standby`.

## Manual Promotion

If the active orchestrator should move to `vps5`, edit local
`operator/state.csv`:

```csv
platform_role,orchestration,orchestration,vps5,,vps3,present
```

Then run:

```powershell
.\tools\services\rollout_from_state.ps1
```

The runner reads the local state, syncs to `vps5`, and future remote service
commands use `vps5` as the active orchestration node.

## Failure Case

If the old orchestrator is already unavailable, the same manual promotion flow
still works as long as the operator machine has current local state, operator
secrets, and SSH access to `vps5`.

Do not choose a new orchestrator automatically based on availability or latency.
The local operator files remain the source of truth during an incident.
