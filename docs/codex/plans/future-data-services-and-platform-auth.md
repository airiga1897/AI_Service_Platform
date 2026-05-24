# Future plan: data services and platform auth

This document reserves the future platform layer for managed databases and
platform-level authorization. It is not part of the current edge/VPN rollout.

## Summary

Add `data_services` as a platform capability after `edge_haproxy` and
`vpn_edge` are proven. The first supported database service should be
PostgreSQL. MariaDB remains reserved until a concrete product needs it.

Separate product admin/auth from platform admin/auth:

- product admin/auth belongs to `AromaFlowAI` and `AI_E_Retail`;
- platform auth belongs to future platform control plane, Semaphore,
  monitoring, deploy actions, and audit.

## Proposed State Rows

Initial future shape:

```csv
service,postgres,postgres,vps1,,,absent
service,postgres_backup,backup,vps2,,,absent
service,mariadb,mariadb,,,,absent
service,platform_auth,platform_auth,,,,absent
```

`postgres` is the primary candidate for product runtimes. Each product runtime
should get its own database/schema/user boundary. Product apps should not share
one unmanaged database namespace.

`mariadb` is optional and should stay `absent` until a product explicitly
requires it.

`platform_auth` is reserved for future control-plane login, role-based access,
and audit. It should not replace product-specific Django/admin auth.

## Rollout Order

Recommended future order after current infrastructure is stable:

1. `edge_haproxy`;
2. `vpn_edge`;
3. `postgres`;
4. `postgres_backup` / backup policy;
5. `monitoring`;
6. `semaphore` / orchestration UI, if still desired;
7. product runtimes: `AromaFlowAI`, then `AI_E_Retail`;
8. `platform_auth` only when web control plane or shared platform UI appears.

## Build And Deploy Notes

Before GitHub Actions are enabled, product images may be built manually and
deployed by immutable `image_ref`. Avoid building product images directly on the
production runtime node unless there is no other practical option.

Data/app services should use Docker DNS names and network aliases by default.
Do not reserve manual static container IPs for `frontend`, `backend`,
`postgres`, `redis`, `monitoring`, `semaphore`, or product runtimes unless a
service becomes a real L3/L4 contract endpoint.

Final model remains:

- product repos build and publish images;
- platform repo deploys images and infrastructure.

## Safety Rules

- Do not store database passwords, dumps, or runtime `.env` values in git.
- Do not enable a shared database service before backup/restore expectations are
  clear.
- Do not mix `platform_auth` with product user/admin accounts.
- Do not make MariaDB part of the default rollout without a concrete dependency.
