# Future site_runtime GitHub Actions CD

## Статус

Будущий план после приёмки ручного MVP rollout. Этот документ не разрешает
GitHub Actions изменять production и не является текущим operational order.

## Цель

Убрать зависимость production rollout от рабочей станции, сохранив
неизменяемые image refs, canonical platform tooling, ручное подтверждение
production mutations и локальное хранение operator/runtime secrets.

## Выбранная модель

- Product CI в `AI_E_Retail` тестирует продукт и после принятия `main`
  публикует `linux/amd64` image в GHCR по точному digest.
- Platform workflow принимает только
  `ghcr.io/airiga1897/ai_e_retail@sha256:<64 hex>`, product revision и
  ожидаемую platform revision.
- До mutations workflow выполняет read-only preflight и публикует безопасный
  deployment plan.
- Production job защищён GitHub Environment `ai-retail-mvp-prod` с
  обязательным ручным approval.
- Actions обращается к отдельному forced-command gateway на active
  orchestration node. Общий shell, admin SSH и чтение operator secrets
  запрещены.
- Gateway использует установленную exact platform revision, локальные
  operator state/secrets и общий instance lock. Несовпадение revision,
  повтор request id или операция вне allowlist отклоняются.

## Canonical rollout

После approval gateway выполняет существующие platform operations, не
дублируя deploy-логику в workflow:

1. backup и repository check;
2. immutable image staging;
3. `site_runtime apply -Check`;
4. real apply;
5. publication/security acceptance;
6. canonical PostgreSQL audit.

`superuser` и `demo_data` остаются отдельными bootstrap-операциями с
собственным approval. Merge в product `main` сам по себе production не
изменяет.

## Rollback и журнал

- Rollback требует отдельного approval и явного предыдущего exact digest.
- Автоматический restore базы или повторный deploy запрещены.
- Actions хранит только безопасные artifacts: request id, digest, revisions,
  checksums, deployment/backup status и ссылки на durable remote logs.
- Application, database и bootstrap secrets не передаются в GitHub artifacts
  или logs.

## Этапы внедрения

1. Check-only gateway и валидация malformed/replayed requests.
2. Read-only workflow без production credentials.
3. Approved image staging при ручном real apply.
4. Полный approved rollout и отдельная rollback rehearsal.
5. Обобщение allowlist для других portable project contracts.

До завершения этих этапов действующим способом остаётся ручной canonical
rollout через `service_remote.ps1`.
