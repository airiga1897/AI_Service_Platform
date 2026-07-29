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
Windows hosts: mycleanbot.mine-craft.su -> 172.22.254.10
  -> operator VPN on VPS1
  -> softether-edge 172.22.254.2
  -> ai_service_vpn_policy
  -> mycleanbot-private-ingress 172.22.254.10:443
  -> ai_service_app_vps1
  -> mycleanbot-route 172.31.1.10:8000
  -> mycleanbot-web
```

`mycleanbot-private-ingress` has no `ports` mapping. It uses a pinned
linux/amd64 Nginx digest, mounts an existing certificate read-only and accepts
requests only from loopback and the approved `softether-edge` policy address.
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
2. Confirm the exact VPN policy subnet `172.22.254.0/24` and that
   `172.22.254.10` is unused.
3. Confirm no public MyCleanBot HAProxy route exists.
4. Prepare the DNS-01 certificate without adding a public A/AAAA record.
5. Take a read-only inventory of the existing VPN, Docker networks, containers
   and listeners.
6. Obtain explicit approval for the VPS change.

## Approved apply sequence

After that approval:

1. Re-enable `ai_service_vpn_policy` only on VPS1 through the existing
   `vpn_edge` role. Expected `softether-edge` address is `172.22.254.2`.
2. Apply `infra/ansible/mycleanbot_vpn_access.yml` with:

   ```text
   mycleanbot_vpn_access_change_approved=true
   ```

3. Verify the ingress container uses the pinned digest, has no published ports,
   owns only `172.22.254.10` on the policy network and can reach only the local
   MyCleanBot backend contract through the app network.
4. On the Windows operator workstation, add one administrator-managed line:

   ```text
   172.22.254.10 mycleanbot.mine-craft.su
   ```

   Use the tracked helper so unrelated hosts entries are preserved:

   ```powershell
   .\tools\mycleanbot\manage_hosts.ps1 plan
   # elevated PowerShell after reviewing plan output
   .\tools\mycleanbot\manage_hosts.ps1 apply
   .\tools\mycleanbot\manage_hosts.ps1 verify
   ```

5. The helper flushes the Windows DNS cache. With VPN connected, verify the certificate and
   `/ingress-livez`. With VPN disconnected, confirm that `172.22.254.10` is
   unreachable.
6. Verify PostgreSQL tenant isolation, backup and scratch restore rehearsal.
7. Stop and request the separate first-rollout confirmation.

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
`.\tools\mycleanbot\manage_hosts.ps1 remove`. It does not remove the VPN edge,
policy network, application, PostgreSQL or backup data.

First product rollout rollback stops only `mycleanbot-web` and
`mycleanbot-worker` when no previous digest exists. Schema rollback and restore
remain separate, stopped-writer procedures requiring new explicit approval.
