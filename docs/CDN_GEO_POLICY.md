# CDN, GeoIP, GeoDNS Plan

Этот документ фиксирует общий план для CDN, GeoIP/GeoPolicy и GeoDNS в AI
Service Platform.

## Цель

Нужен один общий слой гео-решений, но разные способы применения для разных
типов трафика:

- сайты: ускорение, защита, кеширование;
- VPN: выбор ближайшего входа и будущая проверка ускорения SSTP;
- исходящий VPN-трафик: выбор страны выхода;
- защита edge: списки стран, allowlist, blacklist, rate limit.

## Site CDN

CDN для сайтов рассматривается как будущий слой перед публичным web edge.

Применяется к:

- `AromaFlowAI` public web traffic;
- `AI_E_Retail` public web traffic;
- static assets;
- media assets после отдельного решения по storage policy.

Не применяется к:

- SoftEther management `5555/tcp`;
- database traffic;
- private node overlay traffic;
- VPN как к обычному HTTP-сайту.

Ожидаемые функции:

- cache static assets;
- TLS на edge;
- WAF или базовая фильтрация ботов;
- rate limiting;
- origin shielding, если провайдер поддерживает.

## Shared GeoPolicy

GeoPolicy должен быть одним общим источником данных и решений. Это не значит,
что одно правило применяется ко всему трафику. Один сервис готовит данные, а
исполнение остается раздельным.

GeoPolicy outputs:

- HAProxy country lists для защиты сайтов и edge endpoints;
- VPN GeoDNS targets для выбора ближайшего VPS;
- egress country rules для выбора страны выхода VPN-трафика;
- CDN country policy inputs для CDN/WAF правил.

Safety rules:

- сначала dry-run;
- обязательный audit log;
- ручной override;
- изменения маршрутов и списков должны быть откатываемыми.

## GeoDNS For VPN

Для VPN входа базовая идея такая:

```text
vpn.example.com
  Russia users     -> VPS3 Russia
  Kazakhstan users -> VPS2 Kazakhstan
  Europe users     -> VPS1 Latvia
```

GeoDNS выбирает ближайший или наиболее подходящий VPS до подключения клиента.
После DNS выбора клиент подключается уже к конкретному IP.

GeoDNS не заменяет firewall, HAProxy allowlist, healthcheck или monitoring.

## SSTP Acceleration Research

SSTP использует `TCP/443`, поэтому его можно отдельно исследовать через сервисы
уровня TCP:

- Anycast provider;
- L4 TCP proxy provider;
- Cloudflare Spectrum-like service;
- другой TCP acceleration provider.

Это не то же самое, что обычный CDN для сайтов. Обычный web-CDN ожидает HTTP
или HTTPS сайт и может мешать VPN-протоколу. Для SSTP нужен режим, который
проксирует TCP-трафик без превращения его в web request.

Research constraints:

- тестировать только `443/tcp`, `992/tcp`, `1194/tcp`;
- не проксировать `5555/tcp` management;
- сначала тестовый hostname, не production `vpn.example.com`;
- обязательный rollback на direct GeoDNS-to-VPS;
- сравнить latency, stability, reconnect behavior и client IP behavior.

## Current Decision

- Site CDN: future optional для public websites.
- GeoPolicy: planned shared platform service.
- VPN nearest entry: GeoDNS first.
- VPN acceleration: future research через Anycast/L4 TCP proxy, не через
  обычный web-CDN.
- SoftEther остается platform VPN service на VPS1, VPS2 и VPS3.
