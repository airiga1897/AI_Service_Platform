# AI Service Platform

Репозиторий-оркестратор инфраструктуры для сервисов, разворачиваемых на AI Service Platform. Здесь нет прикладного кода — только метаданные платформы, инфра-конфиги, шаблоны и правила CI/CD.

Исходный код продуктов живёт в отдельных репозиториях:

- `airiga1897/AromaFlowAI`
- `airiga1897/AI_E_Retail`

Этот репозиторий владеет метаданными рантаймов уровня платформы, разметкой VPS, шаблонами edge-маршрутизации, шаблонами стеков, плейбуками деплоя и правилами оркестрации CI/CD. Он не должен содержать продуктовый исходный код и на первом этапе не использует git submodules.

Политика источников миграции описана в `docs/MIGRATION_SOURCES.md`. SoftEther VPN — обязательный edge/инфра-компонент платформы, не привязанный к продуктам, описан в `docs/SOFTETHER_VPN.md`. Исследования по CDN, GeoIP, GeoDNS и ускорению VPN собраны в `docs/CDN_GEO_POLICY.md`. Целевая VPN-топология: SoftEther на VPS1, VPS2 и VPS3; HAProxy публикует текущие TCP-входы.

## Рантайм-инстансы

- `aromaflow-work` — рабочий сайт AromaFlowAI.
- `aromaflow-demo` — сайт AromaFlowAI с демо-данными.
- `ai-retail-mvp` — замороженная MVP-версия AI_E_Retail.
- `ai-retail-dev` — копия AI_E_Retail для разработки.

## Модель CI/CD

Продукты собирают и публикуют образы. Платформенный репозиторий валидирует `services.yml` и деплоит выбранные image refs в выбранные стеки на VPS.

Ветки продуктовых репозиториев трактуются как политика сборки/исходников, а не как артефакты деплоя. Пока ветки `main` и `develop` продуктов ещё готовятся, `services.yml` хранит временные значения `bootstrap_ref` для текущих рабочих веток продуктов. Реальный деплой должен использовать неизменяемые Docker image refs, помеченные коммит-SHA или релиз-тегом.

Начальные workflow-ы — только валидация или ручные скелеты. Реальный деплой включается только после того, как сборка продуктовых образов станет стабильной.

## Архитектурные решения (ADR)

Значимые архитектурные решения для платформы записываются как ADR в [`docs/adr/`](docs/adr/README.md). Полный список — в [индексе](docs/adr/README.md).

Действующие ключевые решения:

- [ADR-0002](docs/adr/0002-infra-only-repository.md) — этот репозиторий хранит только инфраструктуру/оркестрацию; продуктовый код — в продуктовых репозиториях.
- [ADR-0003](docs/adr/0003-four-runtime-instances.md) — четыре рантайм-инстанса на старте (`aromaflow-work`, `aromaflow-demo`, `ai-retail-mvp`, `ai-retail-dev`).
- [ADR-0004](docs/adr/0004-extensible-service-catalog.md) — `services.yml` — расширяемый каталог для будущих сайтов и Telegram-ботов.
- [ADR-0005](docs/adr/0005-edge-haproxy-nginx-softether.md) — edge: HAProxy + per-site Nginx + SoftEther, владелец — инфраструктура.
- [ADR-0006](docs/adr/0006-deploy-from-immutable-image-refs.md) — деплой из неизменяемых Docker image refs, не из веток.
- [ADR-0007](docs/adr/0007-shared-geo-policy-service.md) — единый общий источник GeoPolicy, применение раздельно по типу трафика.

Текущий план работ Replit-сессии лежит в [`docs/replit/`](docs/replit/README.md).

## Локальная разработка

Установить общие Python-зависимости:

```bash
python3 -m pip install pyyaml jinja2
```

Прогнать тот же набор проверок, что и CI:

```bash
make check        # validate + render-check + smoke-тесты
make validate     # только валидатор services.yml
make render-check # дрейф сгенерированных compose-файлов
make test         # smoke-тесты всех инструментов
```

Включить pre-commit, чтобы те же проверки запускались до коммита:

```bash
pip install pre-commit
pre-commit install
pre-commit install --hook-type pre-push
```

Подробности — в [`docs/CI_CD.md`](docs/CI_CD.md).
