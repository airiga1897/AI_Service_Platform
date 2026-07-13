# ADR и видение платформы в docs

## Зачем и почему
Зафиксировать в репозитории долгосрочное видение платформы и завести лёгкий процесс ADR (записей об архитектурных решениях), чтобы все принятые архитектурные решения были найдены в одном месте и могли пересматриваться по мере развития.

Видение, которое нужно явно описать в документации:

- В этом репозитории планируется размещать **4 рантайм-инстанса** (уже отражены в `services.yml`):
  - `ai-retail-mvp` — release-guarded MVP runtime `airiga1897/AI_E_Retail`.
  - `ai-retail-dev` — зеркальная копия для дальнейшей разработки `airiga1897/AI_E_Retail` (на старте идентична MVP, далее расходится).
  - `aromaflow-work` — рабочий сайт `airiga1897/AromaFlowAI`.
  - `aromaflow-demo` — демо-версия того же сайта (с `setup_demo_content`).
- Платформа должна быть готова к добавлению **новых приложений и Telegram-ботов** (см. `future_service_template` в `services.yml`: `site` и `telegram-bot`) без изменения базовой схемы.
- Продуктовый код **не вендорится** в этот репозиторий и не подключается submodule'ами на первом этапе — он живёт в продуктовых репозиториях (`AromaFlowAI`, `AI_E_Retail`).

## Критерии готовности
- Появился каталог `docs/adr/` со стандартным шаблоном MADR (`docs/adr/template.md`) и индексом (`docs/adr/README.md` с таблицей всех ADR).
- Заведён мета-ADR `0001-record-architecture-decisions.md` («мы ведём ADR в этом каталоге, формат MADR»).
- Заведены ADR, отражающие уже принятые решения (формулировки опираются на `services.yml` и существующие doc-файлы):
  - `0002-infra-only-repository.md` — этот репозиторий хранит только оркестрацию; продуктовый код в продуктовых репозиториях.
  - `0003-four-runtime-instances.md` — два инстанса AromaFlowAI (`work`, `demo`) и два инстанса AI_E_Retail (`mvp`, `dev`); MVP использует versioned release images, dev развивается независимо.
  - `0004-extensible-service-catalog.md` — `services.yml` рассчитан на расширение новыми сайтами и Telegram-ботами по шаблонам из `future_service_template`.
  - `0005-edge-haproxy-nginx-softether.md` — единый edge: HAProxy + per-site Nginx + SoftEther как обязательный платформенный компонент.
  - `0006-deploy-from-immutable-image-refs.md` — деплой только из неизменяемых docker image refs; `bootstrap_ref` — временная мера.
  - `0007-shared-geo-policy-service.md` — единый источник geo-данных, разные точки применения (HAProxy, GeoDNS, egress, CDN inputs).
- В `README.md` добавлен раздел «Архитектурные решения (ADR)» со ссылкой на `docs/adr/README.md` и краткое перечисление 4 рантайм-инстансов.
- В `docs/ARCHITECTURE.md` добавлен раздел «Roadmap / Рантайм-инстансы», описывающий 4 текущих инстанса и план добавления ботов/новых сайтов; есть ссылка на `services.yml` как на источник истины.
- Планы всех текущих задач Replit-сессии скопированы в `docs/replit/plans/` (по одному `.md` на задачу, имена соответствуют файлам в `.local/tasks/`), плюс `docs/replit/README.md` с кратким индексом и пояснением, что это снапшот плана работ, а не процесс ADR (ADR живут в `docs/adr/`).
- Все новые `.md`-файлы валидны (нет битых внутренних ссылок), `tools/validate-services-yml/validate_services_yml.py` по-прежнему проходит.

## Вне скоупа
- Перепроектирование самих архитектурных решений — задача только зафиксировать уже принятое.
- Вендоринг продуктового кода или подключение submodule'ов.
- Изменения в `services.yml` (структура остаётся; новые ADR на неё ссылаются).
- Реализация новых инструментов (`render-compose`, `healthcheck`, расширение валидатора, CI-хуки) — это отдельные задачи.

## Шаги
1. **Каркас ADR** — создать `docs/adr/`, `docs/adr/README.md` (индекс) и `docs/adr/template.md` (MADR-шаблон: разделы «Контекст», «Решение», «Статус», «Последствия», «Дата»).
2. **Мета-ADR 0001** — записать решение «мы ведём ADR в `docs/adr/`, формат MADR, статусы Proposed/Accepted/Superseded».
3. **ADR 0002–0007** — оформить уже принятые решения (см. список в «Done looks like»), каждый со ссылкой на соответствующие места в `services.yml` и существующих doc-файлах.
4. **Кросс-ссылки** — добавить раздел «Архитектурные решения (ADR)» в `README.md` и раздел «Roadmap / Рантайм-инстансы» в `docs/ARCHITECTURE.md`; обновить индекс ADR.
5. **Проверка** — прогнать валидатор `services.yml`, убедиться, что внутренние ссылки рабочие, нет дублирующих/противоречивых утверждений с `docs/MIGRATION_SOURCES.md`, `docs/SOFTETHER_VPN.md`, `docs/CDN_GEO_POLICY.md`.

## Затрагиваемые файлы
- `README.md`
- `services.yml`
- `docs/ARCHITECTURE.md`
- `docs/CI_CD.md`
- `docs/DEPLOYMENT.md`
- `docs/MIGRATION_SOURCES.md`
- `docs/SOFTETHER_VPN.md`
- `docs/CDN_GEO_POLICY.md`
- `docs/VPS_ROLES.md`
- `tools/validate-services-yml/validate_services_yml.py`
