# План по CDN, GeoIP и GeoDNS

Этот документ фиксирует общий план для CDN, GeoIP/GeoPolicy и GeoDNS в AI
Service Platform.

## Цель

Нужен один общий слой гео-решений, но разные способы применения для разных
типов трафика:

- сайты: ускорение, защита, кеширование;
- VPN: выбор ближайшего входа и будущая проверка ускорения SSTP;
- исходящий VPN-трафик: выбор egress-профиля;
- защита edge: policy lists, allowlist, blacklist, rate limit.

## CDN для сайтов

CDN для сайтов рассматривается как будущий слой перед публичным web edge.

Применяется к:

- публичному web-трафику `AromaFlowAI`;
- публичному web-трафику `AI_E_Retail`;
- статическим ассетам;
- медиа-ассетам после отдельного решения по storage policy.

Не применяется к:

- управляющему порту SoftEther `5555/tcp`;
- трафику баз данных;
- частному overlay-трафику между узлами;
- VPN как к обычному HTTP-сайту.

Ожидаемые функции:

- кеш статических ассетов;
- TLS на edge;
- WAF или базовая фильтрация ботов;
- rate limiting;
- origin shielding, если провайдер поддерживает.

## Общий GeoPolicy

GeoPolicy должен быть одним общим источником данных и решений. Это не значит,
что одно правило применяется ко всему трафику. Один сервис готовит данные, а
исполнение остаётся раздельным.

Выходы GeoPolicy зафиксированы в [`services.yml`](../services.yml) под ключом `platform.geo_policy.data_outputs`; обоснование — в [ADR-0007](adr/0007-shared-geo-policy-service.md). Перечень ниже — производное для людей:

- HAProxy policy lists для защиты сайтов и edge endpoints;
- VPN GeoDNS targets для выбора ближайшего VPS;
- egress policy rules для выбора выходного профиля VPN-трафика;
- CDN policy inputs для CDN/WAF правил.

Правила безопасности:

- сначала dry-run;
- обязательный audit log;
- ручной override;
- изменения маршрутов и списков должны быть откатываемыми.

## GeoDNS для VPN

Для VPN-входа базовая идея такая:

```text
vpn.example.com
  policy target A -> active VPN edge alias A
  policy target B -> active VPN edge alias B
  fallback        -> healthy default VPN edge alias
```

GeoDNS выбирает ближайший или наиболее подходящий VPS по текущей policy до
подключения клиента.
После DNS-выбора клиент подключается уже к конкретному IP.

GeoDNS не заменяет firewall, HAProxy allowlist, healthcheck или мониторинг.

## Исследование ускорения SSTP

SSTP использует `TCP/443`, поэтому его можно отдельно исследовать через сервисы
уровня TCP:

- Anycast provider;
- L4 TCP proxy provider;
- Cloudflare Spectrum-like service;
- другой TCP acceleration provider.

Это не то же самое, что обычный CDN для сайтов. Обычный web-CDN ожидает HTTP
или HTTPS сайт и может мешать VPN-протоколу. Для SSTP нужен режим, который
проксирует TCP-трафик без превращения его в web request.

Ограничения исследования:

- тестировать только `443/tcp`, `992/tcp`;
- не проксировать `5555/tcp` management;
- сначала тестовый hostname, не production `vpn.example.com`;
- обязательный rollback на direct GeoDNS-to-VPS;
- сравнить latency, stability, reconnect behavior и client IP behavior.

## Текущее решение

- CDN для сайтов: будущая опция для публичных сайтов.
- GeoPolicy: общий контракт принят; VPS3 egress canary реализован, но ещё не
  применён.
- Ближайший вход VPN: сначала через GeoDNS.
- Ускорение VPN: будущее исследование через Anycast/L4 TCP proxy, не через
  обычный web-CDN.
- SoftEther остаётся платформенным VPN-сервисом на VPS1, VPS2 и VPS3.

## VPS3 destination-egress canary (2026-07-28)

Первый реализованный потребитель GeoPolicy — узкий, пока не применённый canary
на VPS3. Он классифицирует новые IPv4-соединения от `172.31.3.10/32`
(`site_runtime`) и `172.20.0.2/32` (VPN после SecureNAT). RU и внутренние
назначения идут напрямую, остальные публичные назначения — через явно принятую
упорядоченный набор egress-путей переменной длины. Для первого canary это
`vps1`, `vps2` и `vps4`.

Этот рубеж не включает ingress GeoDNS, CDN policy, OSPF или BGP. Полный контракт
preflight, failover, last-known-good dataset, manual override и rollback
зафиксирован в
[`geo-policy-vps3-canary.md`](codex/plans/geo-policy-vps3-canary.md).
