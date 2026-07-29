# Стек MyCleanBot

Приватный Telegram self-filter разворачивается на VPS1 двумя процессами одного
immutable-образа: `mycleanbot-web` и `mycleanbot-worker`.

Оба процесса разделяют network namespace platform-owned контейнера
`mycleanbot-route`. Он использует локальный image уже принятого
`platform-router`, подключается к `ai_service_app_vps1` с адресом
`172.31.1.10` и поддерживает только маршрут
`172.30.8.10/32 via 172.31.1.2`. Это инфраструктурный route-anchor, а не
третий процесс продукта; он не содержит PostgreSQL и не публикует внешний порт.

PostgreSQL не входит в Compose-стек. Платформа создаёт базу, управляет резервным
копированием и передаёт приложению `DATABASE_URL` через защищённый
`/opt/stacks/mycleanbot-prod/.env.mycleanbot.secrets`.

До установки runtime-файлов оператор обязан проверить, что на VPS1 работают
`platform-router`, `ai_service_app_vps1` и узкая TCP policy MyCleanBot к
`172.30.8.10:5432`. Ручной публичный маршрут или прямой PostgreSQL listener
запрещены.

Конфигурация разделена по аналогии с platform `site_runtime`: несекретные
production-настройки находятся в tracked-файле `mycleanbot.env`, а
`DATABASE_URL`, `DJANGO_SECRET_KEY`, `MASTER_ENCRYPTION_KEY`,
`TELEGRAM_API_ID` и `TELEGRAM_API_HASH` поступают из GitHub Environment и
атомарно устанавливаются в secret-файл с mode `0600`.

Публикация продуктового digest вызывает `repository_dispatch`: платформа
выполняет preflight и записывает кандидат в summary. Реальный deployment требует
отдельного ручного `workflow_dispatch` с тем же digest, использует GitHub
Environment `mycleanbot-prod`, перед запуском контейнеров выполняет миграции и
завершает работу проверкой `/healthz`.

Environment должен содержать `SSH_HOST`, `SSH_USER`, `SSH_KEY`, опциональный
`SSH_PORT`, `SSH_KNOWN_HOSTS`, `GHCR_USERNAME`, read-only `GHCR_TOKEN`, а также
application secrets `DATABASE_URL`, `DJANGO_SECRET_KEY`,
`MASTER_ENCRYPTION_KEY`, `TELEGRAM_API_ID` и `TELEGRAM_API_HASH`. Если тариф
GitHub не поддерживает
required reviewers для private-репозитория, обязательным gate остаётся отдельный
ручной запуск workflow; `repository_dispatch` сам production rollout не выполняет.

Дополнительно Environment содержит `SSH_KNOWN_HOSTS`. Workflow не использует
`ssh-keyscan`: ключ VPS принимается только из заранее проверенного pinned
`known_hosts`. Rollout разрешён только ручным запуском workflow из `main`.

## Production configuration

`mycleanbot.env` хранится в Git и не содержит secrets. До первого deployment в
нём задаются VPN-only `DJANGO_ALLOWED_HOSTS` и одинаковые
`DJANGO_CSRF_TRUSTED_ORIGINS`/`CSRF_TRUSTED_ORIGINS`.

Шаблон `.env.mycleanbot.secrets.example` содержит только пустые secret-поля.
Workflow собирает secret-файл из GitHub Environment без вывода значений,
передаёт его во временный путь и атомарно устанавливает на VPS с mode `0600`.
Worker запрещено запускать, пока `TELEGRAM_API_ID` и `TELEGRAM_API_HASH` не
прошли fail-closed проверку deployment helper.

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

Контейнер приложения публикуется только на `127.0.0.1:8040`. Для начального
доступа через Windows `hosts` платформа запускает отдельный
`mycleanbot-private-ingress` без published ports. Он использует immutable Nginx
image, принимает TLS на `172.31.1.11:443` внутри `ai_service_app_vps1`,
разрешает только routed-hub source `10.89.1.0/24` и проксирует к
`mycleanbot-route` `172.31.1.10:8000` через локальную app-сеть.
Public ingress для instance запрещён validator'ом.

Роль `mycleanbot_vpn_access` не создаёт сертификат или L3 hub и не меняет VPS
без `mycleanbot_vpn_access_change_approved=true`. До apply оператор должен по
доверенному каналу подготовить DNS-01 сертификат и отдельно применить
`l3-vps1`/`platform-router` policy из платформенного runbook.

HTTP probes, PostgreSQL, backup/restore и `telegram-supervisor` heartbeat
остаются обязательными сигналами MyCleanBot, но будут включены в единый
platform-wide monitoring, а не в отдельный monitoring stack проекта.

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

## Private backup transport

Backup traffic never uses a public VPS address. On VPS1,
`mycleanbot-backup-routes.service` installs only two host routes through
`platform-router`: `172.30.8.10/32` for PostgreSQL and `172.30.5.10/32` for
SFTP. On VPS5, `mycleanbot-backup-netns.service` creates an isolated network
namespace on `ai_service_data_vps5`; the dedicated sshd listens only on
`172.30.5.10:22` inside that namespace. No host port, HAProxy route, public DNS
record, or public firewall rule is created for SFTP.

The SFTP account accepts only its dedicated key, restricted to the observed
VPS1 platform source `172.31.1.1`. The client uses
`ssh_config_mycleanbot_backup` and a pinned VPS5 Ed25519 host key obtained
through the trusted operator channel; runtime `ssh-keyscan` is forbidden.
The chroot is `/opt/backups/ai-service-platform/mycleanbot` and Restic writes
only below `/repository/restic`.
