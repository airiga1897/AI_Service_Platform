# Стек MyCleanBot

Приватный Telegram self-filter разворачивается на VPS1 двумя процессами одного
immutable-образа: `mycleanbot-web` и `mycleanbot-worker`.

PostgreSQL не входит в Compose-стек. Платформа создаёт базу, управляет резервным
копированием и передаёт приложению `DATABASE_URL` через защищённый
`/opt/stacks/mycleanbot-prod/.env.mycleanbot`.

В этом же platform secret-файле должны находиться `DJANGO_SECRET_KEY`,
`MASTER_ENCRYPTION_KEY`, `TELEGRAM_API_ID`, `TELEGRAM_API_HASH`,
`DJANGO_ALLOWED_HOSTS` и остальные production-настройки. Файл не хранится в Git.

Публикация продуктового digest вызывает `repository_dispatch`; deployment
защищён GitHub Environment `mycleanbot-prod`, перед запуском контейнеров выполняет
миграции и завершает работу проверкой `/healthz`.

Environment должен требовать ручного approval и содержать `SSH_HOST`, `SSH_USER`,
`SSH_KEY`, опциональный `SSH_PORT`, а также `GHCR_USERNAME` и read-only
`GHCR_TOKEN` для загрузки приватного образа.

Compose генерируется из `services.yml`:

```bash
python3 tools/render-compose/render_compose.py --stack mycleanbot
python3 tools/render-compose/render_compose.py --stack mycleanbot --check
```
