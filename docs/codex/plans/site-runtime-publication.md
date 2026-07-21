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

## Следующие отдельные рубежи

1. Подготовить ACME webroot и закрытый TLS storage без публичного сайта.
2. Подключить HAProxy на `vps3` к application network и открыть только HTTP-01.
3. Получить сертификат Let's Encrypt и проверить цепочку/renewal.
4. Включить SNI-маршрут HTTPS и production env.
5. Принять внешние health endpoints и доказать отсутствие публичного доступа к
   внутренним сервисам и `private_media`.

Каждый реальный шаг требует отдельного подтверждения. Seed, superuser и S3-копия
в этот контракт не входят.
