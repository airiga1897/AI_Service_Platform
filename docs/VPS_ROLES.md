# Platform Nodes, Roles And Service State

Platform uses two operator files:

- `nodes.csv` describes which VPS nodes exist and how to connect to them.
- `state.csv` describes which roles and services should be active on those nodes.

`vps1`, `vps2`, `vps3` are short operator aliases for the current scheme. They are not platform roles.

## Operator Files

Real operator files stay outside git:

```text
operator/nodes.csv
operator/state.csv
```

On the control/orchestration node they are synced to:

```text
/opt/ai-service-platform/operator/nodes.csv
/opt/ai-service-platform/operator/state.csv
```

Safe examples live in:

```text
infra/ansible/nodes.example.csv
infra/ansible/state.example.csv
```

## nodes.csv

Header:

```csv
current_alias,endpoint,connection,ansible_group,roles,root_password
```

Meaning:

- `current_alias` is a short node key, for example `vps1`.
- `endpoint` is operator-side DNS/IP and must not be committed with real values.
- `connection` is `ssh` for bootstrap from operator machine; `local` is only for control-node-local inventory.
- `ansible_group` is a fallback/default group for old flows.
- `roles` are basic node capabilities, for example `production+vpn-edge`.
- `root_password` is temporary bootstrap input and is cleared after successful bootstrap.

`root_password` is never copied to the control node in real form. Sync always sends sanitized `nodes.csv`.

## Reinstall Model

Reinstalling a VPS changes the physical node access keys, not the platform role by itself.

For one managed VPS reinstall:

- update only that alias row in operator-local `nodes.csv` with the fresh temporary `root_password`;
- run bootstrap for that alias with the existing control-node public key;
- let the runner refresh only `operator/<alias>/deploy_key` and `operator/<alias>/admin_key`;
- sync sanitized `nodes.csv` and `state.csv` back to the active orchestration node.

For an orchestration-node reinstall:

- bootstrap the active `orchestration` alias first;
- treat the old `operator/ansible_control.managed_nodes.pub` as obsolete;
- distribute the new Ansible control public key to managed nodes before relying on Ansible again.

`state.csv` should change only when the desired role/service placement changes. It is not edited just because an OS was reinstalled on the same alias.

## state.csv

Header:

```csv
kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state
```

Current example:

```csv
kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state
role,production,prod,vps1,,,present
role,preprod,backup,vps2,,,present
role,backup,backup,vps2,,,present
role,orchestration,management,vps3,,,present
role,monitoring,monitoring,vps3,,,present
service,vpn_edge,vpn_edges,vps1+vps2+vps3,,,present
service,vpn_cascade,vpn_cascades,,,,absent
```

Meaning:

- `kind=role` is a platform responsibility, for example `orchestration`.
- `kind=service` is an installable platform service, for example `vpn_edge`.
- `active_aliases` are where a role/service should be active now.
- `candidate_aliases` are nodes prepared for migration.
- `old_aliases` are previous nodes kept during rollback window.
- `state` is one of `present`, `absent`, `purged`.

Multiple aliases inside one field are separated with `+`.

## State Values

`present` means the role or service should exist.

`absent` means the service should not be active, but data is preserved. Real removal is explicit, for example `service vpn_edge absent`.

`purged` means service data may be deleted, but only by explicit command with confirmation, for example `service vpn_edge purge --confirm-purge`.

Changing CSV files does not automatically run destructive actions.

## Core Roles

- `management` is control tooling: Ansible, Semaphore, orchestration scripts, future control plane.
- `monitoring` is observability: Prometheus, Grafana, Loki, Alertmanager.
- `vpn_edges` is user VPN ingress through HAProxy/SoftEther.
- `vpn_cascades` is reserved for future site-to-site/cascade transport between VPS nodes.

`management` and `monitoring` can live on the same VPS now:

```csv
role,orchestration,management,vps3,,,present
role,monitoring,monitoring,vps3,,,present
```

Later monitoring can move without changing the control node:

```csv
role,orchestration,management,vps3,,,present
role,monitoring,monitoring,vps4,,,present
```

## Inventory Generation

`create_inventory.sh` takes:

- endpoint/connection from `nodes.csv`;
- active/candidate/old groups from `state.csv`.

For every safe `ansible_group` in `state.csv`, the generator creates:

```text
<group>
candidate_<group>
old_<group>
```

Group names must match:

```text
[a-z][a-z0-9_]*
```

Example:

```bash
sudo bash tools/bootstrap/create_inventory.sh \
  --nodes-file /opt/ai-service-platform/operator/nodes.csv \
  --state-file /opt/ai-service-platform/operator/state.csv \
  --include vps1,vps2,vps3
```

Expected result:

- `vps1` appears in `[prod]`;
- `vps3` appears in `[management]` and `[monitoring]`;
- `vps1`, `vps2`, `vps3` appear in `[vpn_edges]`;
- `vpn_cascades`, `candidate_vpn_cascades`, `old_vpn_cascades` exist even before rollout.

## VPN Edge Service

The current user-facing VPN service is `vpn_edge`, not generic `vpn`.
It is the SoftEther user ingress service behind HAProxy.

It is controlled by:

```csv
service,vpn_edge,vpn_edges,vps1+vps2+vps3,,,present
```

Check plan:

```bash
bash tools/services/service.sh vpn_edge plan \
  --nodes-file /opt/ai-service-platform/operator/nodes.csv \
  --state-file /opt/ai-service-platform/operator/state.csv
```

Apply carefully to one node:

```bash
bash tools/services/service.sh vpn_edge apply \
  --nodes-file /opt/ai-service-platform/operator/nodes.csv \
  --state-file /opt/ai-service-platform/operator/state.csv \
  --inventory /opt/ai-service-platform/inventory.ini \
  --limit vps1 \
  --check
```

Removal is explicit:

```bash
bash tools/services/service.sh vpn_edge absent --limit vps1
bash tools/services/service.sh vpn_edge purge --limit vps1 --confirm-purge
```

`vpn_edge` uses the operator-only opaque seed config:

```text
operator/softether/edge/vpn_server.config
```

The seed can contain multiple VirtualHUBs, users, groups, SecureNAT/DHCP, and
credentials. It is copied as state, not generated from Ansible variables.

`vpn_cascade` is documented in `state.csv` but rollout is not implemented yet.
It is reserved for future site-to-site/cascade transport and must use a separate
config/container/volume design.
