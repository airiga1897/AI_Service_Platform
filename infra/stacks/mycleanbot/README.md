# Стек MyCleanBot

Приватный Telegram self-filter разворачивается на VPS1 двумя процессами одного
immutable-образа: `mycleanbot-web` и `mycleanbot-worker`.

PostgreSQL не входит в Compose-стек. Платформа создаёт базу, управляет резервным
копированием и передаёт приложению `DATABASE_URL` через защищённый
`/opt/stacks/mycleanbot-prod/.env.mycleanbot`.

В этом же platform secret-файле должны находиться `DJANGO_SECRET_KEY`,
`MASTER_ENCRYPTION_KEY`, `TELEGRAM_API_ID`, `TELEGRAM_API_HASH`,
`DJANGO_ALLOWED_HOSTS` и остальные production-настройки. Файл не хранится в Git.

Публикация продуктового digest вызывает `repository_dispatch`: платформа
выполняет preflight и записывает кандидат в summary. Реальный deployment требует
отдельного ручного `workflow_dispatch` с тем же digest, использует GitHub
Environment `mycleanbot-prod`, перед запуском контейнеров выполняет миграции и
завершает работу проверкой `/healthz`.

Environment должен требовать ручного approval и содержать `SSH_HOST`, `SSH_USER`,
`SSH_KEY`, опциональный `SSH_PORT`, а также `GHCR_USERNAME` и read-only
`GHCR_TOKEN` для загрузки приватного образа. Если тариф GitHub не поддерживает
required reviewers для private-репозитория, обязательным gate остаётся отдельный
ручной запуск workflow; `repository_dispatch` сам production rollout не выполняет.

Дополнительно Environment содержит `SSH_KNOWN_HOSTS`. Workflow не использует
`ssh-keyscan`: ключ VPS принимается только из заранее проверенного pinned
`known_hosts`. Rollout разрешён только ручным запуском workflow из `main`.

## Production secret file

Шаблон `.env.mycleanbot.example` не содержит значений. Перед установкой оператор
получает значения у владельца и создаёт `/opt/stacks/mycleanbot-prod/.env.mycleanbot`
с mode `0600`. Для текущего опубликованного образа одно и то же trusted-origin
значение записывается в `DJANGO_CSRF_TRUSTED_ORIGINS` и
`CSRF_TRUSTED_ORIGINS`. Worker запрещено запускать, пока `TELEGRAM_API_ID` и
`TELEGRAM_API_HASH` не прошли fail-closed проверку deployment helper.

## Backup and restore

`tools/postgres-tenant/postgres_tenant_backup.py` делает custom-format `pg_dump`
только базы `mycleanbot`, сохраняет его в зашифрованный Restic repository,
применяет retention 14 daily / 4 weekly / 6 monthly и выполняет `restic check`.
Еженедельный restore rehearsal создаёт отдельную scratch-базу, сверяет checksum
dump и число application relations с manifest и всегда удаляет scratch database.
Поэтому первоначальная пустая tenant DB тоже проверяется до первой миграции.
Production database не является целью rehearsal.

Перед созданием tenant оператор запускает
`provision_mycleanbot.py plan`, затем read-only `audit`. `apply` разрешён только
после credentials/VPS approval, получает database password через скрытый prompt,
создаёт фиксированные role/database `mycleanbot` и отказывается перезаписывать
любой существующий объект. Role получает `NOSUPERUSER`, `NOCREATEDB`,
`NOCREATEROLE`, `NOREPLICATION` и не включается в другие роли.

На одобренной VPS-стадии устанавливаются backup wrapper, systemd services/timers
и `/etc/ai-service-platform/mycleanbot-backup.env`. Backup config и Restic
password file имеют mode `0600`; их значения не выводятся в команды, GitHub
summary или application logs.

## VPN-only ingress and monitoring

Контейнер публикуется только на `127.0.0.1:8040`. Шаблон
`nginx.mycleanbot-vpn.conf.template` рендерится только после получения VPN
listen-address, hostname и TLS paths и слушает исключительно VPN interface.
Public ingress для instance запрещён validator'ом.

Prometheus на management node использует Blackbox Exporter для `/livez` и
`/healthz`. `/healthz` проверяет PostgreSQL и DB-backed heartbeat
`telegram-supervisor`. Node Exporter textfile metrics контролируют свежесть
backup и scratch restore rehearsal.

## Deployment state and rollback

`mycleanbot_remote.sh` сериализует операции через `flock`, требует успешный
pre-migration backup, использует временный Docker config и принимает только
`ghcr.io/airiga1897/mycleanbot@sha256:<64 hex>`. После успешных `/livez`,
`/healthz` и heartbeat checks он атомарно обновляет `.deploy-state/current` и
`.deploy-state/previous`.

Rollback повторно принимает только digest. Для первого rollout специальная цель
`undeployed` останавливает только `mycleanbot-web` и `mycleanbot-worker`, не
удаляя PostgreSQL, env, backup или monitoring. Schema/data restore никогда не
выполняется автоматически.

Compose генерируется из `services.yml`:

```bash
python3 tools/render-compose/render_compose.py --stack mycleanbot
python3 tools/render-compose/render_compose.py --stack mycleanbot --check
```
