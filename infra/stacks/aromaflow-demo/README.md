# Стек aromaflow-demo

Рантайм-инстанс демо-сайта AromaFlowAI (preprod — VPS2; в prod не
выкатывается). Контракт см. в
`services.yml -> runtime_instances.aromaflow-demo`.

## Файлы

- `docker-compose.aromaflow-demo.yml` — **сгенерирован** инструментом
  [`tools/render-compose`](../../../tools/render-compose/README.md) из
  `services.yml` и шаблона `django-site`. Не редактируйте вручную —
  перезапустите генератор.

```bash
python3 tools/render-compose/render_compose.py --stack aromaflow-demo
python3 tools/render-compose/render_compose.py --stack aromaflow-demo --check
```

Реальные секреты (например, `.env.aromaflow.demo`) здесь не лежат.
