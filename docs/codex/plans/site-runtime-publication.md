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

## Подготовка Certbot support image

Перед certificate tooling повторяется существующий support-image staging:

```powershell
.\tools\services\service_remote.ps1 site_runtime stage-support-images `
  -Limit vps3 `
  -Check
```

Bundle теперь содержит Redis, Nginx и Certbot, причём все три source ref
закреплены по принятым exact digest. Это исключает незапланированную смену
Nginx или Redis при добавлении Certbot. Manifest фиксирует полный distribution
digest, config image ID и `linux/amd64`, после чего tar передаётся через `vps6`.
`vps3` не обращается к registry. Реальный staging и его идемпотентный повтор
приняты до certificate preflight.

Contact email Let’s Encrypt хранится только в ignored operator model
`publication.acme_contact_email`; для `ai-retail-mvp` принят
`airiga1897@gmail.com`.

## Read-only preflight TLS-сертификата

После принятого support-image staging выполняется:

```powershell
.\tools\services\service_remote.ps1 site_runtime publication-certificate `
  -Instance ai-retail-mvp `
  -Limit vps3 `
  -Check
```

Action разрешён только с `-Check` и сериализован общим lock экземпляра. Он
проверяет:

- exact Certbot receipt, config image ID и `linux/amd64`;
- существующие ACME/TLS volumes и canonical ownership labels;
- read-only ACME/TLS mounts работающего Nginx;
- действующий anchor для будущего network namespace Certbot;
- точное наличие принятого host-scoped HTTP-01 route и edge network attachment;
- HTTP redirect закрытого root на точный HTTPS URL без перехода к ещё не
  включённому TLS endpoint, а также `404` для отсутствующего challenge;
- неизменность списка контейнеров, volumes, `current.json`, Compose и HAProxy.

Проверка может сообщить наличие уже выпущенного `fullchain.pem`, но не читает
закрытый ключ и не выводит contact email. Контракт будущего запуска фиксирует
webroot, TLS path, non-interactive mode, согласие с ToS и
`--keep-until-expiring`, но Certbot в check-mode не запускается. Сертификат,
HTTPS/SNI route и публичный root приложения не создаются.

После отдельного подтверждения реальный выпуск выполняется тем же интерфейсом
без `-Check`:

```powershell
.\tools\services\service_remote.ps1 site_runtime publication-certificate `
  -Instance ai-retail-mvp `
  -Limit vps3
```

Транзакция использует только принятый локальный Certbot image с `--pull never`,
без host ports и Linux capabilities, через network namespace anchor. ACME
webroot и TLS volume подключаются Certbot read-write; Nginx продолжает видеть
их read-only. После `certonly --webroot` отдельный one-shot validation проверяет
домен, наличие private key без вывода содержимого и остаточный срок не менее
14 дней. Затем повторяются private health, внешний HTTP-01 `404`, точный
HTTP→HTTPS redirect и проверки неизменности контейнеров, volume identities,
`current.json`, Compose и HAProxy.

Успех записывается в append-only certificate journal и publication
`current.json`. Повтор идемпотентен благодаря `--keep-until-expiring`: если
сертификат действителен, Certbot не выпускает новый. При ошибке известные
временные Certbot containers удаляются, TLS volume сохраняется для диагностики
и записывается failed journal. Автоматического отката или повторного запроса в
том же запуске нет.

Этот action не записывает HTTPS/SNI fragment, не перезапускает HAProxy/Nginx и
не публикует application root. Включение HTTPS остаётся следующим отдельным
рубежом.

## Read-only preflight HTTPS/SNI

После принятого сертификата будущая production-конфигурация проверяется без
записи:

```powershell
.\tools\services\service_remote.ps1 site_runtime publication-https `
  -Instance ai-retail-mvp `
  -Limit vps3 `
  -Check
```

Action без `-Check` запрещён. Проверка:

- принимает действующий certificate receipt и наличие chain/private key без
  вывода их содержимого;
- строит в памяти будущий HAProxy SNI route, добавляя домен в fail-closed
  allow-condition до `silent-drop`, и запускает `haproxy -c` через stdin;
- проверяет будущий Nginx TLS config через закрытый временный файл внутри
  контейнера; `trap` удаляет его при любом завершении, а отдельная проверка
  подтверждает удаление. Действующий ACME-only файл не заменяется;
- строит prospective `runtime.env`: сохраняет внутренний host и все секретные
  значения, добавляет `retail.travelltickets.ru` в `ALLOWED_HOSTS` и точный
  `https://retail.travelltickets.ru` в `CSRF_TRUSTED_ORIGINS`;
- подтверждает неизменность контейнеров, volumes, `current.json`, Compose,
  `runtime.env`, Nginx и HAProxy;
- подтверждает, что HTTP root только перенаправляет на HTTPS, отсутствующий
  challenge возвращает `404`, а SNI route и application root ещё не
  опубликованы.

Результат содержит только checksums и безопасные host/origin identities.
Реальная запись production env, Nginx TLS config и HAProxy SNI route будет
следующим единым операторским рубежом после принятого `publication-https
-Check`.

Каждый реальный шаг требует отдельного подтверждения. Seed, superuser и S3-копия
в этот контракт не входят.
