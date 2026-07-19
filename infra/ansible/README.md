# Платформенные Ansible-черновики

Этот каталог содержит платформенные Ansible-роли. Часть из них была
выборочно перенесена из ветки `codex/feature/new_infra02` репозитория
`AromaFlowAI`.

## Текущее состояние

- `docker`, `security`, `monitoring`, `management`, `semaphore` —
  чисто платформенные роли (ничего product-specific).
- `backup_client`, `backup_server` — параметризованные черновики:
  имена контейнеров, volume'ов, cron-job'ов, образ и WSGI-модуль
  тащатся из переменных, не из захардкоженных строк.
- Старая роль деплоя приложения `mypet01` сознательно не переносилась.
  Деплой стека приложения должен идти от сгенерированных compose-файлов
  (`infra/stacks/<instance>/`), а не из этой Ansible-роли.

## Модель параметризации

Роли `backup_client` / `backup_server` настраиваются через переменные,
объявленные в `group_vars/all.yml` как placeholder'ы и переопределяемые
на уровне хоста (`host_vars/<host>.yml`) или через `--extra-vars`.

| Переменная | Назначение |
|---|---|
| `app_name` | Имя приложения. Префикс для контейнеров, volume'ов, cron'ов. Должно совпадать с именем рантайм-инстанса в `services.yml`. |
| `app_dir` | Каталог приложения на хосте. По умолчанию `/opt/{{ app_name }}`. |
| `app_image` | Docker-образ для standby-стека (тег подставляется при запуске). |
| `app_wsgi_module` | WSGI-модуль приложения для gunicorn в standby. |
| `app_domains` | Список prod-доменов (для подсказок failover-скрипта). |
| `db_container_name` | Имя контейнера БД на primary. По умолчанию `{{ app_name }}-db-1`. |
| `db_standby_container_name` | Имя контейнера БД standby. По умолчанию `{{ app_name }}-db-standby-1`. |
| `db_standby_volume` | Имя docker-volume для standby PostgreSQL. По умолчанию `{{ app_name }}_postgres_standby`. |
| `backup_cron_prefix` | Префикс имён cron-файлов backup-клиента. По умолчанию `{{ app_name }}`. |

Пример заполнения для инстанса `aromaflow-work` —
[`host_vars/aromaflow-work.yml.example`](host_vars/aromaflow-work.yml.example).

## Перед реальным provisioning

- Подставить `app_name` (и при необходимости `app_image`,
  `app_wsgi_module`, `app_domains`) в `host_vars/<host>.yml` или через
  `--extra-vars`. **Без `app_name`** роли упадут на placeholder
  `REPLACE_ME` — это сознательный fail-fast.
- Сгенерировать `inventory.ini` из GitHub Environments, Ansible Vault
  или локального ввода оператора. Реальные инвентори не коммитим.
- Не забывать про SoftEther VPN: `softether_data`, `softether_logs`,
  копии TLS-сертификатов и конфиг HAProxy с VPN-маршрутизацией —
  это платформенные данные, см. [`docs/SOFTETHER_VPN.md`](../../docs/SOFTETHER_VPN.md).
