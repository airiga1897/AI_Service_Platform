# Деплой

> Placement is role-based. See [Service Placement Policy](PLACEMENT.md).
> Historical positional environment mappings are retired and must not be used
> for new rollout design.

Деплой управляется платформой после того, как продуктовые репозитории опубликовали контейнерные образы.

## Что включено сейчас

- The existing `ai-retail-dev/preprod` workflow is a legacy predeploy proof. It
  validates a compose bundle but is not an approved placement decision for a
  new runtime.
- **Артефакт деплоя:** неизменяемый Docker `image_ref` (digest или коммит-SHA-тег), не git-ветка. См. [ADR-0006](adr/0006-deploy-from-immutable-image-refs.md).
- **Preflight:** `tools/deploy/preflight.py` читает `services.yml`, проверяет regex image ref и отдаёт JSON с `vps`, `compose_file`, `deploy_dir`, `deploy_state_tag_prefix`.
- **GitHub Actions:** workflow [`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml) currently contains the legacy SSH predeploy proof and must be migrated to operator-resolved placement before real `pull/up` is enabled.

## Что намеренно выключено

- Production deployment remains disabled until role-based placement is wired into the deploy workflow.
- Rollout для `aromaflow-work`, `aromaflow-demo`, `ai-retail-mvp` — workflow завершится с сообщением, что сценарий ещё не включён.
- **`ai-retail-mvp`** использует release guard: deploy принимает только явно выпущенные версионные образы вида `ai-retail-mvp-v*`. Текущий release — `ai-retail-mvp-v1`.

## Поток

1. Продуктовый репозиторий гоняет линт, тесты и сборку.
2. Продуктовый репозиторий публикует образ в GHCR с тегами по коммит-SHA или релиз-тегам.
3. Продуктовый репозиторий может триггернуть этот репозиторий через `repository_dispatch`.
4. Платформенный workflow валидирует репозиторий (`make check`) и прогоняет preflight по `image_ref`.
5. Resolve the target alias from operator placement, then perform the guarded SSH predeploy check on that resolved alias.
6. Реальный `docker compose pull/up` и post-deploy healthcheck — следующий guarded milestone.

## Откат

Откат — это **re-deploy предыдущего `image_ref`**, не `git checkout`. Workflow [`.github/workflows/rollback.yml`](../.github/workflows/rollback.yml) требует явный input `to_ref`. Автоматический lookup по deploy-state git-тегам — следующий шаг.

## Источники (refs)

Политика «деплой только из неизменяемых image refs» зафиксирована в [ADR-0006](adr/0006-deploy-from-immutable-image-refs.md); машинно-читаемые правила — в `services.yml` под `platform.source_policy` и `runtime_instances.*.deploy`.

`services.yml` может содержать временные значения `bootstrap_ref`, пока ветки `main` и `develop` продукта не готовы. Эти refs идентифицируют политику сборки, но деплой всё равно должен использовать неизменяемые image refs из GHCR.

## Локальный preflight

```bash
python tools/deploy/preflight.py \
  --instance ai-retail-dev \
  --environment preprod \
  --image-ref 'ghcr.io/airiga1897/ai_e_retail:<40-char-sha>'
```

## Требования к resolved target перед первым predeploy-check

На выбранном operator placement target должны быть:

- доступ по SSH из GitHub Actions через Environment `ai-retail-dev-preprod`;
- установленный Docker Compose plugin (`docker compose`);
- каталог деплоя может отсутствовать — workflow создаст `/opt/stacks/ai-retail-dev-preprod`;
- runtime env-файл должен существовать заранее: `/opt/stacks/ai-retail-dev-preprod/.env.ai-retail.dev`.

Workflow кладёт рядом служебный файл `.env.deploy` только с `AI_RETAIL_DEV_WEB_IMAGE=<image_ref>`. Реальные секреты приложения в репозиторий не попадают.
