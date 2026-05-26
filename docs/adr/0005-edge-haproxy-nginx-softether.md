# 0005. Платформенный edge: HAProxy + per-site Nginx + SoftEther

- **Статус:** Accepted
- **Дата:** 2026-05-15

## Контекст

Публичный трафик, TLS, обновление сертификатов и VPN-ingress должны обслуживаться согласованным edge-слоем, который стоит **перед** продуктовыми рантаймами и не принадлежит ни одному отдельному продукту. Историческая инфраструктура уже использовала HAProxy для SNI-маршрутизации и SoftEther для VPN; продуктовые команды не должны иметь возможности молча перекраивать этот edge.

Контракт edge зашит в `defaults.edge`, `platform.edge_vpn` и `platform.legacy_edge_colocation` в [`services.yml`](../../services.yml) и детализирован в [`docs/SOFTETHER_VPN.md`](../SOFTETHER_VPN.md).

## Решение

Edge платформы состоит из трёх компонентов, принадлежащих инфраструктуре:

1. **HAProxy** — единый публичный TCP entrypoint. Выполняет TLS-SNI маршрутизацию на `443/tcp` между сайтами и SoftEther; форвардит `992/tcp` и `5555/tcp` (management, allowlist) на SoftEther.
2. **Per-site Nginx** — per-runtime обратный прокси перед каждым web-сервисом. Владеет site-level маршрутизацией, выдачей static/media и Certbot для ACME.
3. **SoftEther VPN** — обязательный платформенный компонент, присутствует на **каждом** VPS-узле (VPS1, VPS2, VPS3). Контейнер **не** публикует порты напрямую; порты публикует только HAProxy. UDP-listener-ы явно опциональны и относятся к будущему.

Жёсткие ограничения (уже проверяются валидатором):

- `runtime_instances.*` не должны объявлять `edge_vpn`.
- `runtime_instances.*.containers.current` не должны включать `softether`.
- `platform.edge_vpn.publish_model.softether_container_publish_directly` равно `false`.
- VPN-management на `5555/tcp` — только IP-allowlist.

Стандартный web-CDN — **не** транспорт VPN по умолчанию; ускорение VPN исследуется отдельно (см. `platform.vpn_acceleration` и [`docs/CDN_GEO_POLICY.md`](../CDN_GEO_POLICY.md)).

## Последствия

- Плюс: новый рантайм не может случайно занять edge-порты или сломать VPN.
- Плюс: TLS, ACME и rate limiting живут в одном месте на сайт, а не разбросаны по приложениям.
- Компромисс: добавление нового сайта требует и записи HAProxy SNI, и per-site Nginx-конфига — кодифицируется через шаблоны генератора.
- Дальнейшее: render-compose и генерация edge-конфигов должны держать эту разметку (отдельная задача).

## Рассмотренные альтернативы

- **Один ingress (Traefik / только Nginx).** Отвергнуто — не обрабатывает чисто не-HTTP TCP (SoftEther 992/5555) под единым SNI-entrypoint с per-domain маршрутизацией.
- **Per-runtime ingress-контейнеры.** Отвергнуто — позволило бы продуктовому рантайму случайно конкурировать с edge платформы за порты.
- **SoftEther, публикующий порты напрямую.** Отвергнуто — конфликтует с HTTPS-сайтами на `443/tcp` и обходит rate limiting и allowlist HAProxy.

## Ссылки

- `platform.edge_vpn`, `platform.legacy_edge_colocation`, `defaults.edge` в [`services.yml`](../../services.yml)
- [`docs/SOFTETHER_VPN.md`](../SOFTETHER_VPN.md)
- [`docs/CDN_GEO_POLICY.md`](../CDN_GEO_POLICY.md)
- [`docs/VPS_ROLES.md`](../VPS_ROLES.md)
