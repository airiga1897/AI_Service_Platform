# HAProxy Edge

В этом каталоге лежат рендеры HAProxy-конфигов платформы. Шаблоны и
генератор живут в `tools/render-edge/`; источник истины по
маршрутизации, портам и SNI — `services.yml` (`runtime_instances.*.domains`,
`platform.edge_vpn.ports`).

Архитектура edge (HAProxy + per-site Nginx + SoftEther) описана в
[ADR-0005](../../../docs/adr/0005-edge-haproxy-nginx-softether.md).
Роль HAProxy в SoftEther-маршрутизации — в
[`docs/SOFTETHER_VPN.md`](../../../docs/SOFTETHER_VPN.md).

Файлы `*.example` рядом — справочные фрагменты для проектирования
шаблонов; в активной маршрутизации их использовать не нужно. Не
коммитить hardcoded имена продуктов, реальные IP или секреты.
