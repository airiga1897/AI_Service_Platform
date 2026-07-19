# Стек aromaflow-work

Рантайм-инстанс рабочего сайта AromaFlowAI (prod — VPS1, preprod — VPS2).
Контракт см. в `services.yml -> runtime_instances.aromaflow-work`.

## Файлы

- `docker-compose.aromaflow-work.yml` — **сгенерирован** инструментом
  [`tools/render-compose`](../../../tools/render-compose/README.md) из
  `services.yml` и шаблона `django-site`. Не редактируйте вручную —
  перезапустите генератор.

Перегенерировать после правки `services.yml`:

```bash
python3 tools/render-compose/render_compose.py --stack aromaflow-work
```

Проверить, что файл на диске соответствует `services.yml` (для CI):

```bash
python3 tools/render-compose/render_compose.py --stack aromaflow-work --check
```

Реальные секреты (например, `.env.aromaflow.work`) здесь не лежат — они
живут вне репозитория согласно платформенной политике секретов.
