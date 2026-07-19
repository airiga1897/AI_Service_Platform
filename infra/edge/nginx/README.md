# Nginx Edge

В этом каталоге лежат per-site reverse-proxy конфиги, отрендеренные
из `services.yml` (`runtime_instances.*.domains`) генератором из
`tools/render-edge/`. Один файл — один инстанс типа `site`.

Сертификаты владеет связка Nginx + Certbot; SoftEther потребляет
read-only TLS-копию из общего каталога (см.
[`docs/SOFTETHER_VPN.md`](../../../docs/SOFTETHER_VPN.md)). Архитектура
edge — в [ADR-0005](../../../docs/adr/0005-edge-haproxy-nginx-softether.md).

Не коммитить hardcoded имена продуктов, реальные IP или секреты.
