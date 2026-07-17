# Ручной backup и репетиция восстановления `site_runtime`

## Граница этапа

Для `ai-retail-mvp` создаётся зашифрованный Restic snapshot базы PostgreSQL,
`public_media` и `private_media`. Release static и Redis в backup не входят.
Repository расположен на `vps5`; управление выполняется с orchestration-узла
`vps6`. Расписание, автоматический prune, S3 и public route не включены.

Источник истины — принятый `current.json`. Backup-команды не принимают новый
образ и не меняют deployment. Все операции одного instance используют единый
lock на orchestration-узле.

## Подготовка секрета

Локальный игнорируемый Git файл
`operator/site_runtime/backup-secrets/ai-retail-mvp.env` содержит только:

```text
RESTIC_PASSWORD=<случайное значение>
```

Секрет передаётся штатным SSH bundle, получает режим `0600` и не выводится в
Ansible output. Потеря этого пароля означает потерю доступа к snapshots.

## Ручной запуск

Сначала выполняются `backup-init -Check`, реальный `backup-init`, затем
`backup -Check` и реальный `backup`. Идентификатор принятого snapshot берётся
только из результата Restic:

```powershell
.\tools\services\service_remote.ps1 site_runtime backup-init `
  -Instance ai-retail-mvp -Limit vps3 -Check

.\tools\services\service_remote.ps1 site_runtime backup-init `
  -Instance ai-retail-mvp -Limit vps3

.\tools\services\service_remote.ps1 site_runtime backup `
  -Instance ai-retail-mvp -Limit vps3 -Check

.\tools\services\service_remote.ps1 site_runtime backup `
  -Instance ai-retail-mvp -Limit vps3
```

Backup временно останавливает только `web`, `worker` и `beat`. Anchor, Redis и
Nginx остаются запущенными. В секции `finally` writers запускаются снова,
проверяются три private health endpoint, а plaintext staging удаляется.

## Репетиция восстановления

```powershell
.\tools\services\service_remote.ps1 site_runtime restore-rehearsal `
  -Instance ai-retail-mvp -SnapshotId <snapshot-id> -Limit vps3 -Check

.\tools\services\service_remote.ps1 site_runtime restore-rehearsal `
  -Instance ai-retail-mvp -SnapshotId <snapshot-id> -Limit vps3
```

Репетиция использует только scratch DB и digest-scoped scratch volumes. Она
сверяет manifest и SHA-256, extension `vector`, актуальность Django migrations
и количество media-объектов. Production DB, volumes и `current.json` не
изменяются. После успеха scratch удаляется; после ошибки сохраняется для
диагностики и фиксируется в restore journal.

## Аварийная остановка

Если backup завершился ошибкой, повторно запускать его нельзя до проверки
durable job log и backup journal на `vps6`. Сначала убедитесь, что writers
восстановлены штатным Compose:

```bash
sudo docker compose -f /opt/ai-service-platform/site-runtime/ai-retail-mvp/docker-compose.yml \
  up -d --no-build --pull never web worker beat
```

Затем повторите private runtime acceptance и canonical PostgreSQL audit.
Не удаляйте Restic snapshot, scratch DB/volumes или staging вручную до фиксации
диагностики. Автоматический rollback схемы и production media запрещён.
