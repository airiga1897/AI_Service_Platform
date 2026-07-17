# Единый storage-контракт для site runtime

## Назначение

Документ фиксирует целевое разделение release-артефактов и пользовательских
данных для `AI_E_Retail`, будущих экземпляров AromaFlow и других сайтов.
Пользовательские загрузки не должны попадать в `STATIC_ROOT`, `frontend/dist`
или файловую систему immutable image.

Этот контракт пока является направлением развития. Он не расширяет текущую
модель `site_runtime` и не разрешает public route или реальный deployment.

## Классы хранения

| Класс | Примеры | Жизненный цикл | Доступ runtime | Публикация |
|---|---|---|---|---|
| `release_static` | JS, CSS, Django admin, собранный SPA | связан с release digest | one-shot writer; затем read-only | Nginx `/static/` |
| `public_media` | фотографии товаров и масел, публичные логотипы | persistent, независимо от deployment | web/worker read-write | Nginx `/media/` read-only |
| `private_media` | сертификаты, инструкции, RAG-файлы, внутренние документы | persistent, независимо от deployment | только авторизованные backend/worker | через backend с проверкой прав |
| `temporary` | CSV/XLSX import, распаковка архивов, quarantine | ephemeral с TTL | только обработчик | не публикуется |
| `exports` | отчёты и сформированные выгрузки | ограниченный retention | генератор и авторизованный backend | авторизованная или подписанная ссылка |

## Обязательные правила

- `collectstatic` пишет только в `STATIC_ROOT`; пользовательские файлы никогда
  не сохраняются в static volume.
- One-shot контейнер заполняет static volume до migrations и запуска runtime.
  После подготовки web и Nginx должны получать static read-only.
- Public media монтируется read-write только в компоненты, которые принимают
  или обрабатывают загрузки, и read-only в Nginx.
- Private media не монтируется в Nginx и выдаётся только backend после проверки
  пользователя, объекта и разрешённой операции.
- В PostgreSQL хранится относительный путь или object key. Крупные файлы не
  сохраняются в строках базы данных.
- Persistent media имеет отдельные backup, restore, retention и integrity
  проверки и не удаляется при apply, rollback или пересоздании контейнера.
- Upload pipeline проверяет лимит размера, MIME, расширение и фактическое
  содержимое. Изображения декодируются и при необходимости пересохраняются.
- Пользовательские HTML и SVG не обслуживаются с основного origin без санации;
  предпочтительны преобразование в безопасный формат или отдельный download
  origin с `Content-Disposition: attachment`.

## Масштабирование

Для одного VPS допустимы named Docker volumes с регулярным backup/restore.
Перед переходом к нескольким runtime-узлам canonical media storage переносится
в S3-compatible хранилище. Контейнеры остаются stateless, а deployment не
перемещает пользовательские данные.

Static следует версионировать release digest. Новый deployment заполняет новый
volume, проходит health acceptance и только затем переключает Nginx. Failed
`collectstatic` не должен изменять static предыдущего принятого deployment.

## Реализованная canonical model

Generic `site_runtime` использует три обязательных storage-класса:

```yaml
storage:
  release_static:
    lifecycle: release
    volume_prefix: ai_retail_mvp_static
    container_path: /app/staticfiles
    runtime_access: read-only
    nginx: true
  public_media:
    lifecycle: persistent
    volume: ai_retail_mvp_media
    container_path: /app/media
    runtime_access: read-write
    nginx: true
  private_media:
    lifecycle: persistent
    volume: ai_retail_mvp_private_media
    container_path: /app/private_media
    runtime_access: read-write
    nginx: false
```

Resolver добавляет к `release_static.volume_prefix` полный release digest.
One-shot `static` получает итоговый volume read-write; web и Nginx используют
его read-only. Public media остаётся persistent и доступен web/worker, а Nginx
читает его read-only. Private media доступен только web/worker и не монтируется
в Nginx.

Перед первым подключением durable private media apply проверяет старые web и
worker containers. Если в немонтированном `/app/private_media` есть записи,
rollout останавливается без вывода имён файлов и требует отдельного import.
Старые static volumes автоматически не удаляются.

Классы `temporary` и `exports`, S3-compatible storage и backup automation
остаются отдельным production-hardening этапом до появления публичных загрузок.

Для AromaFlow фотографии масел относятся к `public_media`, а рецептуры,
сертификаты поставщиков и внутренние документы — к `private_media`.
