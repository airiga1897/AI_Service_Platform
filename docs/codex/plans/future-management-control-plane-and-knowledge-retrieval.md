# Future Plan: Management Control Plane And Knowledge Retrieval

## Summary

Этот план фиксирует место двух будущих platform capabilities:

- `management-control-plane`
- `knowledge-retrieval`

Их не нужно реализовывать до завершения базовой платформенной цепочки: bootstrap/operator workflow, Ansible provisioning и первый стабильный deploy/rollback.

## Implementation Order

1. Завершить bootstrap/operator workflow:
   - `nodes.csv`;
   - bootstrap runner-ы;
   - сохранение ключей в `operator/<alias>/`;
   - real inventory на VPS3.

2. Поднять Ansible provisioning:
   - Docker;
   - security/firewall/fail2ban;
   - monitoring;
   - backup;
   - management tooling;
   - SoftEther как platform edge/VPN capability.

3. Стабилизировать первый deploy/rollback:
   - GitHub Environment/secrets через script-first helper;
   - `ai-retail-dev/preprod` predeploy-check;
   - controlled `docker compose pull/up`;
   - rollback dry-run и затем real rollback.

4. Сделать `management-control-plane` MVP:
   - read-only dashboard;
   - platform roles/nodes из `services.yml` и operator CSV;
   - GitHub workflow status;
   - healthcheck status;
   - ссылки на runbooks, ADR и docs.

5. Добавить `knowledge-retrieval` MVP:
   - semantic search по `docs/`, ADR, runbooks и `services.yml`;
   - индексация deploy/preflight logs и Ansible output;
   - ответы со ссылками на источники;
   - первые сценарии: “что делать дальше?” и “почему deploy упал?”.

6. Только после этого добавить controlled actions:
   - UI запускает GitHub Actions, Semaphore jobs или Ansible на VPS3;
   - production-действия требуют явного подтверждения;
   - AI может рекомендовать действия, но не выполняет опасные операции сам.

## Design Rules

- `management-control-plane` и `knowledge-retrieval` остаются отдельными capabilities.
- Web UI не должен становиться прямым SSH-оркестратором.
- Правильный поток управления:

  ```text
  UI -> GitHub Actions / Semaphore / VPS3 Ansible -> VPS
  ```

- `knowledge-retrieval` использует документацию, registry, логи и историю операций как источники знаний.
- Выбор backend для embeddings/vector search (`pgvector`, `Qdrant` или другой вариант) принимается отдельным планом перед реализацией.

## Test Plan

- Проверить, что этот документ не обещает немедленную реализацию UI или AI-сервиса.
- Проверить, что UI не описан как прямой SSH-доступ к VPS.
- Проверить, что `knowledge-retrieval` отделён от `management-control-plane`.
- Перед будущей реализацией добавить отдельные acceptance criteria для read-only dashboard и retrieval MVP.

## Assumptions

- Реализация начинается после первого стабильного deploy/rollback.
- На момент старта `knowledge-retrieval` уже есть полезные источники данных: docs, ADR, runbooks, deploy logs, Ansible output.
- Первым control plane этапом будет read-only dashboard, а не action-heavy UI.
