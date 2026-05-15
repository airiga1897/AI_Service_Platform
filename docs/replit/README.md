# Планы Replit-сессии

Этот каталог — **снапшот текущего плана работ Replit-сессии**. Каждый файл в [`plans/`](plans) соответствует 1:1 проектной задаче, созданной в этой Replit-сессии, и зеркалирует план, который лежит в `.local/tasks/` рабочего окружения (он не коммитится в git).

Это **не** запись об архитектуре. Архитектурные решения живут в [`../adr/`](../adr/README.md).

Это **не** runbook. Операционные процедуры живут в [`../RUNBOOKS.md`](../RUNBOOKS.md).

## Назначение

- Сделать план работ Replit-сессии доступным для ревью в PR-ах и видимым любому, кто читает репозиторий на GitHub.
- Сохранить исходный скоуп («What & Why», «Done looks like», «Out of scope», «Steps») для каждой задачи даже после её завершения и удаления рабочих файлов в `.local/tasks/`.

## Планы в этом снапшоте

| План | Заголовок |
|------|-----------|
| [`plans/01-adr-and-platform-vision-docs.md`](plans/01-adr-and-platform-vision-docs.md) | ADR и видение платформы в docs |
| [`plans/02-extend-services-yml-validator.md`](plans/02-extend-services-yml-validator.md) | Расширение валидатора `services.yml` |
| [`plans/03-render-compose-tool.md`](plans/03-render-compose-tool.md) | Реализация `tools/render-compose` |
| [`plans/04-healthcheck-tool.md`](plans/04-healthcheck-tool.md) | Реализация `tools/healthcheck` |
| [`plans/05-ci-and-precommit-integration.md`](plans/05-ci-and-precommit-integration.md) | CI и pre-commit интеграция |

## Соглашения

- Имена файлов зеркалируют файлы планов в `.local/tasks/`.
- Планы написаны на русском (рабочий язык этой сессии); вся остальная документация в `docs/` и ADR также на русском.
- Планы — снапшоты только на добавление: при изменении скоупа предпочтительнее завести новый файл плана и оставить короткую заметку в старом, а не переписывать историю.
