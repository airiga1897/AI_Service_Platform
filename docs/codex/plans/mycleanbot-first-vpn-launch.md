# MyCleanBot first VPN-only launch

## Scope

This plan finishes only the first MyCleanBot production launch. Monitoring
implementation is deferred to the shared platform-wide monitoring plane.
MyCleanBot keeps its required health, heartbeat, PostgreSQL and backup signals
as a product contract, but does not own Prometheus, Grafana or exporters.

No step in this plan creates a public web route, opens a public listener, merges
a pull request or performs the first product rollout without its explicit gate.

## Access path

The bootstrap access path is:

```text
Windows hosts: mycleanbot.mine-craft.su -> 172.31.1.11
  -> l3-vps1.mine-craft.su:443 / MyCleanBotOperatorVps1
  -> routed TAP 10.89.1.0/24
  -> platform-router allowlist
  -> mycleanbot-private-ingress 172.31.1.11:443
  -> ai_service_app_vps1
  -> mycleanbot-route 172.31.1.10:8000
  -> mycleanbot-web
```

`mycleanbot-private-ingress` has no `ports` mapping. It uses a pinned
linux/amd64 Nginx digest, mounts an existing certificate read-only and accepts
requests only from loopback and the isolated `10.89.1.0/24` operator hub.
The hub has no default route and DHCP pushes only `172.31.1.11/32`.
The worker still has no published port.

The current public DNS state must not be confused with publication. On
2026-07-29, `mycleanbot.mine-craft.su` already resolved as a CNAME to
`vps1.mine-craft.su`. The record predates this change. Public TCP/443 is the
existing VPN ingress and did not complete a TLS handshake for the MyCleanBot
SNI. Do not add a MyCleanBot HAProxy/backend route. Decide separately whether
to remove the existing CNAME; the Windows hosts entry overrides it while VPN
access is being bootstrapped.

## Certificate

The certificate must cover `mycleanbot.mine-craft.su`. Because no public HTTP
route is allowed, issuance and renewal use DNS-01. The authoritative zone is
currently served by REG.RU name servers.

The access role deliberately does not own DNS credentials or certificate
issuance. Use an existing suitable certificate or an explicitly approved
DNS-01 procedure. Never place a DNS API token, private key or challenge
credential in Git, command output or GitHub job summaries.

Expected protected paths on VPS1:

```text
/etc/letsencrypt/live/mycleanbot.mine-craft.su/fullchain.pem
/etc/letsencrypt/live/mycleanbot.mine-craft.su/privkey.pem
```

## Pre-apply gate

Before any VPS change:

1. Reconcile the trusted VPS1 host key on the active orchestration node from
   operator-owned pinned material. `ssh-keyscan` is forbidden.
2. Confirm that `10.89.1.0/24`, `172.27.1.0/24`, `172.29.1.0/24` and
   `172.31.1.11` do not overlap existing routes or endpoints.
3. Confirm VPS1 disk and available-memory headroom, then plan the
   `host_resources` transition from 512 MiB to 1024 MiB swap with
   `vm.swappiness=10`.
4. Confirm no public MyCleanBot HAProxy route exists.
5. Prepare the DNS-01 certificate without adding a public A/AAAA record.
6. Take a read-only inventory of the existing VPN, Docker networks, containers
   and listeners.
7. Obtain explicit approval for the VPS change.

## Approved apply sequence

After that approval:

1. Apply the reviewed VPS1 `host_resources` plan and verify `/swapfile`,
   `/etc/fstab`, active swap size and `vm.swappiness=10`.
2. Add the reviewed `l3-vps1` operator link, platform-router policy and
   HAProxy SNI fragments from
   `docs/examples/l3-vps1-mycleanbot.example.yml`.
3. Add `softether_l3_vps` service and edge-route desired state only on VPS1,
   then apply `softether_l3_vps`, `platform_router` and `edge_haproxy`.
4. Apply `infra/ansible/mycleanbot_vpn_access.yml` with:

   ```text
   mycleanbot_vpn_access_change_approved=true
   ```

5. Verify the ingress container uses the pinned digest, has no published ports,
   owns only `172.31.1.11` on the app network and can reach only the local
   MyCleanBot backend contract through the app network.
6. On the Windows operator workstation, add one administrator-managed line:

   ```text
   172.31.1.11 mycleanbot.mine-craft.su
   ```

   Use the tracked helper so unrelated hosts entries are preserved:

   ```powershell
   .\tools\mycleanbot\manage_hosts.ps1 plan
   # elevated PowerShell after reviewing plan output
   .\tools\mycleanbot\manage_hosts.ps1 apply
   .\tools\mycleanbot\manage_hosts.ps1 verify
   ```

7. The helper flushes the Windows DNS cache. With the `l3-vps1` operator hub
   connected, verify the certificate and `/ingress-livez`. With it disconnected,
   confirm that `172.31.1.11` is
   unreachable.
8. Verify PostgreSQL tenant isolation, backup and scratch restore rehearsal.
9. Stop and request the separate first-rollout confirmation.

## First rollout

After the separate rollout confirmation, manually dispatch only:

```text
instance=mycleanbot
environment=prod
image_ref=ghcr.io/airiga1897/mycleanbot@sha256:097e4b28afefa288475ec1ba91031c6cc02d03d1c40c10c9c070d6aad7fb4e87
```

Acceptance requires immutable digest evidence, migrations, `/livez`,
`/healthz`, fresh `telegram-supervisor` heartbeat, no worker port, no PostgreSQL
container, tenant-only database access and successful VPN-only HTTPS access.

## Rollback

Access rollback stops only `mycleanbot-private-ingress` and removes the single
managed Windows hosts line with
`.\tools\mycleanbot\manage_hosts.ps1 remove`. The routed hub and its one
platform-router policy are then removed from desired state without touching
the ordinary VPN ingress, application, PostgreSQL or backup data.

First product rollout rollback stops only `mycleanbot-web` and
`mycleanbot-worker` when no previous digest exists. Schema rollback and restore
remain separate, stopped-writer procedures requiring new explicit approval.
