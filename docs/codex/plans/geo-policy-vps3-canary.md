# GeoPolicy egress canary on VPS3

## Status

Policy implementation is present and the isolated marked transport milestone is
implemented in `codex/feature/aieretail09`, but production policy
is not applied. The canary remains blocked until the three currently available
non-RU transport gateways (`vps1`, `vps2`, `vps4`) and the first RU dataset are
explicitly accepted.

## Scope

The host policy on VPS3 classifies only new IPv4 flows from:

- `site_runtime`: `172.31.3.10/32`;
- VPN ingress after SecureNAT: `172.20.0.2/32`.

RU public destinations and special, management, Docker, VPN, and transport
networks retain the ordinary VPS3 route. Other public destinations use the
first healthy path in the accepted priority order. If every configured path
fails, only that scoped non-RU traffic is dropped.

Existing conntrack flows restore their original mark. Inbound HTTPS and VPN
replies therefore retain the ingress route and are not reclassified.

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
- `platform_router` owns the variable-length set of transport gateways and their pre-provisioned
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

The engine does not hard-code three paths: `egress.paths` is ordered and may
later grow or shrink. Each alias owns an explicit stable `route_mark` and
`route_table`; ranking changes only preference order and never reallocates them.
A single accepted path is valid but explicitly has no failover redundancy.
Default `auto` preserves the current receipt alias when it remains configured;
otherwise it selects the first path. Removing an alias therefore requires a
green replacement preflight, and rollback to that removed alias requires
temporarily restoring its accepted path contract.

## Acceptance sequence

First run only:

```powershell
.\tools\services\service_remote.ps1 geo_policy apply `
  -Limit vps3 `
  -Check
```

Accept only `changed=0`, `check_mode_mutations=false`, a valid nftables
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

Rollback:

```powershell
.\tools\services\service_remote.ps1 geo_policy rollback -Limit vps3
```
