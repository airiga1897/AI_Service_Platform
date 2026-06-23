# Future plan: operator state node retirement tool

Этот план описывает будущий верхнеуровневый инструмент для безопасного вывода VPS из
operator state. Сейчас удаление узла выполняется вручную через `operator/state.csv`,
`operator/nodes.csv`, `operator/networks.csv`, allowlists и последующую регенерацию
inventory. Цель инструмента - убрать ручное редактирование связей вроде
`vps3>vps5+vps5>vps4` и не допускать dangling references.

## Problem

`operator/state.csv` хранит несколько типов ссылок на alias:

- `service` rows: active/candidate/old aliases конкретного сервиса.
- `edge_route` rows: active aliases маршрутов HAProxy.
- `platform_role` rows: active/candidate/old platform roles.
- `cascade_topology` rows: active/candidate/old links вида `source>target`.

При удалении VPS важно сначала убрать его из active topology и service placement, а
только потом удалять alias из `nodes.csv`. Иначе генерация inventory или rollout может
сломаться, либо хуже - пройти пустым запуском, если inventory stale.

## Proposed Tools

Добавить отдельные команды в `tools/operator_state/`:

```powershell
tools\operator_state\cascade_link.ps1 remove -From vps3 -To vps5
tools\operator_state\cascade_link.ps1 add -From vps1 -To vps5
tools\operator_state\retire_node.ps1 vps3
tools\operator_state\purge_node.ps1 vps3 -BackupDir .tmp\operator-purge
```

И Unix equivalents:

```bash
bash tools/operator_state/cascade_link.sh remove --from vps3 --to vps5
bash tools/operator_state/retire_node.sh vps3
bash tools/operator_state/purge_node.sh vps3 --backup-dir .tmp/operator-purge
```

## Command Behavior

`cascade_link remove`:

- removes exact `from>to` from `cascade_topology.active_aliases`;
- optionally moves the removed link to `old_aliases`;
- fails if the link is not present unless `--ignore-missing` is set;
- validates that both aliases still exist in `nodes.csv`, unless the removed link is
  already only in `old_aliases`.

`cascade_link add`:

- adds exact `from>to` to `cascade_topology.active_aliases`;
- fails if either alias is absent from `nodes.csv`;
- fails if either endpoint is not active for `service,vpn_cascade`;
- fails on duplicate links;
- does not create SoftEther secrets automatically.

`retire_node`:

- removes the node alias from all `active_aliases` and `candidate_aliases`;
- removes all `alias>peer` and `peer>alias` links from active/candidate
  `cascade_topology`;
- moves removed service aliases and topology links to `old_aliases` by default;
- removes the alias from `edge_route` active aliases;
- keeps the alias in `nodes.csv` and `networks.csv`;
- prints the exact follow-up rollout/check commands.

`purge_node`:

- requires the alias to be absent from all active/candidate state fields;
- allows historical `old_aliases`, but should offer `--drop-old-references`;
- backs up `operator/<alias>` before deleting or moving secret material;
- removes the alias from `nodes.csv` and `networks.csv`;
- removes node endpoint IPs from management allowlists when they are marked as node
  endpoints;
- refuses to run if active cascade topology still mentions the alias.

## Safety Checks

Every command should run these checks before writing:

- `state.csv` header matches the expected schema.
- Alias names are exact tokens split by `+`; substring matches are forbidden.
- Cascade links are exact tokens split by `+` and must match `source>target`.
- Active/candidate aliases must exist in `nodes.csv`.
- Active/candidate topology link endpoints must exist in `nodes.csv`.
- `old_aliases` may reference a retired alias only after a warning.
- The resulting state must allow `tools/bootstrap/create_inventory.sh` to complete.

Every command should run these checks after writing:

```powershell
bash tools/bootstrap/create_inventory.sh `
  --nodes-file operator/nodes.csv `
  --state-file operator/state.csv `
  --output .tmp/inventory-check.ini

git diff --check
```

On Windows, the tool may use Git Bash explicitly when WSL bash is unavailable.

## Desired Retirement Flow

For a node such as `vps3`:

1. Remove active cascade links:

   ```powershell
   tools\operator_state\retire_node.ps1 vps3
   ```

2. Review the generated diff and run service checks for affected services.

3. Apply affected services so no runtime component still depends on the retired node.

4. Confirm there are no active references:

   ```powershell
   rg "vps3" operator
   ```

   Historical docs and archived probe history are allowed; active inputs are not.

5. Purge the node from operator address books and secure material:

   ```powershell
   tools\operator_state\purge_node.ps1 vps3 -BackupDir .tmp\operator-purge
   ```

6. Regenerate remote inventory through `service_remote.ps1` or the bootstrap inventory
   command on the control node.

## Non-Goals

- The tool must not execute long remote rollout commands automatically.
- The tool must not create or rotate SoftEther secrets automatically.
- The tool must not delete provider VPS instances.
- The tool must not remove historical docs or archived probe logs.

## Acceptance Criteria

- Removing a node from cascade topology no longer requires manual string editing.
- Active/candidate references to missing aliases fail loudly.
- `old_aliases` references to already purged aliases warn and skip during inventory
  generation.
- `service.sh` preflight prevents silent zero-host rollout.
- `purge_node` creates a backup of `operator/<alias>` before removing secure material.
