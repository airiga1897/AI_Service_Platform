# Подготовка приватного образа для Site Runtime

## Граница этапа

Этот этап связывает разработку продукта в `AI_E_Retail` с универсальными
средствами развёртывания в `AI_Service_Platform`. Продуктовый репозиторий
публикует неизменяемый образ в GHCR, а платформа использует его digest как
идентификатор развёртывания.

Операция подготовки загружает образ в Docker на вычисленном целевом узле. Она
не создаёт и не запускает контейнеры продукта, не выполняет миграции или seed,
не создаёт volumes, не формирует runtime compose и не добавляет edge route.

## Каноническая модель

- `services.yml` хранит контракт продукта/runtime и правило digest-only.
- `operator/site_runtime/instances.yml` хранит размещение instance и сетевой intent.
- `operator/state.csv` перечисляет узлы, на которых разрешён `site_runtime`.
- Resolver не читает устаревшие поля `deploy.environments.*.vps`.
- В версии 1 на одном alias разрешён не более чем один site instance.

## Последовательность для оператора

Сначала локально вычислить модель:

```powershell
.\tools\services\service.ps1 site_runtime plan `
  -Instance ai-retail-mvp `
  -ImageRef ghcr.io/airiga1897/ai_e_retail@sha256:b1d1c78bda98f46953c96b197124be1d39182fa2c5d89de35470c6a3f8de5b56 `
  -Limit vps3
```

Затем проверить удалённую роль. Команда может авторизоваться, сформировать и
передать временный архив, но в check mode не выполняет `docker load` на vps3:

```powershell
.\tools\services\service_remote.ps1 site_runtime stage-image `
  -Instance ai-retail-mvp `
  -ImageRef ghcr.io/airiga1897/ai_e_retail@sha256:b1d1c78bda98f46953c96b197124be1d39182fa2c5d89de35470c6a3f8de5b56 `
  -Limit vps3 `
  -Check
```

После проверки вывода загрузить образ:

```powershell
.\tools\services\service_remote.ps1 site_runtime stage-image `
  -Instance ai-retail-mvp `
  -ImageRef ghcr.io/airiga1897/ai_e_retail@sha256:b1d1c78bda98f46953c96b197124be1d39182fa2c5d89de35470c6a3f8de5b56 `
  -Limit vps3
```

Рабочая станция использует авторизацию `gh` и передаёт токен локальному Docker
через stdin. Ни vps6, ни vps3 не получают registry credentials. После проверки
временные tar и manifest удаляются со всех трёх узлов.

## Критерии приёмки

- Роль сообщает запрошенный digest, ожидаемый Docker config image ID,
  `linux/amd64` и детерминированный transport tag.
- Receipt находится в
  `/var/lib/ai-service-platform/site-runtime/images/ai-retail-mvp/`.
- Повторная подготовка того же digest сообщает `already_loaded: true`, не
  выполняет повторный `docker load` и не изменяет receipt.
- Наборы Docker container ID до и после операции совпадают.
- Не создаются product compose project, контейнеры, volumes, host ports,
  миграции, seed, nginx route или публичный edge route.
- PostgreSQL остаётся primary на vps8 с асинхронными streaming standby vps4 и vps9.

Runtime-команда `apply` остаётся запрещённой до приёмки этого этапа.
