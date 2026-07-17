# Generic site_runtime apply для AI_E_Retail

## Граница этапа

Этап добавляет production-like private runtime и проверяет его через Ansible
check mode. Реальный `apply`, Django migrations, seed, host ports, домен и public
route выполняются только после отдельного операторского подтверждения.

Runtime состоит из anchor, Redis, migration, web, worker, beat и Nginx. Только
anchor получает `NET_ADMIN` и адрес `172.31.3.10`; остальные компоненты используют
его network namespace. Nginx слушает `8080` только внутри Docker namespace.

## Секреты

Создайте игнорируемый Git файл:

```powershell
Copy-Item .\operator\site_runtime\secrets\template.env `
  .\operator\site_runtime\secrets\ai-retail-mvp.env
```

В `SECRET_KEY` задайте уникальное случайное production-значение длиной не менее
50 символов. Не добавляйте туда `DATABASE_URL`, `DB_PASSWORD` или PostgreSQL
superuser/replication credentials. Пароль product role извлекается на
orchestration-узле из canonical `POSTGRES_PRODUCT_AI_RETAIL_MVP_PASSWORD`.

## Support images

Redis и Nginx не скачиваются с vps3. Рабочая станция разрешает `redis:7-alpine`
и `nginx:alpine` в exact `linux/amd64` digests, формирует единый tar с checksum и
передаёт его через vps6.

```powershell
.\tools\services\service_remote.ps1 site_runtime stage-support-images `
  -Limit vps3 `
  -Check
```

После проверки выполнить staging и повторить его для доказательства
идемпотентности:

```powershell
.\tools\services\service_remote.ps1 site_runtime stage-support-images -Limit vps3
.\tools\services\service_remote.ps1 site_runtime stage-support-images -Limit vps3
```

Второй запуск должен сообщить `already_loaded: true` и `changed=0`.

## Apply check

```powershell
.\tools\services\service_remote.ps1 site_runtime apply `
  -Instance ai-retail-mvp `
  -ImageRef ghcr.io/airiga1897/ai_e_retail@sha256:b1d1c78bda98f46953c96b197124be1d39182fa2c5d89de35470c6a3f8de5b56 `
  -Limit vps3 `
  -Check
```

Check mode проверяет product/support receipts, exact image IDs, application
network, работающий `platform_router`, secret contract, будущий takeover
phase-1 probe, отсутствие unmanaged private media и `docker compose config`.
Resolved contract выводит digest-specific static volume, persistent
public/private media и количество unmanaged entries без имён файлов. Временные файлы удаляются. Наборы
контейнеров и volumes до и после проверки должны совпасть; probe остаётся
работать без изменений.

## Canonical PostgreSQL audit перед rollout

Перед реальным запуском выполнить read-only audit трёх PostgreSQL-узлов:

```powershell
.\tools\services\audit_runtime_cleanup.ps1 -Aliases vps8,vps4,vps9
```

Audit сверяет отчёт с `operator/postgres/config.yml` и `operator/state.csv`.
Он требует primary на vps8, два streaming/async подключения через
`172.30.8.2`, standby с активными WAL receivers на vps4/vps9 и точные
product/replication HBA-правила без публичных CIDR. При расхождении скрипт
сохраняет JSON/Markdown отчёты и возвращает ненулевой код.

## Реальный private apply

После отдельного разрешения та же команда без `-Check` остановит phase-1 probe,
запустит anchor и Redis, заполнит новый release static volume, один раз выполнит
`python manage.py migrate --noinput`, затем запустит web/worker/beat/Nginx и проверит `/healthz/`, `/readyz/` и
`/worker-healthz/`. Deployment journal сохраняет digest, Compose checksum,
storage identities, результаты static/migration/health и финальный статус.
Предыдущий static volume сохраняется; автоматический rollback схемы и runtime
не выполняется.

После health выполняется единая read-only приёмка `runtime_acceptance`. Она
проверяет работающие anchor/Redis/web/worker/beat/Nginx, отсутствие оставшихся
static/migration containers и host ports, exact image IDs, storage mounts,
`current.json` и успешный deployment journal. Private filenames и секреты в
вывод не попадают.

Если финальная приёмка нового deployment завершается ошибкой, journal получает
`final_status=failed`, а `current.json` возвращается к предыдущему принятому
receipt. Контейнеры и схема автоматически не откатываются; повторный apply до
анализа сохранённого job log запрещён.

Повтор той же команды с тем же digest должен получить `already_current=true`,
пропустить `collectstatic` и migrations и выполнить только health и финальную
read-only приёмку. После этого PostgreSQL audit повторяется.
