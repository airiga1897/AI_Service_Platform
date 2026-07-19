# Future plan: VPS transport for controlled VPN egress

Этот план сохраняет будущую стратегию transport-слоя между VPS для controlled
VPN egress. Это не текущий execution step и не разрешение включать реальный
пользовательский egress.

## Summary

Сначала проверяем совместимость SoftEther site-to-site/cascade как основного
кандидата transport между VPS. Пользовательский SoftEther ingress и
site-to-site transport держим раздельно: разные контейнеры, volumes и конфиги.
SSH tunnel остаётся fallback для точечных TCP-сценариев. WireGuard не делаем.
L2 между VPS не делаем как базовую архитектуру.

## Key Decisions

- SoftEther site-to-site/cascade проверяем первым.
- Пользовательский SoftEther ingress и site-to-site transport держим в разных
  контейнерах и volumes.
- SSH tunnel используем только как fallback для точечных TCP-сценариев.
- WireGuard не используем и не делаем foundation для platform transport.
- L2 между VPS не является базовой архитектурой.
- Реальный пользовательский egress не включается до compatibility-теста.

## Explicit Egress Profiles

Non-RU to non-RU egress is allowed only through explicit named profiles. In v1,
profile selection is manual and operator-driven; RoutePolicy/GeoPolicy may
choose profiles automatically later, but SoftEther cascade remains transport,
not the routing brain.

Each profile must name the ingress alias, egress alias, transport port, reason,
state, and rollback path. The default behavior remains local egress on the
ingress VPS unless a profile is explicitly enabled.

If a non-RU to non-RU route cannot use a direct path from the ingress VPS to the
target egress, it may use an isolated transit segment such as `vps5 -> vps3`.
That segment is not a shared cascade fabric link: it is profile-bound,
L3-routed, acyclic, and carries only marked traffic. NAT remains only on the
final egress VPS. Do not enable `vps3 <-> vps5` as a normal bidirectional
SoftEther cascade path.

## Compatibility Test

Перед любым production-использованием нужно проверить:

- site-to-site/cascade поднимается без изменения пользовательского VPN ingress;
- остановка site-to-site контейнера не ломает SSTP/443 пользовательский вход;
- отдельные volumes не перетирают существующий `softether_data`;
- тестовый трафик выходит через выбранный egress VPS только в lab-сценарии;
- SSH tunnel работает как точечный TCP fallback и не претендует на полный
  IP-dataplane.

## Future Implementation Notes

- В `services.yml` позже можно добавить planned-блок transport policy, но не
  включать его как active production behavior до теста.
- В docs нужно явно различать `softether-ingress` и `softether-s2s`.
- Backup scope для site-to-site должен быть отдельным от пользовательского
  VPN ingress.
- RoutePolicy/GeoPolicy остаётся отдельным слоем выбора egress; SoftEther
  transport не должен становиться “мозгом” маршрутизации.
