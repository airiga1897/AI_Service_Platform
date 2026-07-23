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

`instances.yml` — источник истины для размещения generic site runtime и его
приватной сети. Файл хранится локально у оператора и синхронизируется на
активный orchestration-узел через remote wrapper.

Не записывайте сюда image refs, GHCR tokens, Docker credentials или историю
развёртываний. Image ref является входом транзакции; принятые артефакты
фиксируются в receipt, а позднее — в deployment journal.

В версии 1 на одном alias разрешён только один site instance.
