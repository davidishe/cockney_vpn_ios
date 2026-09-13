# Разработка

## Структура

- `apple/Package.swift`: SwiftPM-пакет с общим кодом приложения.
- `apple/project.yml`: основной файл XcodeGen для app/extension targets.
- `apple/Godwit.xcodeproj`: сгенерированный Xcode-проект.
- `apple/Sources/OlcRTCClientKit`: общие SwiftUI views, models, stores,
  parsers и runtime managers.
- `apple/Sources/OlcRTCClientMac`: точка входа macOS-приложения.
- `apple/Sources/OlcRTCClientiOS`: точка входа iOS-приложения и entitlements.
- `apple/Sources/OlcRTCPacketTunnel`: iOS Packet Tunnel extension.
- `apple/Scripts`: скрипты сборки.

Кодовая база OlcRTC не хранится в этом репозитории. Для сборок, которым нужен
Go CLI или gomobile XCFramework, передайте путь к внешнему checkout OlcRTC:

```bash
./apple/Scripts/build-xcframework.sh --olcrtc-root /path/to/olcrtc
```

Вместо флага можно использовать переменную окружения:

```bash
OLCRTC_REPO_ROOT=/path/to/olcrtc ./apple/Scripts/build-xcframework.sh
```

Для нескольких команд подряд экспортируйте переменную один раз:

```bash
export OLCRTC_REPO_ROOT=/path/to/olcrtc
./apple/Scripts/build-macos-app.sh && ./apple/Scripts/build-ios-unsigned-local-ipa.sh
```

Локальные результаты сборки не коммитятся:

- `apple/.build/`
- `apple/.derived-data/`
- `apple/.swiftpm/`
- `apple/Frameworks/Mobile.xcframework`
- `olcrtc/`, если локальный checkout OlcRTC временно положен рядом с этим
  проектом.

## Проект Xcode

После изменений targets, dependencies, entitlements или bundle IDs:

```bash
cd apple
xcodegen generate
```

`project.yml` считается единственным источником правды. Xcode-проект
генерируется из него.

Для быстрой проверки доступных targets и schemes:

```bash
xcodebuild -list -project apple/Godwit.xcodeproj
```

## Ограничения

- iOS Packet Tunnel сейчас сфокусирован на TCP и DNS-over-tunnel поведении.
  Произвольный UDP forwarding еще не является полноценным production path.
- iOS local SOCKS mode использует background audio mode, чтобы процесс
  продолжал работать после сворачивания приложения. Это удобно для sideloaded
  local testing; для системного iOS-трафика нужен сторонний маршрутизатор
  трафика или подписанная Packet Tunnel сборка.
- Для реального iPhone с Packet Tunnel нужен платный Apple Developer Program и
  provisioning profiles с Network Extension capability для обоих iOS targets
  (`space.tokenova.cockney.ios` + `.PacketTunnel`) и App Group
  `group.space.tokenova.cockney.ios`.
- Team ID: `DEVELOPMENT_TEAM=…` или файл `CockneyVPN/secrets/apple_development_team`.
  TestFlight: `./apple/Scripts/build-ios-testflight.sh --olcrtc-root …`.
- Диагностика: Журнал → «На сервер» → POST `/api/olcrtc/diagnostics/logs`, затем очистка
  локального журнала (см. backend `Docs/OlcRtc/CLIENT.md`).

## Экспериментальный режим OpenFlux (Яндекс Документы)

Добавлен 13.09.2026 для диагностики: в OpenFlux-клиенте через документ Яндекса трафик
до exit node на NL доходит, но пользоваться невозможно. Цель режима — не
продуктовый транспорт, а подробные логи с телефона через уже существующую кнопку
«Журнал → На сервер».

Как включить: новый профиль → провайдер «OpenFlux (Яндекс Документы)» → «URL документа»
(публичная ссылка, та же, что у exit node в `/etc/openflux/openflux.env` на NL) →
режим VPN. В режиме локального SOCKS профиль не запускается: ядро OpenFlux работает
на уровне IP-пакетов.

Устройство:

- Go-ядро: `internal/openflux` в форке olcrtc, экспорт в `mobile/openflux.go`
  (`MobileOpenflux*`). Отдельный `liboflux.a` из репозитория OpenFlux подключить нельзя:
  второй Go-рантайм в том же процессе не слинкуется с `Mobile.xcframework`.
- Расширение: `OpenFluxTunnel.swift`. Адрес туннеля `10.10.10.2/32` (его жёстко ждёт
  exit node), MTU 1500, DNS отвечает ядро через DoT. Сети Яндекса, DoT-резолверы и
  control-plane Cockney исключены из маршрутов.
- Защитник сокетов (`IP_BOUND_IF`) в этом режиме **не ставится**: собственные сокеты
  провайдера и так идут мимо туннеля, а привязка к интерфейсу рвёт сессию при смене
  Wi-Fi ↔ LTE.
- IPv6 не захватывается: идёт мимо туннеля. Для диагностики это приемлемо.

Выгрузка логов: у OpenFlux-профиля нет Cockney-токена, а сервер привязывает журнал к
устройству подписки. Поэтому для выгрузки берётся токен любого профиля с подпиской.
Если таких профилей нет, выгрузка отказывает с «Нет access token».

Что пишется в журнал:

- `openflux: stats ...` раз в 5 с, только при изменениях. Секции `up`/`dn`: пакеты,
  TCP-данные, повторы (`retr`), SYN/RST/FIN, дропы очередей. `tx`/`rx`: сообщения
  документа, кадры, курсоры, склеенные кадры (`multi`), эхо, ошибки. `lag`: задержка
  доставки по отметке `time` Яндекса. `probe`: RTT и потери по зондам exit node.
- События: `session ready`, `session ended`, `stall rx silent`, `waitAuth`,
  `document participants`, `yandex delivery lag`, `dns ...`, первые кадры каждого типа
  с вырезанными base64 (`frame ...`).
- `openflux-ext: ...` раз в 5 с: сколько пакетов отдал iOS и сколько принял, память
  расширения (`mem=`, лимит jetsam ~50 МБ), смена сети (`openflux path`).
