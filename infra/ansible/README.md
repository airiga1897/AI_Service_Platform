# Platform Ansible Drafts

These roles were selectively migrated from `AromaFlowAI` branch
`codex/feature/new_infra02`.

## Current State

- `docker`, `security`, `monitoring`, `management`, and `semaphore` are
  platform-level roles.
- `backup_client` and `backup_server` are reusable drafts, but still contain
  legacy MyPet01/AromaFlowAI assumptions in some templates.
- The old `mypet01` application deploy role was intentionally not migrated as
  an active role. Stack deployment should be regenerated from `services.yml`.

## Before Real Provisioning

- Replace hardcoded compose project names, database users, container names, and
  domain names with values rendered from `services.yml`.
- Generate `inventory.ini` from GitHub Environments, Ansible Vault, or local
  operator input. Do not commit real inventories.
- Keep SoftEther VPN backup and restore in scope: `softether_data`,
  `softether_logs`, certificate copies, and HAProxy VPN routing are platform
  data.
