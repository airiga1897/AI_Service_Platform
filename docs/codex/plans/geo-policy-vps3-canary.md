# GeoPolicy egress canary on VPS3

## Status

Policy implementation is present and the isolated marked transport milestone is
implemented in `codex/feature/aieretail09`, but production policy
is not applied. The canary remains blocked until the three currently available
non-RU transport gateways (`vps1`, `vps2`, `vps4`) and the first RU dataset are
explicitly accepted.

## Scope

The policy inside the `platform-router` network namespace classifies only new
IPv4 flows from:

- `site_runtime`: `172.31.3.10/32`;
- VPN ingress on the isolated policy handoff: `172.22.252.2/32`.

RU public destinations and special, management, Docker, VPN, and transport
networks retain the ordinary VPS3 route. Other public destinations use the
first healthy path in the accepted priority order. If every configured path
fails, only that scoped non-RU traffic is dropped.

AI_E_Retail reaches the router at `172.31.3.2`; `softether-edge` reaches it at
`172.22.252.4`. The router is not attached to the common `172.20.0.0/24` edge
network. Existing conntrack flows restore their original mark. Inbound HTTPS
and VPN replies therefore retain connected ingress routes and are not
reclassified.

## Contracts

- `operator/geo_policy/config.yml` is the accepted, secret-free operator intent.
- The config records an explicit, dated receipt linking each observed egress
  country code to the official OpenAI supported-country list; runtime also
  requires the live country to remain equal to that accepted code.
- `operator/geo_policy/data/ru_ipv4.cidrs` is generated from the aggregated
  IPdeny RU IPv4 list.
- `operator/geo_policy/data/ru_ipv4.json` records source, RIPE coverage,
  SHA-256, prefix/address counts, fetch time, and the last-known-good chain.
- `/opt/ai-service-platform/geo_policy/current.json` is the VPS3 runtime receipt.
- `/var/lib/ai-service-platform/platform_router/current.json` is the accepted
  transport receipt that GeoPolicy must match before every check or apply.
- `platform_router` owns both source gateways and the variable-length set of
  transport gateways and their pre-provisioned
  route-mark/table contracts. GeoPolicy owns destination classification and
  active-path selection.

The first dataset requires `-AcceptInitial`. Later datasets must retain at least
90% RIPE RU allocation coverage, remain within a 20% address-count delta, and
chain back to the explicitly accepted root SHA. A dataset older than 72 hours
is reported as degraded and remains in service as last-known-good.

## Failover

- Probe interval: 15 seconds.
- Switch after three consecutive failures.
- Every configured path is checked for non-RU country and OpenAI reachability.
- Return to the highest-priority recovered path after five successful probes and at least five minutes
  since the last switch.
- The active nftables table is replaced as one transaction.
- `-GeoPolicyActivePath <alias>` is the manual override; `blocked` is
  entered only by the automatic fail-closed state machine.
- `rollback` restores the active path from the previous receipt.

OSPF and BGP are not part of this canary.

## Manual preparation

Run these locally; the network downloads and remote commands are intentionally
operator-driven:

```powershell
Copy-Item `
  .\operator\geo_policy\config.yml.example `
  .\operator\geo_policy\config.yml

python .\tools\geo_policy\prepare_transport_secrets.py

.\tools\geo_policy\refresh_dataset.ps1 -AcceptInitial

python -m tools.geo_policy.collect_candidates `
  --aliases vps1,vps2,vps4 `
  --output .\operator\geo_policy\egress-ranking.proposal.json
```

Copy the generated root SHA, exact proposal ID, accepted aliases, gateways,
route marks, and route tables into `config.yml`. Change `state` to `accepted`
only after reviewing them.

Before GeoPolicy preflight, `platform_router` must have provisioned and accepted:

- first-ranked table `5301` with the accepted default gateway and rule for mark
  `0x530003`;
- second-ranked table `5302` with the accepted default gateway and rule for mark
  `0x530004`;
- third-ranked table `5303` with the accepted default gateway and rule for mark
  `0x530005`;
- return paths and egress NAT on all remote gateways.

Every configured source path is permanent desired state inside the router
namespace. Its fwmark rule and an
`unreachable default metric 32767` fallback remain installed even while the
SoftEther NIC is reconnecting. A live tunnel adds only the preferred default
route with metric `10`; losing the NIC removes that preferred route without
allowing marked traffic to fall through to either the router main table or the
VPS3 host main table. No GeoPolicy fwmark rules or policy tables are installed
on the host. Reconciliation
deletes a rule or table only after its alias is removed from the operator
contract. A transport receipt is written only after the live marked lookup from
`172.31.3.2` selects the expected tunnel.

The engine does not hard-code three paths: `egress.paths` is ordered and may
later grow or shrink. Each alias owns an explicit stable `route_mark` and
`route_table`; ranking changes only preference order and never reallocates them.
A single accepted path is valid but explicitly has no failover redundancy.
Default `auto` preserves the current receipt alias when it remains configured;
otherwise it selects the first path. Removing an alias therefore requires a
green replacement preflight, and rollback to that removed alias requires
temporarily restoring its accepted path contract.

The shared VPS3 namespace is rolled out cumulatively. The canonical operator
entrypoint coordinates target router servers, target HAProxy publication, the
source router clients and the final mutation-free GeoPolicy acceptance:

```powershell
.\tools\geo_policy\rollout_transport.ps1 `
  -EgressPaths 'vps1+vps2+vps4' `
  -TargetAliases 'vps2,vps4' `
  -Check
```

After that preflight is accepted, run the same command without `-Check`. It
performs per-step checks, stops at the first failure, and ends with GeoPolicy
check mode; it never performs production GeoPolicy apply. `TargetAliases` is
the subset being introduced or repaired, while `EgressPaths` is the cumulative
desired selector, so the workflow supports adding or removing transport nodes
without assuming there are always three.

The individual commands below are diagnostic/manual recovery primitives, not
the canonical rollout. The path selector grows while each remote target is
limited independently:

```powershell
.\tools\services\service_remote.ps1 platform_router apply `
  -Limit vps1,vps3 -PlatformRouterEgressPaths vps1 -Check

.\tools\services\service_remote.ps1 platform_router apply `
  -Limit vps2,vps3 -PlatformRouterEgressPaths vps1+vps2 -Check

.\tools\services\service_remote.ps1 platform_router apply `
  -Limit vps4,vps3 -PlatformRouterEgressPaths vps1+vps2+vps4 -Check
```

Each real apply uses the same limit and cumulative selector only after its
matching check is accepted. Omitting the selector means all configured paths
and is reserved for final steady-state reconciliation.

The public SNI route is a transport dependency, not a post-rollout concern. A
target `platform_router` server may listen successfully on `443` while public
clients still time out because HAProxy has not accepted its backend network and
SNI. The orchestrator therefore applies target `edge_haproxy` before starting
source client acceptance. Source diagnostics use distinct safe phases for an
unavailable public transport, detected authentication failure and a session
that otherwise failed to establish.

For `edge_route,softether_l3_vps` only, HAProxy publishes both active and
candidate aliases. A candidate transport must be publicly reachable before it
can be accepted, so limiting this route to active aliases creates an impossible
promotion dependency. Candidate handling is not extended to VPN ingress,
Minecraft, or other edge routes, and `old_aliases` are never published. Target
acceptance requires the dedicated HAProxy backend to report `UP` and a local
SNI/TLS handshake to succeed before source clients are reconciled.

All client links in the shared VPS3 namespace must be accounts and NICs of one
SoftEther client daemon, as required by ADR 0009. Running one client container
per link makes every daemon compete for the same local `localhost:5555` control
endpoint and can disconnect the pre-existing PostgreSQL transport. The
multi-account migration is accepted only when the resolved client account count
is four, PostgreSQL readiness is restored, and all three egress paths still pass.
GeoPolicy production apply remains blocked until then.

Each account is configured for startup and repeated reconnect on every real
transport reconciliation, including accounts that already exist in persistent
client state. `AccountConnect` is asynchronous, so the temporary creation of a
NIC is not acceptance: `AccountStatusGet` must report an established session
before the interface address and marked-route verification are accepted. A real
`platform_router apply` currently changes timestamp-tagged local image refs and
recreates the shared client stack; this is an expected planned interruption of
all accounts, unlike a check-only run.

## Acceptance sequence

First run only:

```powershell
.\tools\services\service_remote.ps1 geo_policy apply `
  -Limit vps3 `
  -Check
```

Before that preflight, prepare the common source gateway with:

```powershell
.\tools\geo_policy\rollout_gateway.ps1 -Mode Check
.\tools\geo_policy\rollout_gateway.ps1 -Mode Apply
```

`Apply` leaves GeoPolicy itself in check mode. It connects `platform-router` to
the isolated VPN policy network after canonical `vpn_edge` has created that
network and attached `softether-edge`, continuously reconciles both source
defaults, installs the host direct-egress guard, and updates scoped FORWARD/SNAT
for the new VPN identity on each accepted target (`vps1,vps2,vps4` by default).

Accept GeoPolicy check only with `changed=0`, `check_mode_mutations=false`, a valid nftables
candidate, current or explicitly tolerated degraded dataset status, and green
country/OpenAI probes for every configured path.

Real apply requires a separate confirmation. After it, verify:

1. RU and special destinations leave directly through VPS3.
2. OpenAI and another non-RU destination leave through the first-ranked path.
3. The same behavior holds for a VPN client connected to VPS3.
4. Public HTTPS, `/healthz/`, `/readyz/`, background work, and PostgreSQL audit
   remain green.
5. Failure switches to the next healthy ranked path only after three probes.
6. Recovery of a higher-priority path waits for five successes and the
   five-minute hold.
7. Failure of all configured paths blocks only scoped non-RU traffic.

Remove only GeoPolicy while preserving both gateways:

```powershell
.\tools\services\service_remote.ps1 geo_policy rollback -Limit vps3
```

Explicitly roll back the gateway and restore Docker defaults only when required:

```powershell
.\tools\geo_policy\rollout_gateway.ps1 -Mode Rollback
```
