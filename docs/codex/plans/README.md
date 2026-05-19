# Codex Plans

Эта папка разделяет основной порядок платформенных шагов и временные/вспомогательные материалы.

## Основной порядок

1. [VPS3 management bootstrap](01-vps3-management-bootstrap.md) — сначала поднимается VPS3 как Ansible control node, затем VPS1/VPS2 как managed nodes.

## Временные и вспомогательные материалы

- [Temporary GitHub Actions deploy access](temporary-github-actions-deploy-access-ai-retail-dev-preprod.md) — временный мост для `ai-retail-dev/preprod` на VPS2, не основной способ управления инфраструктурой.
- [Cursor deploy/rollback prompt](cursor-deploy-rollback-next-step.md) — prompt/archive для Cursor, не часть operational order.
- [Future VPS transport](future-vps-transport-softether-s2s-and-ssh-tunnel.md) — будущий план проверки SoftEther site-to-site/cascade и SSH tunnel fallback для controlled VPN egress.
- [Future security checks](future-security-sast-sca-dast.md) — будущий план SAST, SCA/OSA и DAST в report-only режиме.
