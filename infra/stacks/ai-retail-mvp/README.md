# Стек ai-retail-mvp

Рантайм-инстанс «замороженного» MVP проекта AI_E_Retail (preprod — VPS2).
Контракт см. в `services.yml -> runtime_instances.ai-retail-mvp`.

## Файлы

- `docker-compose.ai-retail-mvp.yml` — **сгенерирован** инструментом
  [`tools/render-compose`](../../../tools/render-compose/README.md) из
  `services.yml` и шаблона `django-react-site`. Не редактируйте вручную —
  перезапустите генератор.

```bash
python3 tools/render-compose/render_compose.py --stack ai-retail-mvp
python3 tools/render-compose/render_compose.py --stack ai-retail-mvp --check
```

Реальные секреты (например, `.env.ai-retail.mvp`) здесь не лежат.
