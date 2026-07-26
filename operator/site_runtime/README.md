# Операторский intent Site Runtime

Контракт будущей публикации `ai-retail-mvp` проверяется только командой
`site_runtime publication-check ... -Check`. Пока
`publication.public_route_enabled=false`, команда без check-mode запрещена и
edge/runtime не изменяются. Подробности находятся в
`docs/codex/plans/site-runtime-publication.md`.

Future ACME/TLS storage проверяется через
`site_runtime publication-prepare ... -Check`. Реальный вызов без `-Check`
создаёт volumes и обновляет только Nginx через отдельный Compose overlay.
Оба режима не запрашивают сертификат и не подключают HAProxy к application
network.

HTTP-01 ingress сначала проверяется командой
`site_runtime publication-http01 ... -Check`. Она не записывает HAProxy config,
не подключает edge container к application network и сохраняет внешний ACME
placeholder со статусом `404`. Отдельно разрешённый вызов без `-Check`
подключает только `edge-haproxy` к private application network, применяет
host-scoped ACME route и принимает временный marker извне. Сертификат,
HTTPS-route и публичный root приложения этим действием не создаются. При ошибке
восстанавливаются предыдущий HAProxy config и исходное network attachment.

Для TLS contact email хранится только в ignored `instances.yml` в поле
`publication.acme_contact_email`. Certbot доставляется существующей командой
`stage-support-images`: Redis, Nginx и Certbot закреплены в canonical model по
принятым exact digest для `linux/amd64`; рабочая станция формирует tar/manifest
и передаёт образы через orchestration-узел. `vps3` не скачивает их из registry.

Перед реальным запросом сертификата выполняется строго read-only команда
`site_runtime publication-certificate ... -Check`. Она проверяет принятый
HTTP-01 route, exact Certbot receipt/image, ACME/TLS volumes и read-only mounts
Nginx, но не создаёт контейнер Certbot, challenge-файл или сертификат. Вызов
без `-Check` является отдельным операторским рубежом: запускает только exact
Certbot с `--pull never` через network namespace anchor, принимает сертификат и
пишет journal. HTTPS/SNI route, public root и application env не изменяются.

После сертификата команда `site_runtime publication-https ... -Check`
проверяет только prospective HAProxy SNI, Nginx TLS и production
`ALLOWED_HOSTS`/`CSRF_TRUSTED_ORIGINS`. Она не записывает конфигурацию, не
перезапускает контейнеры и не открывает приложение. Отдельно подтверждённый
вызов без `-Check` транзакционно применяет environment/Nginx, принимает private
health, открывает только HTTPS SNI route к Nginx и выполняет внешнюю
health/security-проверку. При ошибке предыдущая закрытая конфигурация
восстанавливается; Gunicorn, Redis, PostgreSQL и `private_media` публичными не
становятся.

`instances.yml` — источник истины для размещения generic site runtime и его
приватной сети. Файл хранится локально у оператора и синхронизируется на
активный orchestration-узел через remote wrapper.

Не записывайте сюда image refs, GHCR tokens, Docker credentials или историю
развёртываний. Image ref является входом транзакции; принятые артефакты
фиксируются в receipt, а позднее — в deployment journal.

В версии 1 на одном alias разрешён только один site instance.
