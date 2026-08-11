# MeerBot iOS SDK

Экран чата с ИИ-ассистентом MeerBot внутри вашего iOS-приложения: SwiftUI-вью, потоковые
ответы (SSE), эскалация на менеджера, догон истории после обрыва связи, пуш-уведомления.

**Статус:** `0.1.0` — рабочий чат. Не сделано: вложения, verified identity (HMAC),
App Attest, cert pinning. См. [Границы](#границы-текущей-версии).

---

## Требования

- iOS 15+ (многострочное поле ввода — с iOS 16, на 15 однострочное)
- Swift 5.9+ / Xcode 15+
- Аккаунт в кабинете MeerBot с настроенным ассистентом

---

## Установка (Swift Package Manager)

```
https://github.com/NogMeer/meerbot-ios-sdk
```

В Xcode: **File → Add Package Dependencies…** → вставить URL → правило версии
**Up to Next Major `0.1.0`**.

Или в `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/NogMeer/meerbot-ios-sdk.git", from: "0.1.0")
]
```

> **Почему отдельный репозиторий, а не путь внутри `agentbot-platform`.**
> SPM умеет ставить пакет только из **корня** репозитория (или из корня submodule):
> манифест обязан лежать в `Package.swift` на верхнем уровне. Корень `agentbot-platform` —
> Next.js-приложение, поэтому подключить `agentbot-platform/mobile-sdk-ios` как SPM-зависимость
> технически невозможно — это ограничение SPM, а не наше решение.
>
> Исходник остаётся здесь (правка контракта и бэкенда — один PR), публикация — зеркало.
> Репозиторий зеркала создаётся один раз вручную (публичный: приватный потребовал бы от
> интегратора доступа к нашему GitHub), дальше каждый релиз:
> ```bash
> SHA=$(git subtree split --prefix=mobile-sdk-ios HEAD)
> git push git@github.com:NogMeer/meerbot-ios-sdk.git $SHA:refs/heads/main
> git push git@github.com:NogMeer/meerbot-ios-sdk.git $SHA:refs/tags/0.1.0
> ```
> Тег обязан указывать на **коммит зеркала** (`$SHA`), а не на коммит монорепозитория:
> SPM резолвит semver-теги того репозитория, откуда ставят, и в дереве тега `Package.swift`
> должен лежать в корне.

---

## Настройка в кабинете (обязательный шаг)

1. **Кабинет → Бот → Каналы → Виджеты → Создать**, тип — **headless** (свой UI, наш API).
2. В «Разрешённые домены» добавить строку **`https://<bundleId>`** вашего приложения,
   например `https://ru.tumanvpn.app`.
   Это не сайт — это значение заголовка `Origin`, которым SDK помечает свои запросы
   (по умолчанию оно строится из bundleId). Кабинет принимает только `https://`-origin,
   поэтому схема `mobile://` не подойдёт. Если удобнее — укажите домен своего сайта
   и передайте его в `origin:` при настройке.
3. Скопировать показанный один раз ключ `pk_live_…`.

---

## Быстрый старт

```swift
import SwiftUI
import MeerBotSDK

@main
struct MyApp: App {
    init() {
        MeerBot.shared.configure(apiKey: "pk_live_…")
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @State private var showChat = false

    var body: some View {
        Button("Поддержка") { showChat = true }
            .sheet(isPresented: $showChat) {
                MeerBot.shared.chatView(title: "Поддержка", primaryColor: .accentColor) {
                    showChat = false
                }
            }
    }
}
```

Сессия открывается при первом показе экрана, а не в `configure(...)`: рукопожатие заводит
запись посетителя, и делать его на старте приложения означало бы приписывать владельцу
«посетителей», которые чат не открывали. Нужен прогрев (например, по наведению на кнопку) —
`MeerBot.shared.preconnect()`. Если `configure` не вызвали, `chatView()` покажет явное
сообщение об ошибке, а не пустой экран.

### Свой UI поверх нашего состояния

```swift
if let controller = MeerBot.shared.chatController() {
    // controller.store — ObservableObject: messages / mode / sending / connectionError
    // controller.send("текст"), controller.retry(), controller.openConversation(id:)
}
```

---

## Пуш-уведомления

```swift
func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
) {
    MeerBot.shared.setPushToken(deviceToken)
}

func application(
    _ application: UIApplication,
    didReceiveRemoteNotification payload: [AnyHashable: Any]
) -> Bool {
    MeerBot.shared.handlePush(payload)   // true — пуш наш, чат открыт на нужном диалоге
}
```

### Два ключа — сегодняшнее ограничение бэкенда

Пуши требуют **второго** ключа: **Кабинет → Бот → Каналы → Мобильные приложения → Создать**,
затем `configure(apiKey: "<ключ виджета>", pushApiKey: "<ключ приложения>")`.

Почему не один ключ: `POST /api/v1/mobile/register` выдаёт JWT с `aud = ClientMobileApp.id`,
а `POST /api/v1/widget/chat/stream` требует `aud = ClientWebsiteWidget.id` того же ключа
(`findActiveWidgetByApiKey`). Это разные таблицы с независимыми `apiKeyId`, у mobile-ключа
строки виджета нет вовсе → чат по нему всегда получит `403 widget_not_active`. Пока бэкенд
не свяжет мобильное приложение с каналом чата, чат и пуши живут на разных ключах.
**Сама доставка APNs на бэкенде — заглушка** (`server/lib/mobile/push-service.ts` только
логирует), так что регистрация токена сегодня ничего не доставляет.

---

## Что делает SDK

| Возможность | Как работает |
|---|---|
| Потоковый ответ | `POST /api/v1/widget/chat/stream`, SSE; текст появляется по мере генерации |
| Ответ менеджера | событие `manager_message` в том же потоке (режим `pending_escalation`/`human`) |
| Эскалация | событие `escalation` → `store.mode` переключается, UI это отражает |
| Обрыв связи | частичный текст сохраняется, показывается баннер с «Повторить»; если сервер успел дописать ответ — лента перечитывается через `GET /api/v1/widget/messages` |
| Протухший токен | 15-минутный JWT обновляется прозрачно, запрос повторяется ровно один раз |
| Пуш → диалог | `handlePush` открывает нужный `conversationId` и подтягивает историю |
| Сброс | `MeerBot.shared.reset()` — визитор, история и токены на устройстве |

Идентификатор посетителя (`visitorUuid`) хранится в `UserDefaults`; JWT живёт только в
памяти (15 минут, обновляется handshake'ом) — в Keychain хранить нечего.

---

## Границы текущей версии

- **Вложения** (`/widget/upload`) не поддержаны — только текст.
- **Verified identity** (HMAC-подпись внешнего userId) не реализована: посетитель анонимный,
  инструменты с доступом к данным клиента ему недоступны. Виджет с `requireIdentity=true`
  ответит `403 identity_required`.
- **App Attest / cert pinning** — не реализованы (на бэкенде проверка аттестации тоже
  заглушка, `/api/v1/mobile/attestation` всегда отвечает `verified: true`).
- **Пуши** — регистрация устройства работает, доставка на бэкенде не реализована.
- **`ChatMode.closed`** блокирует ввод, но сервер этот режим сегодня не присылает.

---

## Разработка

```bash
swift build
swift test
```

Пакет объявляет `macOS(.v12)` только чтобы сборка и тесты шли на хосте без симулятора;
весь UIKit-зависимый код изолирован в `Sources/MeerBotSDK/Support/PlatformAppearance.swift`.
Продуктовая площадка — iOS. Проверка iOS-сборки:

```bash
xcodebuild -scheme MeerBotSDK -destination 'generic/platform=iOS Simulator' build
```

Тесты не ходят в сеть: транспорт подменяется `StubURLProtocol`, который умеет резать ответ
на произвольные чанки и обрывать соединение посреди потока.

### Структура

```
Sources/MeerBotSDK/
  MeerBotSDK.swift              публичный фасад MeerBot
  Networking/APIClient.swift    handshake, JWT, SSE-поток, история, регистрация устройства
  Networking/SSEParser.swift    побайтовый разбор event-stream
  Networking/ChatStreamEvent.swift  отображение событий сервера в типы SDK
  State/ChatController.swift    поведение: отправка, обрыв, повтор, догон истории
  State/ChatStore.swift         наблюдаемое состояние экрана
  UI/                           SwiftUI: ChatView, MessageBubbleView
```

### Контракт с бэкендом

Источник правды — `agentbot-platform`:
`src/app/api/v1/widget/{session,chat/stream,messages}/route.ts`,
`src/app/api/v1/mobile/register/route.ts`.
Эталонный клиент того же протокола — `widget/src/chat/api/stream.ts` (веб-виджет).
Меняется контракт — синхронно правятся оба, плюс Android/RN SDK.
