# `tools/render-edge`

Генератор edge-конфигов платформы (HAProxy + per-site Nginx) из
`services.yml`. Параллелен `render-compose`, использует общий загрузчик
`tools/_lib/registry.py`.

## Что генерируется

- `infra/edge/haproxy/haproxy.cfg` — единый конфиг HAProxy с
  HTTP/HTTPS frontend'ами, SNI-маршрутизацией на per-site Nginx и
  TCP-блоком SoftEther (443/992/1194/5555 mgmt).
- `infra/edge/nginx/sites/<instance>.conf` — один reverse-proxy
  на каждый рантайм-инстанс типа `site`. Telegram-боты пропускаются.

## CLI

```bash
# Сгенерировать всё в дефолтные пути
python3 tools/render-edge/render_edge.py

# Только проверить дрейф (для CI / pre-commit)
python3 tools/render-edge/render_edge.py --check

# Альтернативные пути / реестр
python3 tools/render-edge/render_edge.py \
    --registry path/to/services.yml \
    --haproxy-out path/to/haproxy.cfg \
    --nginx-out-dir path/to/sites/
```

Exit-коды:

- `0` — всё успешно (сгенерировано или совпадает в `--check`).
- `1` — режим `--check`: содержимое разошлось с диском.
- `2` — ошибка конфигурации (нет `services.yml`, плохая структура,
  неизвестный проект и т.п.).

## Откуда что берётся

| Что в шаблоне | Откуда в `services.yml` |
|---|---|
| SNI-маршрут для сайта | `runtime_instances.<name>.domains.prod` |
| Имя backend-контейнера | `runtime_instances.<name>.containers.future`, суффикс `-backend` или `-web` |
| Имя nginx-контейнера | `runtime_instances.<name>.containers.future`, суффикс `-nginx` |
| TCP-порты SoftEther | `platform.edge_vpn.ports.tcp` |
| Management-порт | `platform.edge_vpn.security.management_port` |

Архитектурное обоснование — [ADR-0005](../../docs/adr/0005-edge-haproxy-nginx-softether.md).

## Шаблоны

В `templates/` используются нестандартные jinja-разделители (`<<` / `>>`,
`<%` / `%>`, `<#` / `#>`), как и в `render-compose`, чтобы литеральные
shell-подстановки в конфигах не приходилось экранировать.
