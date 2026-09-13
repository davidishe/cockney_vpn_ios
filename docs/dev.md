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

### Выгрузка журнала без подписки (dev-сборки)

В Debug-сборке, собранной с ключом, в «Журнале» есть тогл «Выгрузка без подписки (dev)».
Когда у выбранного профиля и всех остальных нет Cockney-токена, журнал уходит на
`POST /api/olcrtc/diagnostics/logs` с заголовком `X-Diagnostics-Dev-Key` вместо Bearer.
Устройство — ID установки (`diagnostics.devInstallId` в UserDefaults). На сервере режим
получает префикс `dev:`, например `dev:openflux`.

Сборка с ключом (ключ только в `CockneyVPN/secrets/cockney_diagnostics_dev_key`, в git его нет):

```bash
xcodebuild ... -configuration Debug COCKNEY_DIAGNOSTICS_DEV_KEY="$(tr -d '[:space:]' < ../../secrets/cockney_diagnostics_dev_key)" build
```

Ключ попадает в `Info.plist` (`CockneyDiagnosticsDevKey`), но Swift читает его только под
`#if DEBUG`: даже если передать ключ в Release/TestFlight-сборку, тогла там не будет.
Серверная сторона: `OlcRtc:DiagnosticsDevUploadKey` или env
`OLCRTC_DIAGNOSTICS_DEV_UPLOAD_KEY` на RU. Пустое значение выключает dev-выгрузку (401).

### Дефект 13.09.2026: расширение убивалось по памяти

Симптом: OpenFlux-режим работает несколько секунд, видео встаёт, в журнале последняя строка
`openflux-ext: ... mem=38MB`, дальше тишина и `The iOS VPN tunnel stopped before it reported a
connection`. Память расширения за 10 с выросла с 9 до 38 МБ, и iOS убил его по лимиту ~50 МБ.

Причин две:
- Поток `openflux.reader` крутил бесконечный цикл без `autoreleasepool`. Каждый пакет от Go
  приходит autoreleased-объектом `NSData`, а пул потока не освобождается, пока цикл не выйдет.
  Все принятые пакеты оставались в памяти.
- В Go-ядре не было мягкого лимита кучи. Upstream OpenFlux ставит `SetMemoryLimit`, а при
  переносе это потерялось. Теперь 30 МБ и `GCPercent=20`, в строке `openflux: stats` видны
  `goheap`/`gosys`.

Если `mem=` в `openflux-ext` снова уверенно ползёт к 45 МБ, первым делом проверять эти два места.

### Фризы каждые ~66 секунд: ротация сессии

Яндекс закрывает каждую сессию редактора примерно через 66 с (`close 1005`, без причины;
замеры 13.09.2026: 67.7, 66.1, 64.9, 69.6, 66.6 с). Одна сессия на клиенте и одна на
exit node означали, что раз в полминуты одна из сторон на 2-6 с офлайн — это и были
фризы видео при нулевых потерях в канале.

Обе стороны теперь ротуются заранее (`internal/openflux/session.go`, патч exit node):
на 45-й секунде открывается вторая сессия, после её готовности трафик переводится на
неё, старый сокет живёт ещё 6 с ради ответов в полёте. Пока живы обе, один и тот же
broadcast приходит дважды, поэтому входящие полезные нагрузки дедуплицируются по хэшу
(`rx dup=` в статистике).

В журнале это видно как `rotating: active #N age=45s` → `promoted session #N+1` →
`session #N ended`. Если `session ... ended` появляется без предшествующего `rotating`,
значит Яндекс закрыл раньше срока: клиент поднимет новую сессию, а при закрытии в первые
3 с (бывает сразу после рукопожатия) повторит подключение без паузы.

### DNS: пул соединений и кэш

Первая версия открывала новое TLS-соединение на каждый DNS-запрос. На телефоне это
стоило ~300 мс на имя, а под нагрузкой резолверы начинали отказывать: 13.09.2026 один
запрос занял 12,6 с и провалился на всех трёх серверах (Яндекс — EOF, Google и Cloudflare —
таймаут). Имена переставали резолвиться, и сайты не открывались при полностью живом туннеле.

Теперь на каждый сервер держится одно соединение, запросы мультиплексируются по DNS-id,
ответы кэшируются на минуту (на пустой ответ — 5 с), первым пробуется сервер, который
ответил в прошлый раз. Замеры: 797 мс первый запрос (с рукопожатием), 102 мс следующий
по тому же соединению, 0 мс из кэша. В статистике — `dns cached=`, `dns fail=`, `dnsavg`.

TTL записей не разбирается: кэш живёт фиксированную минуту. Для диагностики это
приемлемо, для продукта — нет, придётся парсить TTL.

### Потолок скорости: пачки пакетов

Документ пересылает примерно 300 сообщений в секунду независимо от их размера, поэтому
«один пакет — одно сообщение» упирало туннель в ~1 Мбит/с при нулевых потерях.

Теперь писатель забирает из очереди всё, что уже накопилось (до 32 пакетов или 24 КБ),
и отправляет одним контейнером `0x42`: маркер, затем пары «длина + обычная полезная
нагрузка 0x00/0x1F». Накопления не ждём: на пустой очереди пакет уходит сразу, поэтому
задержка на тихом туннеле не растёт, а пачки появляются ровно тогда, когда есть затор.
Замер: 300 пакетов ушли 10 сообщениями, ответные 900 пакетов пришли 37 сообщениями.
В статистике — `tx batch=` и `rx batch=`.

**Совместимость сломана намеренно:** стоковое приложение OpenFlux читает один пакет на
сообщение и на этом документе работать больше не будет. Ему нужен свой документ и
exit node без патча Cockney.

Ещё в статистике появилась строка `rst <адрес>xN` — топ адресов, которые сбрасывают
соединения, чтобы всплески RST можно было связать с конкретным сервисом.
