# 0007. Единый общий источник данных GeoPolicy

- **Статус:** Accepted
- **Дата:** 2026-05-15

## Контекст

Гео-решения нужны в нескольких несвязанных местах: HAProxy country lists для защиты сайтов, GeoDNS для выбора ближайшего входа VPN, выбор страны egress для VPN-трафика и country-входы для будущего сайтового CDN. Если каждый слой держит свои country/IP-данные, списки расходятся, решения разъезжаются, и «фикс» в одном месте молча регрессирует другой.

Это уже описано в `platform.geo_policy` в [`services.yml`](../../services.yml) и в [`docs/CDN_GEO_POLICY.md`](../CDN_GEO_POLICY.md).

## Решение

Существует **один** общий источник GeoPolicy для country/IP-данных. **Применение остаётся раздельным по типу трафика.**

- `platform.geo_policy.status` равен `planned-shared-platform-service`.
- `platform.geo_policy.data_outputs` перечисляет потребителей: `haproxy_country_lists`, `vpn_geodns_targets`, `egress_country_rules`, `cdn_country_policy_inputs`.
- `enforcement_boundaries` фиксирует, что защитой сайтов владеет HAProxy (или будущий CDN), ближайшим VPN-входом — GeoDNS, выбором egress VPN — routing-policy controller, а продуктовая HA **не** обрабатывается GeoPolicy.
- Безопасность: сначала dry-run, обязательный audit log, обязательный ручной override (`platform.geo_policy.safety`).
- Правило защиты сайтов никогда не должно молча сломать VPN-доступ или продуктовый failover.

## Последствия

- Плюс: одно место для обновления country-данных, четыре согласованных применения.
- Плюс: edge-защита, маршрутизация VPN и политика CDN остаются развязанными на уровне применения.
- Компромисс: сам сервис GeoPolicy ещё не существует (`planned-…`); пока он не выйдет, отдельные слои держат свои списки с обязательством мигрировать.
- Дальнейшее: когда GeoPolicy будет реализован, заменить этот ADR новым, описывающим реальный интерфейс и rollout.

## Рассмотренные альтернативы

- **Per-layer country-списки.** Сегодняшнее де-факто состояние. Отвергнуто как долгосрочный план, потому что исторически вызывало дрейф между списками HAProxy и ожиданиями VPN/CDN.
- **Единый движок применения для всех гео-решений.** Отвергнуто — связывает защиту сайтов, VPN и CDN; одно правило могло бы сломать несвязанные типы трафика.

## Ссылки

- `platform.geo_policy`, `platform.edge_protection`, `platform.vpn_acceleration` в [`services.yml`](../../services.yml)
- [`docs/CDN_GEO_POLICY.md`](../CDN_GEO_POLICY.md)
- [ADR-0005](0005-edge-haproxy-nginx-softether.md)
