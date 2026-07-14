# Codex Plans

> Numbered plans describe completed or historical milestones and are not a
> placement source of truth. Fixed positional environment mappings are retired.
> Use [`../../PLACEMENT.md`](../../PLACEMENT.md) and current operator
> state/config.

Эта папка хранит operational order и будущие планы. Numbered-файлы описывают основной порядок внедрения. `future-*` и prompt/archive документы не являются текущим порядком выполнения.

## Основной Порядок

1. [Control/orchestration node bootstrap](01-orchestration-bootstrap.md) - bootstrap, sync `nodes.csv`/`state.csv`, inventory и verify.
2. [GitHub Actions deploy access](02-github-actions-deploy-access-ai-retail-dev-preprod.md) - GitHub Environment/secrets/predeploy-check для `ai-retail-dev-preprod`, без product `pull/up`.
3. [VPN first service rollout](03-vpn-first-service-rollout.md) - `edge_haproxy` как TCP edge и `vpn_edge` как SoftEther user ingress.
4. [Platform services manual rollout, then GitHub gate](04-platform-services-manual-rollout-then-github-gate.md) - ручная проверка platform services, затем перенос проверенного rollout в GitHub Actions.
5. [Egress policy, probes, and AI-assisted analysis](05-egress-policy-probes-and-ai-analysis.md) - staged roadmap для egress policy, probes, AI-assisted classification и controlled routing enforcement.

## Текущая Модель

- `nodes.csv` - только адресная книга: `current_alias,endpoint,expected_ip,connection,ssh_port,root_password`.
- `state.csv` - источник истины для `platform_role`, `service`, `active/candidate/old` и `present/absent/purged`.
- `edge_route` - HAProxy route внутри `edge_haproxy`, не отдельный контейнер.
- `plan` - команда runner-а, а не состояние сервиса.
- Active orchestration node выбирается из `state.csv`, не по hardcoded `vps3`.
- Основной rollout без GitHub:

  ```powershell
  .\tools\services\rollout_from_state.ps1 `
    -NodesFile .\operator\nodes.csv `
    -StateFile .\operator\state.csv
  ```

  WSL/Linux equivalent:

  ```bash
  bash tools/services/rollout_from_state.sh \
    --nodes-file ./operator/nodes.csv \
    --state-file ./operator/state.csv
  ```

GitHub Actions позже должны вызывать эти же scripts, а не содержать отдельную deploy-логику.

Detached service jobs are the normal path for long-running rollout. Upload and
extract bundles stay temporary in `/tmp`; durable job logs are written to
`/var/log/ai-service-platform/jobs/<job-id>.log`, and job state is written to
`/var/lib/ai-service-platform/jobs/<job-id>/`. The `platform_ops` role creates
these paths and installs log rotation on every current and future VPS. See
[Durable detached job logs](durable-job-logs.md).

## Будущие Материалы

- [Minimum VPS resource expansion](minimum-vps-resource-expansion.md) - approved pools, minimum profiles, safe resize order, and acceptance checks before `site_runtime`.
- [Manual site runtime rollout before GitHub CD](manual-site-runtime-rollout-before-github-cd.md) - operator-first rollout contract, durable deployment journal, rehearsal gates, and the criteria for enabling GitHub CD.
- [Future Edge HAProxy security layers](future-edge-haproxy-security-layers.md) - GeoIP, scanner autoban, WAF-like rules и ACME bypass после стабильного VPN/TCP edge.
- [Future VPS transport](future-vps-transport-softether-s2s-and-ssh-tunnel.md) - SoftEther site-to-site/cascade и SSH tunnel fallback.
- [Future SD-WAN-like egress controller](future-sd-wan-like-egress-controller.md) - direct/cascade path selection for approved targets with health checks and safe route reconciliation.
- [Future security checks](future-security-sast-sca-dast.md) - SAST, SCA/OSA и DAST в report-only режиме.
- [Future platform role node migration](future-platform-role-node-migration-and-primary-promotion.md) - перенос physical node и назначение нового active node.
- [Future operator state node retirement tool](future-operator-state-node-retirement-tool.md) - безопасное удаление VPS из service placement, cascade topology, inventory inputs и operator secrets.
- [Future management control plane and knowledge retrieval](future-management-control-plane-and-knowledge-retrieval.md) - web control plane и AI semantic knowledge layer.
- [Future data services and platform auth](future-data-services-and-platform-auth.md) - PostgreSQL, MariaDB reserved и platform auth.
- [Controlled pgvector runtime migration](pgvector-runtime-migration.md) - standby-first PostgreSQL image migration required by AI_E_Retail.

## Вспомогательные Материалы

- [Cursor deploy/rollback prompt](cursor-deploy-rollback-next-step.md) - prompt/archive для Cursor, не часть operational order.
