# Codex Plans

Эта папка разделяет основной порядок платформенных шагов и будущие/вспомогательные материалы.

## Основной порядок

1. [Control/orchestration node bootstrap](01-vps3-management-bootstrap.md) — fresh bootstrap, reinstall одного VPS, PuTTY host-key handling, sync `nodes.csv`/`state.csv`, inventory и проверка Ansible connectivity.
2. [GitHub Actions deploy access](02-github-actions-deploy-access-ai-retail-dev-preprod.md) — GitHub Environment/secrets/predeploy-check для `ai-retail-dev-preprod` как infrastructure/deploy-access слой, без product `pull/up`.
3. [VPN first service rollout](03-vpn-first-service-rollout.md) — SoftEther/VPN edge как первый настоящий platform service после infrastructure preparation, управляется строкой `service,vpn_edge,...` в `state.csv`.

## Термины порядка

- **Infrastructure preparation**: bootstrap, users/keys, Ansible, inventory, GitHub Environment и deploy-access precheck.
- **Platform service rollout**: VPN, edge, monitoring, backup, product runtimes.
- Первый service rollout: **SoftEther/VPN**.
- Product deploy и полноценный rollback включаются позже, после predeploy-check и VPN milestone.

## Временные и будущие материалы

- [Cursor deploy/rollback prompt](cursor-deploy-rollback-next-step.md) — prompt/archive для Cursor, не часть operational order.
- [Future VPS transport](future-vps-transport-softether-s2s-and-ssh-tunnel.md) — будущий план проверки SoftEther site-to-site/cascade и SSH tunnel fallback для controlled VPN egress.
- [Future security checks](future-security-sast-sca-dast.md) — будущий план SAST, SCA/OSA и DAST в report-only режиме.
- [Future platform role node migration](future-platform-role-node-migration-and-primary-promotion.md) — будущий runbook переноса любого physical node и плавного назначения нового active node для platform role.
- [Future management control plane and knowledge retrieval](future-management-control-plane-and-knowledge-retrieval.md) — будущий план web control plane и AI semantic knowledge layer после стабильного deploy/rollback.
