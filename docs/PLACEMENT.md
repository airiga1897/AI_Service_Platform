# Service Placement Policy

Physical aliases such as `vps1`, `vps2`, and `vps9` identify nodes. They do not
encode production, preproduction, application, database, or failover roles.

## Sources Of Truth

Use placement inputs in this order:

1. `operator/state.csv` defines current platform roles, service placement,
   candidates, retired aliases, and lifecycle state.
2. Service-specific operator config defines topology within the aliases selected
   by `state.csv`.
3. `operator/nodes.csv` is an address book only.

Do not infer placement from an alias number, provider, country, an old bootstrap
target name, or a historical plan. In particular, `vps1` does not mean
production and `vps2` does not mean preproduction.

The `runtime_instances.*.deploy.environments.*.vps` fields currently present in
`services.yml` belong to the legacy GitHub predeploy milestone. They are not the
desired-state source for new application placement. The deploy tooling must be
migrated to role/service-based placement before product rollout is enabled.

## Current Infrastructure Boundaries

The current design direction is:

- `vps4`, `vps8`, and `vps9`: PostgreSQL cluster nodes. Product web, worker,
  nginx, and Redis workloads must not be placed there after the database pool is
  normalized.
- `vps6`: active orchestration node; `vps5`: orchestration candidate. Product
  runtimes do not run on the control-plane pair.
- `vps3`: application-pool target for AI_E_Retail after sizing to 2 vCPU,
  4 GB RAM, and 40 GB disk.
- `vps7`: application-pool target for AromaFlow after sizing to 2 vCPU,
  2 GB RAM, and 30 GB disk.
- `vps2`: application-pool target for TravellTickets. Its current 2 vCPU,
  2 GB RAM, and 20 GB disk profile is the initial minimum.
- `vps1`: relocation/replacement candidate because of current latency; do not
  assign a new durable application role until that migration is decided.

These bullets are planning constraints, not runtime desired state. A placement
becomes active only after it is represented in operator state/config and rolled
out explicitly.

## Minimum Node Profiles

| Pool | Alias | Workload | Minimum profile |
| --- | --- | --- | --- |
| database | `vps8` | PostgreSQL primary | 2 vCPU, 4 GB RAM, 50 GB disk |
| database | `vps4` | PostgreSQL standby | 2 vCPU, 4 GB RAM, 30 GB disk |
| database | `vps9` | PostgreSQL standby | 2 vCPU, 4 GB RAM, 50 GB disk |
| application | `vps3` | AI_E_Retail | 2 vCPU, 4 GB RAM, 40 GB disk |
| application | `vps7` | AromaFlow | 2 vCPU, 2 GB RAM, 30 GB disk |
| application | `vps2` | TravellTickets | 2 vCPU, 2 GB RAM, 20 GB disk |
| orchestration | `vps6` | active controller | current profile |
| orchestration | `vps5` | standby controller | current profile |

`vps1` has no new durable role until relocation. Product nginx, web, worker,
scheduler, and Redis containers are prohibited on database nodes. Mandatory
edge/VPN services and the database overlay remain there.

Provider resize is an operator action. Resize database nodes one at a time:
standby `vps4`, then primary `vps8`, verifying replication after each return.
Database disk monitoring must warn at 70% usage. Until monitoring owns that
rule, it remains an acceptance check rather than an unmanaged host cron job.
A 1-2 GB emergency swap with low swappiness is allowed on 4 GB nodes, but is
not counted as workload memory.

Because `vps4` has a smaller disk than `vps8` and `vps9`, promotion preflight
must compare its available space with primary data, retained WAL, and operating
headroom. Expand `vps4` before promotion when that capacity gate fails.

## Application Placement Rules

- Place nginx, web, workers, scheduler, and the runtime-specific Redis instance
  in the same application failure domain unless a measured scaling requirement
  justifies another split.
- Keep PostgreSQL on database-pool nodes. Applications reach the current primary
  through a controlled `platform_router` service endpoint.
- Redis ownership is per runtime instance, not per VPS and not platform-global.
- Public exposure is a separate `edge_route` decision; deploying a runtime does
  not publish it automatically.
- Prefer application nodes with low measured latency to the database primary,
  but do not sacrifice database failure isolation merely to remove one network
  hop.

## Historical Documents

Documents under `docs/adr`, `docs/cursor`, `docs/replit`, and older numbered
plans record decisions or milestones at the time they were written. Their fixed
VPS mappings are historical evidence, not current placement instructions. When
they conflict with this policy or current operator state, this policy and the
operator sources of truth win.
