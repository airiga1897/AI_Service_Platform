# Продуктовая база AI Retail в postgres_runtime

## Граница этапа

Этот этап готовит контракт PostgreSQL для первого instance `site_runtime`. Он
не развёртывает runtime продукта, не публикует image, не изменяет топологию
PostgreSQL и не переинициализирует standby.

Операторский intent описывает одну управляемую продуктовую базу:

- instance: `ai-retail-mvp`;
- database и owner role: `ai_retail_mvp`;
- обязательное extension: `vector`;
- разрешённый routed source на primary vps8: `172.30.8.2/32`;
- источник пароля: локальный ignored key
  `POSTGRES_PRODUCT_AI_RETAIL_MVP_PASSWORD`

Продуктовая login-role не имеет прав superuser, создания баз/ролей или
репликации. База принадлежит этой роли. При каждом apply primary роль
`postgres_runtime` сверяет пароль и проверяет владельца, атрибуты роли,
extensions и локальный вход с паролем.

## Сетевая граница

Правило HBA ограничено продуктовой базой, продуктовой ролью и адресом-источником
platform-router на vps8. Probe первого этапа подтвердил путь трафика из общего
network namespace `site_runtime` к PostgreSQL через разрешённый router path.

Этап не добавляет host port PostgreSQL, новый overlay или прямое подключение
контейнера продукта к data network.

## Операторский gate

Сначала выполнить check mode только для primary:

```powershell
.\tools\services\service_remote.ps1 postgres_runtime apply `
  -Limit vps8 `
  -Check
```

После проверки вывода выполнить точечный apply primary:

```powershell
.\tools\services\service_remote.ps1 postgres_runtime apply `
  -Limit vps8 `
  -DetachedRemoteJob
```

Не передавать `-ReinitStandby` и не выбирать vps4/vps9 на этом этапе.

## Критерии приёмки

Apply primary должен завершиться без failed hosts и пройти встроенную проверку
продуктовой базы. Затем отдельно подтверждается, что обе standby остаются в
recovery и продолжают streaming с primary. До приёмки этих проверок rollout
продукта не начинается.

```powershell
.\tools\services\audit_runtime_cleanup.ps1 -Aliases vps8,vps4,vps9
```
