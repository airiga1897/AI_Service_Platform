# Codex Plans

Эта папка разделяет основной порядок платформенных шагов и временные/вспомогательные материалы.

## Основной порядок

1. [VPS3 management bootstrap](01-vps3-management-bootstrap.md) — сначала поднимается current alias VPS3 как Ansible control node, затем current aliases VPS1/VPS2 как managed nodes.
2. Разложить bootstrap-generated keys в ignored `operator/<alias>/` по инструкции из первого шага. Это пока ручной operator-local шаг: в repo ключи не попадают.
3. Сгенерировать real inventory на VPS3 и запускать Ansible уже с management node.

## Временные и вспомогательные материалы

- [Temporary GitHub Actions deploy access](temporary-github-actions-deploy-access-ai-retail-dev-preprod.md) — временный мост для `ai-retail-dev/preprod` на VPS2. Запускается после bootstrap VPS2 и использует `operator/vps2/deploy_key`.
- [Cursor deploy/rollback prompt](cursor-deploy-rollback-next-step.md) — prompt/archive для Cursor, не часть operational order.
- [Future VPS transport](future-vps-transport-softether-s2s-and-ssh-tunnel.md) — будущий план проверки SoftEther site-to-site/cascade и SSH tunnel fallback для controlled VPN egress.
- [Future security checks](future-security-sast-sca-dast.md) — будущий план SAST, SCA/OSA и DAST в report-only режиме.
- [Future platform role node migration](future-platform-role-node-migration-and-primary-promotion.md) — будущий runbook переноса любого physical node и плавного назначения нового active node для platform role.
