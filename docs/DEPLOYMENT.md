# Деплой

Деплой управляется платформой после того, как продуктовые репозитории опубликовали контейнерные образы.

## Что включено сейчас

- **Единственный разрешённый rollout:** `ai-retail-dev` → окружение `preprod` → **VPS2**.
- **Артефакт деплоя:** неизменяемый Docker `image_ref` (digest или коммит-SHA-тег), не git-ветка. См. [ADR-0006](adr/0006-deploy-from-immutable-image-refs.md).
- **Preflight:** `tools/deploy/preflight.py` читает `services.yml`, проверяет regex image ref и отдаёт JSON с `vps`, `compose_file`, `deploy_dir`, `deploy_state_tag_prefix`.
- **GitHub Actions:** workflow [`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml) — `make check` + preflight; при настроенных secrets выполняет SSH predeploy-check для `ai-retail-dev/preprod`: копирует compose-bundle на VPS2 и запускает `docker compose config` без `pull/up`.

## Что намеренно выключено

- Production deploy (`prod` / VPS1) для любого инстанса.
- Rollout для `aromaflow-work`, `aromaflow-demo`, `ai-retail-mvp` — workflow завершится с сообщением, что сценарий ещё не включён.
- **`ai-retail-mvp`** заморожен (`frozen: true`): deploy принимает только refs, совпадающие с `frozen_image_ref_pattern` (теги вида `ai-retail-mvp-v*`).

## Поток

1. Продуктовый репозиторий гоняет линт, тесты и сборку.
2. Продуктовый репозиторий публикует образ в GHCR с тегами по коммит-SHA или релиз-тегам.
3. Продуктовый репозиторий может триггернуть этот репозиторий через `repository_dispatch`.
4. Платформенный workflow валидирует репозиторий (`make check`) и прогоняет preflight по `image_ref`.
5. Для `ai-retail-dev/preprod` — SSH predeploy-check: подготовить bundle, проверить наличие runtime env-файла и выполнить `docker compose config` на VPS2.
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

## Требования к VPS2 перед первым predeploy-check

На VPS2 должны быть:

- доступ по SSH из GitHub Actions через Environment `ai-retail-dev-preprod`;
- установленный Docker Compose plugin (`docker compose`);
- каталог деплоя может отсутствовать — workflow создаст `/opt/stacks/ai-retail-dev-preprod`;
- runtime env-файл должен существовать заранее: `/opt/stacks/ai-retail-dev-preprod/.env.ai-retail.dev`.

Workflow кладёт рядом служебный файл `.env.deploy` только с `AI_RETAIL_DEV_WEB_IMAGE=<image_ref>`. Реальные секреты приложения в репозиторий не попадают.
