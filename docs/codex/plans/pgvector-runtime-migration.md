# Controlled pgvector Runtime Migration

## Goal

Add pgvector to the existing PostgreSQL 16 cluster before creating the
AI_E_Retail database. The data volume, primary/standby roles, replication
slots, and service endpoint stay unchanged.

Status: completed on 2026-07-14. `vps4`, `vps9`, and `vps8` run the same
digest listed below. Both physical standbys are `streaming async`, and both
replication slots are active. Product database creation remains a separate
step.

Container restart and host reboot rehearsals completed sequentially in the
order `vps4`, `vps9`, `vps8`. Service routes, SoftEther transport, standby
reconnect, and active replication slots recovered without Ansible repair.
The retired `postgres:16-alpine` image IDs were then removed explicitly from
all three nodes; no broad image prune was used.

## Pinned Runtime

- Image tag used for discovery: `pgvector/pgvector:0.8.5-pg16-bookworm`
- Runtime pin: `pgvector/pgvector@sha256:eb2a451bbc37d71947fafac0bb76d2992c6aafb305942a708e0d6c567eb42985`
- Platform: `linux/amd64`
- PostgreSQL: `16.14`
- pgvector: `0.8.5`

The role validates the exact PostgreSQL version and the presence of
`vector.control` before replacing a running container. Per-alias image
overrides prevent an accidental primary-first migration.

## Ordered Migration

1. Set the pgvector image override for `vps4` only.
2. Apply `postgres_runtime` to `vps4` and confirm it returns as a streaming
   standby.
3. Add the same override for `vps9`, apply it, and confirm both standbys are
   streaming.
4. Add the override for `vps8`, apply it last, and confirm the primary and
   both replication slots are healthy.
5. Collapse the staged overrides into the canonical global image only after
   all three nodes use the same digest.
6. Create the AI_E_Retail role/database and run
   `CREATE EXTENSION IF NOT EXISTS vector` in that database.

Never create the extension while either standby still runs an image without
the pgvector shared library. Do not use `-ReinitStandby` for this migration.

## Acceptance Per Node

- Container image matches the pinned digest.
- `SHOW server_version` returns `16.14`.
- `vector` is present in `pg_available_extensions`.
- Standby nodes remain in recovery and return to `streaming async`.
- After the primary migration, `pg_stat_replication` contains both
  `ai_sp_vps4` and `ai_sp_vps9`, and both slots are active.
