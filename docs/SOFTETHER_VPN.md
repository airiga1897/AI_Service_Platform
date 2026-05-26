# SoftEther VPN

SoftEther VPN — первоклассный edge-компонент платформы. Его нельзя удалять или
трактовать как случайное legacy-состояние при миграции с runtime-имён
MyPet01/AromaFlowAI.

SoftEther относится к слою инфраструктуры. Продуктовые рантаймы вроде
`aromaflow-work`, `aromaflow-demo`, `ai-retail-mvp` и `ai-retail-dev` могут
маршрутизироваться через общий edge, но не владеют VPN-сервисом.

Целевое состояние: SoftEther работает на каждом active VPN/edge alias из
`state.csv`, например `vps1`, `vps2` или `vps3`.

Существующая сохранённая установка — только TCP. UDP-протоколы VPN — будущая
опция, а не обязательные текущие listener-ы.

В дальнейшем можно добавлять новые VPN-only edge-узлы без географических
assumptions в документации. На таких узлах работают HAProxy TCP entrypoints,
SoftEther, мониторинг и бэкап VPN-конфигурации, но они не хостят продуктовые
рантаймы, продуктовые БД или продуктовые workflow-ы деплоя.

Обычный сайтовый CDN — не транспорт SoftEther по умолчанию, потому что VPN —
не обычный HTTP-трафик сайтов. Будущее ускорение можно отдельно тестировать
через GeoDNS, Anycast или L4 TCP proxy для `443/tcp`, `992/tcp` и
`1194/tcp`. Управление на `5555/tcp` должно оставаться напрямую и в allowlist.

## Роль платформы

- HAProxy владеет публичными TCP entrypoints и направляет VPN-трафик в
  контейнер SoftEther внутри Docker-сети.
- На `443/tcp` HAProxy умеет разделять трафик сайтов и VPN по доменному
  имени, потому что видит TLS SNI.
- По UDP маршрутизация по доменному имени в этой схеме не доступна; UDP-пакеты
  маршрутизируются по IP и порту, если UDP-протоколы будут включены позже.
- Nginx/Certbot владеют обновлением сертификатов; SoftEther потребляет
  скопированные файлы сертификатов из общего TLS-каталога.
- Конфигурация и логи VPN — это persistent-данные платформы, и они входят в
  бэкап, восстановление, мониторинг и правила firewall.

## Текущие TCP-порты

Машинно-читаемый список — в [`services.yml`](../services.yml) под ключом `platform.edge_vpn.ports`. Таблица ниже — производное от него для людей; при расхождении источник истины — `services.yml`.

| Порт | Протокол | Назначение |
|---|---|---|
| `443` | TCP | SSTP/SSL VPN через HAProxy SNI routing |
| `992` | TCP | Альтернативный SSL endpoint SoftEther |
| `1194` | TCP | OpenVPN-совместимый TCP endpoint |
| `5555` | TCP | SoftEther Server Manager, IP-фильтрация |

## Будущие опциональные UDP-порты

Эти порты не активны в текущей сохранённой установке и не входят в `platform.edge_vpn.ports`. Добавлять их только после того, как соответствующие протоколы SoftEther включены и проверены; одновременно расширять `services.yml`.

| Порт | Протокол | Назначение |
|---|---|---|
| `500` | UDP | IPsec/IKE |
| `4500` | UDP | IPsec NAT-T |
| `1701` | UDP | L2TP |
| `1194` | UDP | OpenVPN-совместимый UDP endpoint |

## Обязательные тома

- `softether_data`: конфигурация сервера SoftEther, включая
  `vpn_server.config`.
- `softether_logs`: логи сервера SoftEther.
- `certbot_conf`: источник истины по сертификатам, владелец — Certbot.
- Каталог TLS-копий Nginx/Certbot, монтируемый read-only в SoftEther как
  `/etc/ssl/vpn`.

## Бэкап и восстановление

В скоуп бэкапа должны входить:

- `softether_data`;
- `softether_logs`, когда полезны для разбора инцидентов;
- скопированные файлы VPN-сертификатов;
- VPN-конфиг маршрутизации HAProxy и management allowlist.

Восстановление считается неполным, пока:

- контейнер SoftEther не стартанул с восстановленным томом `softether_data`;
- файлы VPN-сертификатов не присутствуют и не валидны;
- HAProxy не маршрутизирует VPN SNI на SoftEther;
- порты `443/tcp`, `992/tcp`, `1194/tcp` и `5555/tcp` не маршрутизированы
  через HAProxy осознанно;
- будущие UDP-порты не открыты или не закрыты осознанно согласно набору
  включённых протоколов;
- management-порт `5555` не доступен только с разрешённых IP.

## Граница продуктовой HA

Не строить high availability AromaFlowAI или AI_E_Retail поверх SoftEther.
Доступность продуктов обеспечивается DNS, HAProxy/Nginx, частной overlay-сетью
узлов, бэкапом/восстановлением, репликацией и rollback деплоя. SoftEther — для
VPN-доступа, management-доступа и контролируемой маршрутизации egress.

## Мониторинг и безопасность

- Мониторить TCP endpoints SoftEther и здоровье контейнера.
- Предпочитать TCP healthcheck-и проверкам только по ICMP.
- Доступ к Server Manager держать под IP-фильтром.
- Включать логи SoftEther в fail2ban или алертинг только после подтверждения
  формата логов и реального поведения client IP.
- Не коммитить `vpn_server.config`, если он содержит пароли, пользователей,
  ключи или другие секреты.

## SoftEther Config Updates

`operator/softether/edge/vpn_server.config` is an install seed, not a file that
normal rollout continuously enforces. After the first successful start, the
remote `/opt/ai-service-platform/vpn_edge/softether_data/vpn_server.config`
belongs to SoftEther runtime state and may be changed by SoftEther itself.

Normal `vpn_edge present` rollout copies the seed only when the remote config is
missing. It does not overwrite the live config and does not restart
`softether-edge` because of the seed.

Intentional replacement uses the explicit reseed action and must target one
alias:

```powershell
.\tools\services\rollout_from_state.ps1 -ReseedVpnEdge vps4
```

WSL/Linux equivalent:

```bash
bash tools/services/rollout_from_state.sh --reseed-vpn-edge vps4
```

The low-level debug escape hatch is:

```powershell
.\tools\services\service_remote.ps1 vpn_edge reseed -Limit vps4
```

The reseed action requires an installed `vpn_edge`, creates a timestamped backup
of the live config, copies the operator seed, restarts `softether-edge`, verifies
the container, and prints the backup path. More granular `vpncmd` updates are
reserved for a later phase.

## SoftEther Cascade Transport

`vpn_cascade` is the separate site-to-site/cascade transport service. It is not
the user VPN ingress and it does not reuse `/opt/ai-service-platform/vpn_edge`.
The rollout creates a distinct container, config volume, logs directory, backup
directory, and Docker network:

```text
/opt/ai-service-platform/vpn_cascade
ai_service_cascade 172.21.0.0/24
softether-cascade  172.21.0.2
```

To enable it, add or update a `state.csv` service row with explicit aliases:

```csv
service,vpn_cascade,vpn_cascades,vps4,,,present
```

The operator seed config is per node and optional for the very first clean
bootstrap:

```text
operator/softether/cascade/<alias>/vpn_server.config
```

If the seed exists, normal `vpn_cascade present` copies it only when the remote
cascade config is missing. If the seed does not exist and the remote config is
also missing, rollout starts a clean SoftEther cascade container with an empty
`softether_data` directory. SoftEther can then be configured manually through
SSH and `docker compose exec`/`vpncmd`; the resulting
`vpn_server.config` can be copied back into the operator seed path later.

After first start, the remote
`/opt/ai-service-platform/vpn_cascade/softether_data/vpn_server.config` is
mutable runtime state. `vpn_cascade` does not publish HAProxy routes, does not
change host routing, and does not enforce egress policy. Controlled routing must
come later from approved policy, not directly from cascade rollout.
