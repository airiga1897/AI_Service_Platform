# Архитектурные решения (ADR)

В этом каталоге хранятся записи об архитектурных решениях (ADR — Architecture Decision Records) для AI Service Platform.

ADR фиксируют значимые архитектурные решения: их контекст, само решение, статус и последствия. Это не задачи проекта и не roadmap-пункты — они записывают решения, которые уже приняты (или явно предложены), чтобы любой, кто будет читать репозиторий позже, мог понять, *почему* платформа выглядит именно так.

- Формат: [MADR](https://adr.github.io/madr/) — см. [`template.md`](template.md).
- Имя файла: `NNNN-short-kebab-title.md`, четырёхзначная zero-padded последовательность.
- Допустимые статусы: `Proposed` → `Accepted` → `Superseded` (записывайте superseder в обоих ADR).

Это **не** то же самое, что `docs/replit/`. `docs/replit/` — снапшот текущего плана работ Replit-сессии; ADR живут дольше и описывают архитектуру, а не workflow.

## Индекс

| ADR | Заголовок | Статус |
|-----|-----------|--------|
| [0001](0001-record-architecture-decisions.md) | Ведение записей об архитектурных решениях | Accepted |
| [0002](0002-infra-only-repository.md) | Этот репозиторий — только инфра/оркестрация | Accepted |
| [0003](0003-four-runtime-instances.md) | Четыре рантайм-инстанса на старте | Accepted |
| [0004](0004-extensible-service-catalog.md) | `services.yml` — расширяемый каталог сервисов | Accepted |
| [0005](0005-edge-haproxy-nginx-softether.md) | Платформенный edge: HAProxy + per-site Nginx + SoftEther | Accepted |
| [0006](0006-deploy-from-immutable-image-refs.md) | Деплой из неизменяемых Docker image refs | Accepted |
| [0007](0007-shared-geo-policy-service.md) | Единый общий источник данных GeoPolicy | Accepted |
| [0008](0008-vps3-destination-geo-egress-canary.md) | VPS3 destination-based GeoPolicy egress canary | Accepted |

## Как добавить новый ADR

1. Скопировать [`template.md`](template.md) в `NNNN-your-decision.md`, используя следующий свободный номер.
2. Заполнить разделы «Контекст», «Решение», «Статус», «Последствия» и «Дата».
3. Добавить строку в индекс выше.
4. Открыть PR. Решение становится `Accepted` после merge, если явно не помечено как `Proposed`.

## Замена ADR (supersession)

Когда новый ADR заменяет старый:

- Поставить старому ADR статус `Superseded by ADR-NNNN`.
- Поставить новому ADR статус `Accepted (supersedes ADR-MMMM)`.
- Не удалять старый ADR — история важна.
