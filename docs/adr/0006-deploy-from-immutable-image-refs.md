# 0006. Деплой из неизменяемых Docker image refs

- **Статус:** Accepted
- **Дата:** 2026-05-15

## Контекст

Имена веток («задеплой `main`», «задеплой `develop`») удобны, но неоднозначны: одно и то же имя со временем разрешается в разный код, и rollback становится невозможен без внешнего учёта. Продуктовые репозитории уже собирают контейнерные образы; единственный осмысленный юнит деплоя между двумя продуктовыми репозиториями и тремя VPS-узлами — это image ref.

Это уже зашито как `platform.source_policy.preferred_deploy_artifact: immutable_docker_image_ref` в [`services.yml`](../../services.yml).

## Решение

Артефакты деплоя — **неизменяемые Docker image refs** (digest или коммит-SHA-тег). Имена веток существуют только как политика сборки/источников.

- `platform.source_policy.preferred_deploy_artifact` равно `immutable_docker_image_ref`.
- `platform.source_policy.deploy_from_archives` равно `false`.
- `platform.source_policy.branch_names_are_build_policy_only` равно `true`.
- Per-project `source.deploy_refs.preferred` равно `image_ref`.
- Значения `bootstrap_ref` в `projects.*.source.bootstrap_ref` — **временные** до появления продуктовых `develop` / `main` / релиз-тегов; они всегда перечислены в `allowed_source_refs` и удаляются после promotion (см. [`docs/DEPLOYMENT.md`](../DEPLOYMENT.md)).
- Rollback использует ранее задеплоенный image ref; он не делает re-checkout ветки.

## Последствия

- Плюс: каждый деплой воспроизводим, rollback механический.
- Плюс: продуктовый CI владеет сборкой и тегированием; платформенный CI никогда не компилирует продуктовый код.
- Компромисс: требует работающего image registry и стабильной дисциплины тегирования образов в продуктовых репо.
- Дальнейшее: записи `bootstrap_ref` — техдолг и должны удаляться по мере стабилизации продуктовых веток.

## Рассмотренные альтернативы

- **Деплой из git-refs.** Отвергнуто — не воспроизводимо (изменяемые ветки), связывает деплой с source checkout.
- **Деплой из архивов.** Явно отвергнуто через `source_policy.deploy_from_archives: false` — та же проблема воспроизводимости плюс непрозрачное происхождение.

## Ссылки

- `platform.source_policy`, `projects.*.source.deploy_refs` в [`services.yml`](../../services.yml)
- [`docs/DEPLOYMENT.md`](../DEPLOYMENT.md)
- [`docs/CI_CD.md`](../CI_CD.md)
