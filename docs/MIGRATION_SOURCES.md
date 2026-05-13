# Migration Sources

This document records which historical infrastructure assets may be reused in
AI Service Platform and which assets must stay out of this repository.

## Source Priority

1. `airiga1897/AromaFlowAI`, branch `codex/feature/new_infra02`
   - Primary source for cleaned platform-level drafts.
   - Use for Ansible roles, operations notes, deployment boundaries, and VPS
     layout.
2. `riga1897/SiteProject01`, branch `feature/siteproject01_newtask01`
   - Historical reference for mature MyPet01 infrastructure work.
   - Use as design input for HAProxy, Nginx, SoftEther, backup, CI/CD, and
     healthcheck behavior.
3. Local roadmap: `D:/Users/RGHome/OneDrive/Desktop/roadmap.md`
   - Architecture decision record for the three-VPS platform direction.
   - Use for priority and rollout order, not as executable source.

## Allowed To Migrate

- Platform Ansible roles: Docker, security, monitoring, backup client, backup
  server, management, and Semaphore.
- Edge routing patterns: HAProxy SNI routing, ACME bypass, rate limiting,
  blacklist handling, GeoIP lists, and stats endpoint.
- Site delivery ideas: future CDN in front of public websites for cache,
  filtering, and origin shielding. Do not use CDN as the default VPN transport.
- Shared GeoPolicy idea: one platform source for country/IP data that feeds
  HAProxy protection lists, VPN GeoDNS, egress policy, and CDN policy inputs.
  The active plan is documented in `CDN_GEO_POLICY.md`.
- Per-site Nginx proxy/static/media patterns.
- SoftEther VPN configuration contract, ports, volumes, TLS sharing, backup,
  restore, monitoring, and firewall requirements.
- Backup strategy: PostgreSQL dump, media/static volumes, `certbot_conf`,
  `softether_data`, local standby copy, S3-compatible offsite copy, and
  retention policy.
- CI/CD ideas: immutable GHCR image refs, Trivy scan, healthcheck, rollback
  metadata, manual deploy dispatch, and Telegram notifications.

## Not Allowed To Migrate

- Product source code from `SiteProject01`, `AromaFlowAI`, or `AI_E_Retail`.
- Django apps, migrations, templates, fixtures, demo media, generated
  `staticfiles`, logs, local `.env` files, or product test suites.
- Real IP addresses, private keys, tokens, passwords, real inventories, or
  unencrypted vault files.
- Hardcoded MyPet01 names as active platform names. Legacy names may appear only
  in migration notes for the current `aromaflow-work` runtime state.

## Execution Order

1. Preserve this source policy and the SoftEther VPN contract in docs.
2. Move reusable Ansible roles into `infra/ansible`.
3. Add generic edge templates for HAProxy, Nginx, and SoftEther.
4. Validate `services.yml` before any render or deploy work.
5. Render stack compose files from registry data.
6. Keep real deployment disabled until validation, render, healthcheck, and
   rollback dry-runs are reliable.
