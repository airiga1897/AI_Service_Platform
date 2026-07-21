# Backup, retention и репетиция восстановления `site_runtime`

## Граница этапа

Для `ai-retail-mvp` создаётся зашифрованный Restic snapshot базы PostgreSQL,
`public_media` и `private_media`. Release static и Redis в backup не входят.
Repository расположен на `vps5`; управление выполняется с orchestration-узла
`vps6`. Автоматический backup запускается ежедневно в 03:30 МСК со случайной
задержкой до 15 минут. S3 и public route не включены.

Источник истины — принятый `current.json`. Backup-команды не принимают новый
образ и не меняют deployment. Все операции одного instance используют единый
lock на orchestration-узле.

## Автоматическое расписание и retention

Расписание устанавливается отдельно и не является побочным эффектом
`backup-init`:

```powershell
.\tools\services\service_remote.ps1 site_runtime backup-schedule `
  -Instance ai-retail-mvp -Limit vps3 -Check

.\tools\services\service_remote.ps1 site_runtime backup-schedule `
  -Instance ai-retail-mvp -Limit vps3
```

Повторный вызов должен быть идемпотентным. Timer на `vps6` использует
`OnCalendar=*-*-* 03:30:00 Europe/Moscow`, `RandomizedDelaySec=900` и
`Persistent=true`. Он вызывает тот же canonical `site_runtime backup`, что и
операторская команда. Занятый lock останавливает запуск до любых изменений.
Перед первым включением или изменением timer платформа обновляет его systemd
stamp текущим временем: пропущенное окно 03:30 не запускает backup немедленно.

Retention выполняется только после создания snapshot, штатного запуска writers
и успешной private health-проверки. Для instance-тега сохраняются 7 daily,
4 weekly и 6 monthly точек; затем выполняются `prune` и `restic check`. Ошибка
retention не удаляет новый принятый snapshot, но завершает операцию со статусом
`failed`.

Проверка и ручной запуск установленного systemd-маршрута:

```bash
sudo systemctl status ai-service-platform-site-runtime-backup-ai-retail-mvp.timer
sudo systemctl list-timers ai-service-platform-site-runtime-backup-ai-retail-mvp.timer
sudo systemctl start ai-service-platform-site-runtime-backup-ai-retail-mvp.service
sudo journalctl -u ai-service-platform-site-runtime-backup-ai-retail-mvp.service --since today
```

Для аварийного отключения следующих запусков используется
`sudo systemctl disable --now ai-service-platform-site-runtime-backup-ai-retail-mvp.timer`.
Это не удаляет snapshots, repository, секрет или journal. Повторное включение
выполняется штатным `backup-schedule` после диагностики.

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
сверяет manifest и SHA-256, extension `vector`, migration ledger scratch и текущей production DB
и количество media-объектов. Production DB, volumes и `current.json` не
изменяются. После успеха scratch удаляется; после ошибки сохраняется для
диагностики и фиксируется в restore journal.

## Очистка неудачной репетиции

Scratch-объекты после ошибки сохраняются до завершения диагностики. Удалять их вручную запрещено.
Сначала выполняется read-only inventory по точному `rehearsal_id` из failed restore journal:

```powershell
.\tools\services\service_remote.ps1 site_runtime restore-cleanup `
  -Instance ai-retail-mvp -RehearsalId <rehearsal-id> -Limit vps3 -Check
```

После проверки количества scratch DB, volumes и staging запускается та же команда без `-Check`.
Она принимает только journal со статусом `failed`, признаком неизменности production и сохранённой
диагностикой. Результат записывается в отдельный append-only cleanup journal. Завершающий повтор с
`-Check` должен показать нулевой остаток.

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
