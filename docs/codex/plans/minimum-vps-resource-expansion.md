# Minimum VPS Resource Expansion

## Goal

Prepare separate database, application, and orchestration pools before the
first `site_runtime` deployment. Provider operations are manual; this document
defines their order and acceptance contract.

## Target Profiles

| Alias | Assignment | Target |
| --- | --- | --- |
| `vps8` | PostgreSQL primary | 2 vCPU, 4 GB RAM, 50 GB disk |
| `vps4` | PostgreSQL standby | 2 vCPU, 4 GB RAM, 30 GB disk |
| `vps9` | PostgreSQL standby | keep 2 vCPU, 4 GB RAM, 50 GB disk |
| `vps3` | AI_E_Retail | 2 vCPU, 4 GB RAM, 40 GB disk |
| `vps7` | AromaFlow | 2 vCPU, 2 GB RAM, 30 GB disk |
| `vps2` | TravellTickets | keep 2 vCPU, 2 GB RAM, 20 GB disk |
| `vps5`, `vps6` | orchestration | keep current profiles |
| `vps1` | relocation candidate | no expansion or durable role |

Product workloads are prohibited on database nodes. Mandatory edge/VPN and
`platform_router` services remain present.

## Operator Sequence

1. Record backup status, replication, capacity, containers, and networks.
2. Resize `vps4`; confirm it returns as a streaming standby.
3. Resize `vps8`; confirm it returns as primary with both standbys streaming.
4. Confirm `vps9` already matches its target.
5. Resize `vps3`; remove only reviewed retired objects, never volumes blindly.
6. Resize and inspect `vps7` using the same rules.
7. Verify `vps2`; do not resize it initially.
8. Implement `site_runtime`, then activate product placement in operator config.

Long PowerShell commands and provider operations are operator-run. Never resize
primary and standby database nodes concurrently.

## Acceptance

- SSH, passwordless sudo, Docker, edge/VPN containers, and networks survive.
- No `vpn_cascade` or `softether_p2p` runtime returns.
- `vps8` is not in recovery; `vps4` and `vps9` are in recovery.
- `ai_sp_vps4` and `ai_sp_vps9` are `streaming`, `async` on `vps8`.
- `P2PPgPrimaryVps8` and the controlled PG overlay are unchanged.
- Database disk usage has a 70% warning requirement.
- Optional swap is limited to 1-2 GB with low swappiness.
- Promotion of `vps4` requires a capacity gate covering current primary data,
  retained WAL, and operating headroom; expand it when the gate fails.

## Next Step

Deploy AI_E_Retail to `vps3` from an immutable GHCR digest with the manual
generic `site_runtime` flow. Prove idempotency, upgrade, rollback, reboot
recovery, and placement validation before GitHub CD.
