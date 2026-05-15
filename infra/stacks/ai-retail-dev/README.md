# Стек ai-retail-dev

Рантайм-инстанс под будущую разработку AI_E_Retail (preprod — VPS2).
Контракт см. в `services.yml -> runtime_instances.ai-retail-dev`.

## Файлы

- `docker-compose.ai-retail-dev.yml` — **сгенерирован** инструментом
  [`tools/render-compose`](../../../tools/render-compose/README.md) из
  `services.yml` и шаблона `django-react-site`. Не редактируйте вручную —
  перезапустите генератор.

```bash
python3 tools/render-compose/render_compose.py --stack ai-retail-dev
python3 tools/render-compose/render_compose.py --stack ai-retail-dev --check
```

Реальные секреты (например, `.env.ai-retail.dev`) здесь не лежат.
