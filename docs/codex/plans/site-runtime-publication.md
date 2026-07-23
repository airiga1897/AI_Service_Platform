# Публикация `ai-retail-mvp`

## Текущий рубеж

На ветке `codex/feature/aieretail03` подготовлен только read-only контракт будущей
публикации. Он не изменяет DNS, сертификаты, Compose, контейнеры или HAProxy.

- production-домен: `retail.travelltickets.ru`;
- ожидаемая DNS-запись: CNAME на `vps3.mine-craft.su`;
- единственный ingress: `vps3`;
- HTTP backend `172.31.3.10:8080` предназначен только для HTTP-01 challenge;
- HTTPS передаётся HAProxy в TCP/SNI passthrough на Nginx `172.31.3.10:8443`;
- TLS завершается в site Nginx;
- публичные health endpoints: `/healthz/` и `/readyz/`;
- `/worker-healthz/` остаётся private;
- Gunicorn, Redis, PostgreSQL и `private_media` публично не доступны;
- `public_route_enabled=false` до отдельного операторского разрешения.

## Локальная проверка модели

```powershell
python .\tools\site_runtime\resolve_publication.py `
  --registry .\services.yml `
  --instances .\operator\site_runtime\instances.yml `
  --state .\operator\state.csv `
  --instance ai-retail-mvp `
  --limit vps3
```

Команда выводит будущие HAProxy/Nginx-фрагменты и их SHA-256, но ничего не
записывает и не применяет.

## Удалённая read-only проверка

```powershell
.\tools\services\service_remote.ps1 site_runtime publication-check `
  -Instance ai-retail-mvp `
  -Limit vps3 `
  -Check
```

Команда проверяет canonical model, текущее DNS-разрешение, private application
network, действующий edge HAProxy и отсутствие host ports у runtime. Отсутствие
подключения HAProxy к application network на этом рубеже ожидаемо и выводится как
планируемое изменение.

Вызов без `-Check` штатно запрещён.

## Подготовка ACME/TLS storage

Canonical model резервирует два persistent Docker volume:

- `ai_retail_mvp_acme_webroot` → `/var/www/acme`, read-only для Nginx;
- `ai_retail_mvp_tls` → `/etc/letsencrypt`, read-only для Nginx.

Certbot в будущем получает к ним read-write доступ только как управляемый
one-shot процесс. Сертификат на этом рубеже не запрашивается.

```powershell
.\tools\services\service_remote.ps1 site_runtime publication-prepare `
  -Instance ai-retail-mvp `
  -Limit vps3 `
  -Check
```

Команда проверяет существующий `current.json` и Compose, наличие будущих volume
без их создания и выводит:

- текущие deployment/Compose identities;
- future Compose contract checksum;
- checksums ACME-only Nginx, Compose override и HAProxy ACME fragment;
- `volumes_created=false`, `certificate_requested=false`;
- `runtime_changed=false`, `edge_changed=false`.

Публичный HTTP server в future-render обслуживает только
`/.well-known/acme-challenge/`, а на остальные пути отвечает `404`.

После успешного `-Check` реальный preparation выполняется отдельной командой:

```powershell
.\tools\services\service_remote.ps1 site_runtime publication-prepare `
  -Instance ai-retail-mvp `
  -Limit vps3
```

Реальный вызов под общим instance lock:

1. создаёт persistent ACME/TLS volumes, если они отсутствуют;
2. записывает отдельный `docker-compose.publication.yml` и ACME-only Nginx config;
3. проверяет объединённый Compose;
4. пересоздаёт только Nginx, не запуская `collectstatic` и migrations;
5. принимает private health, read-only mounts и `404` публичного root;
6. записывает отдельный append-only publication journal.

Application `current.json` и базовый `docker-compose.yml` не изменяются. HAProxy
не подключается к application network, сертификат не запрашивается и внешний
маршрут не появляется. Повторный вызов должен вернуть `already_prepared=true`
без пересоздания Nginx.

## Следующие отдельные рубежи

Перед реальным подключением edge выполняется check-only HTTP-01 contract:

```powershell
.\tools\services\service_remote.ps1 site_runtime publication-http01 `
  -Instance ai-retail-mvp `
  -Limit vps3 `
  -Check
```

Команда принимает publication preparation receipt и Nginx mounts, строит
prospective HAProxy config в памяти, проверяет его через работающий HAProxy и
подтверждает текущий внешний `404` placeholder. Файлы HAProxy, Docker networks,
сертификаты и runtime не изменяются. Будущий route ограничен одновременно
точным `Host: retail.travelltickets.ru` и префиксом
`/.well-known/acme-challenge/`; остальные ACME hosts сохраняют placeholder.

После принятого `-Check` отдельным операторским разрешением выполняется тот же
интерфейс без `-Check`:

```powershell
.\tools\services\service_remote.ps1 site_runtime publication-http01 `
  -Instance ai-retail-mvp `
  -Limit vps3
```

Реальный вызов сериализован общим instance lock и выполняет только HTTP-01
рубеж:

1. сохраняет snapshot действующего HAProxy config;
2. подключает только `edge-haproxy` к `ai_service_app_vps3`;
3. атомарно записывает уже проверенный host-scoped route и перезапускает HAProxy;
4. создаёт временный marker в ACME webroot и принимает его извне со статусом
   `200`;
5. удаляет marker и записывает append-only journal/current receipt.

При ошибке предыдущий HAProxy config и исходное network attachment
восстанавливаются. Повторный вызов идемпотентен: route и сеть не применяются
повторно, выполняется только внешняя приёмка. Сертификат не запрашивается,
HTTPS-route не создаётся, публичный root приложения остаётся закрытым.

Следующие отдельные рубежи:

1. Получить сертификат Let's Encrypt и проверить цепочку/renewal.
2. Включить SNI-маршрут HTTPS и production env.
3. Принять внешние health endpoints и доказать отсутствие публичного доступа к
   внутренним сервисам и `private_media`.

Каждый реальный шаг требует отдельного подтверждения. Seed, superuser и S3-копия
в этот контракт не входят.
