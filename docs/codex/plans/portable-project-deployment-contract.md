# Переносимый deployment-контракт прикладных проектов

## Цель

Платформа должна запускать прикладной проект без повторного описания его
функциональности в инфраструктурном репозитории. Проект владеет командами,
параметрами приложения, frontend-конфигурацией и bootstrap-операциями. Платформа
владеет адресами инфраструктуры, production-безопасностью, секретами, storage,
порядком rollout и журналами.

«Запустить проект как есть» означает сохранить функциональный контракт проекта,
но не копировать локальные адреса, dev-режим и bootstrap-пароли во все
production-процессы.

## Versioned contract проекта

Каждый поддерживаемый image содержит
`/app/deploy/site-runtime.contract.yml`. Исходный файл хранится в репозитории
проекта и проходит CI-валидацию до публикации image.

Минимальный контракт версии 1:

```yaml
schema_version: 1
application:
  environment:
    runtime:
      - AI_PROVIDER
      - RAG_ENABLED
      - ENABLE_PLATFORM_ADMIN
      - ENABLE_SAAS_MODULES
      - ENABLE_DEMO_MODE
      - ENABLE_PAYMENTS
    secrets:
      - SECRET_KEY
      - OPENAI_API_KEY
    platform_owned:
      - DATABASE_URL
      - DB_HOST
      - DB_PORT
      - DB_NAME
      - DB_USER
      - DB_PASSWORD
      - CELERY_BROKER_URL
      - ALLOWED_HOSTS
      - CSRF_TRUSTED_ORIGINS
      - CORS_ALLOWED_ORIGINS
    local_only:
      - VITE_DEV_PROXY_TARGET
    bootstrap:
      superuser:
        command: python manage.py create_superuser
        environment:
          - DJANGO_SUPERUSER_USERNAME
          - DJANGO_SUPERUSER_EMAIL
          - DJANGO_SUPERUSER_PASSWORD
  frontend:
    configuration: runtime
    public_endpoint: /runtime-config.js
  components:
    static: python manage.py collectstatic --noinput
    migration: python manage.py migrate --noinput
    web: gunicorn electronics_network.wsgi:application --bind 0.0.0.0:8000
    worker: python -m celery -A electronics_network worker -l info
    beat: python -m celery -A electronics_network beat -l info --scheduler django_celery_beat.schedulers:DatabaseScheduler
  health:
    live: /healthz/
    ready: /readyz/
    worker: /worker-healthz/
```

Контракт перечисляет имена, но не содержит значения секретов. Каждое имя из
исходного env обязано принадлежать runtime, secrets, platform-owned, bootstrap
или local-only. Неклассифицированные имена и повторное объявление одного имени
в разных классах отклоняются, поэтому функциональные параметры не теряются
молча.

## Разрешение environment

Платформа формирует effective environment в фиксированном порядке:

1. Берёт application runtime и secrets из operator-only профиля экземпляра.
2. Вычисляет `platform_owned` из canonical PostgreSQL, Redis, domain, TLS и
   storage model.
3. Проверяет обязательные значения и типы без вывода секретов.
4. Передаёт effective runtime только web/worker/beat и one-shot операциям,
   которым он необходим.
5. Передаёт bootstrap environment только одноразовой bootstrap-команде и
   удаляет временный secret-файл в `always`.

Локальные `.env`, `.env.docker` и Compose остаются удобными интерфейсами
разработчика. Они могут быть источником operator-профиля, но целиком не
монтируются в production runtime. Значения `DEBUG`, `ENVIRONMENT`, database,
broker, public origin и cookie/TLS всегда нормализуются платформой.

Локальный импорт выполняется сначала без изменений:

```powershell
python tools/site_runtime/import_project_env.py `
  --contract D:\Projects\Codex\AI_E_Retail\deploy\site-runtime.contract.yml `
  --source-env D:\Projects\Codex\AI_E_Retail\.env.docker `
  --target operator\site_runtime\secrets\ai-retail-mvp.env `
  --bootstrap-operation superuser `
  --bootstrap-target operator\site_runtime\bootstrap-secrets\ai-retail-mvp.superuser.env `
  --check
```

После принятия отчёта та же команда без `--check` атомарно обновляет ignored
operator secret. Существующие непустые production-секреты имеют приоритет над
локальными; отчёт содержит только имена полей, без значений.

Bootstrap выполняется отдельным сериализованным действием:

```powershell
.\tools\services\service_remote.ps1 site_runtime bootstrap `
  -Instance ai-retail-mvp `
  -Operation superuser `
  -Limit vps3 `
  -Check
```

После принятия check-mode та же команда без `-Check` запускает только команду,
объявленную embedded contract. Bootstrap secret передаётся one-shot контейнеру,
не добавляется в постоянный `runtime.env`, удаляется с orchestration node после
операции и не выводится в журнал.

## Frontend runtime configuration

Публичные frontend-параметры не должны требовать пересборки immutable image.
SPA загружает `/runtime-config.js` до основного bundle и использует только
явно разрешённые несекретные значения. Build-time `VITE_*` остаются fallback
для локальной разработки.

Это позволяет одному image digest работать в demo, preprod и production.
Секреты, database URLs и внутренние адреса никогда не попадают в
`runtime-config.js`.

## Bootstrap и переносимость

Bootstrap не является частью обычного старта контейнера. Миграция, создание
администратора, seed и изменение embedding dimension — отдельные
сериализованные операции с dry-run/preflight, журналом и идемпотентной
командой проекта.

Для `ai-retail-mvp` первый bootstrap использует существующие
`DJANGO_SUPERUSER_*` из локального `.env.docker`, не меняя логин или пароль.
Платформа передаёт только эти три значения one-shot процессу. После выполнения
принимаются active/staff/superuser, роль профиля, verified primary email и
успешный login без вывода токена или пароля.

## Рубежи внедрения

1. **Presentation image**: AI_E_Retail добавляет contract v1 и runtime frontend
   config. Demo/Platform Admin/SaaS становятся доступны из runtime-профиля.
2. **Bootstrap admin**: существующие credentials применяются one-shot и
   удаляются; постоянный runtime и `current.json` не меняются.
3. **Generic resolver**: `site_runtime` извлекает contract из staged image,
   валидирует operator-профиль и показывает классифицированный effective model.
4. **Contract-driven apply**: команды и environment берутся из принятого
   contract; platform-owned значения сохраняют приоритет.
5. **Reusable onboarding**: новый проект предоставляет image, contract и
   operator-профиль, после чего использует общие stage/apply/bootstrap/backup/
   publication действия без отдельной Ansible-роли.

### Обновление уже опубликованного runtime

Наличие принятого HTTPS publication receipt меняет контракт `apply`: публикация
должна сохраняться, а не возвращаться к private-конфигурации. До любых runtime
mutations платформа fail-closed проверяет связь publication receipt с текущим
deployment, checksums `runtime.env`, public Nginx и HAProxy, TLS/ACME volumes,
работающий SNI route, локальный TLS endpoint и внешнюю security-приёмку.

Prospective Compose включает те же persistent TLS/ACME volumes, Nginx получает
принятый public config, а platform-owned `ALLOWED_HOSTS` и
`CSRF_TRUSTED_ORIGINS` повторно выводятся из canonical publication model. После
обновления принимаются private и external health и отсутствие публичных
Gunicorn/Redis/PostgreSQL/private media. Затем новый deployment receipt проходит
финальную приёмку, и только после неё обновляется publication receipt.
Расхождение любого durable или фактического identity останавливает `apply` до
изменения runtime.

## Приёмка презентационного профиля AI_E_Retail

- SPA показывает Shop, B2B, Ops, Platform Admin, SaaS и demo-сценарии,
  разрешённые профилем.
- Backend feature flags совпадают с публичной runtime-конфигурацией SPA.
- Не настроенные OpenAI, SMTP и платёжные провайдеры не объявляются рабочими;
  demo/fake режим отображается явно.
- Администратор входит через SPA и Django admin существующими credentials.
- `/healthz/` и `/readyz/` возвращают `200`, worker health остаётся private.
- Runtime image digest, effective configuration и contract checksum записаны
  в deployment journal/current receipt.
- Повторный bootstrap и повторный apply идемпотентны.
