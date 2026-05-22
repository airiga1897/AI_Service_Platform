# Step-by-step: VPN Edge First Service Rollout

This document describes the first real platform service rollout after infrastructure preparation.

Order:

1. Bootstrap VPS nodes from `nodes.csv`.
2. Sync `nodes.csv` and `state.csv` to the control/orchestration node.
3. Verify Ansible connectivity.
4. Complete GitHub deploy-access/predeploy-check.
5. Roll out the first service: `vpn_edge`.

Product deploy is still later.

## 1. Source Of Truth

VPN edge uses two operator-local files:

```text
operator/nodes.csv
operator/state.csv
```

`nodes.csv` describes VPS nodes and endpoints.

`state.csv` describes desired service state:

```csv
kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state
service,vpn_edge,vpn_edges,vps1+vps2+vps3,,,present
service,vpn_cascade,vpn_cascades,,,,absent
```

`vpn_edge` is the user VPN ingress service. Its seed config is the opaque
operator secret `operator/softether/edge/vpn_server.config`.

`vpn_cascade` is reserved for future site-to-site/cascade transport and is not rolled out now.
It must get a separate config/container/volume design before implementation.

## 2. Prepare Inventory

On the control node:

```bash
cd /opt/ai-service-platform

sudo bash tools/bootstrap/create_inventory.sh \
  --nodes-file /opt/ai-service-platform/operator/nodes.csv \
  --state-file /opt/ai-service-platform/operator/state.csv \
  --include vps1,vps2,vps3 \
  --check
```

Inventory should contain:

- `vps1`, `vps2`, `vps3` in `[vpn_edges]`;
- empty `[vpn_cascades]`, `[candidate_vpn_cascades]`, `[old_vpn_cascades]` groups until cascade rollout exists.

## 3. Plan

Windows/operator:

```powershell
.\tools\services\service.ps1 vpn_edge plan `
  -NodesFile .\operator\nodes.csv `
  -StateFile .\operator\state.csv
```

Control node/Linux:

```bash
bash tools/services/service.sh vpn_edge plan \
  --nodes-file /opt/ai-service-platform/operator/nodes.csv \
  --state-file /opt/ai-service-platform/operator/state.csv
```

`plan` does not change anything.

## 4. First Careful Apply

First target:

```text
vps1
```

Dry run:

```bash
bash tools/services/service.sh vpn_edge apply \
  --nodes-file /opt/ai-service-platform/operator/nodes.csv \
  --state-file /opt/ai-service-platform/operator/state.csv \
  --inventory /opt/ai-service-platform/inventory.ini \
  --limit vps1 \
  --check
```

Real apply:

```bash
bash tools/services/service.sh vpn_edge apply \
  --nodes-file /opt/ai-service-platform/operator/nodes.csv \
  --state-file /opt/ai-service-platform/operator/state.csv \
  --inventory /opt/ai-service-platform/inventory.ini \
  --limit vps1
```

After validating `vps1`, repeat for `vps2` and `vps3`.

## 5. Remove Model

Changing `state.csv` does not remove services automatically.

Stop/remove service without deleting data:

```bash
bash tools/services/service.sh vpn_edge absent \
  --nodes-file /opt/ai-service-platform/operator/nodes.csv \
  --state-file /opt/ai-service-platform/operator/state.csv \
  --inventory /opt/ai-service-platform/inventory.ini \
  --limit vps1
```

Delete stopped service data only with explicit confirmation:

```bash
bash tools/services/service.sh vpn_edge purge \
  --nodes-file /opt/ai-service-platform/operator/nodes.csv \
  --state-file /opt/ai-service-platform/operator/state.csv \
  --inventory /opt/ai-service-platform/inventory.ini \
  --limit vps1 \
  --confirm-purge
```

## 6. SoftEther Contract

SoftEther/VPN is a platform service, not part of `AromaFlowAI` or `AI_E_Retail`.
This rollout covers `vpn_edge` only; `vpn_cascade` remains reserved.

`vpn_server.config` is copied as an opaque edge seed. Ansible v1 must not parse
VirtualHUBs, users, groups, passwords, SecureNAT/DHCP, or certificates from it
and must not patch it with string replacements.

Current TCP-only contract:

| Port | Protocol | Purpose |
| --- | --- | --- |
| `443` | TCP | SSTP/SSL VPN through HAProxy SNI routing |
| `992` | TCP | Alternative SoftEther SSL endpoint |
| `1194` | TCP | OpenVPN-compatible TCP endpoint |
| `5555` | TCP | SoftEther Server Manager, allowlist only |

UDP is not enabled yet.

HAProxy publishes TCP ports externally. SoftEther stays inside Docker network and does not publish ports directly.

## 7. Acceptance Checklist

- `state.csv` contains `service,vpn_edge,...,present`.
- `state.csv` contains reserved `service,vpn_cascade,...,absent`.
- `create_inventory.sh --state-file` adds active VPN edge aliases to `[vpn_edges]`.
- `service vpn_edge plan` does not change anything.
- `service vpn_edge apply --limit vps1 --check` runs without destructive actions.
- `service vpn` is rejected.
- `service vpn_cascade` is rejected as reserved/not implemented.
- SoftEther container starts on the target node.
- Both existing VirtualHUBs from the opaque edge seed are still present.
- TCP ports `443`, `992`, `1194`, `5555` follow the edge contract.
- `vpn_server.config`, private keys, real IPs, passwords, and generated inventory are not committed.
