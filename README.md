# MeerBot iOS SDK

Экран чата с ИИ-ассистентом MeerBot внутри вашего iOS-приложения: SwiftUI-вью, потоковые
ответы (SSE), эскалация на менеджера, догон истории после обрыва связи, пуш-уведомления.

**Статус:** `0.2.0` — рабочий чат на собственном канале платформы (`mobile_app`), один ключ,
verified identity. Не сделано: вложения, App Attest, cert pinning.
См. [Границы](#границы-текущей-версии).

> **0.2.0 ломает интеграцию 0.1.x.** Чат переехал с `/api/v1/widget/*` на `/api/v1/mobile/*`:
> вместо двух ключей — один (мобильного приложения), `pushApiKey` и `origin` из `configure`
> убраны, разрешённые домены каналу больше не нужны. Что делать — [Миграция](#миграция-с-01x).

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
**Up to Next Minor `0.2.0`** (до 1.0 минорная версия может ломать контракт).

Или в `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/NogMeer/meerbot-ios-sdk.git", from: "0.2.0")
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
> git push git@github.com:NogMeer/meerbot-ios-sdk.git $SHA:refs/tags/0.2.0
> ```
> Тег обязан указывать на **коммит зеркала** (`$SHA`), а не на коммит монорепозитория:
> SPM резолвит semver-теги того репозитория, откуда ставят, и в дереве тега `Package.swift`
> должен лежать в корне.

---

## Настройка в кабинете (обязательный шаг)

1. **Кабинет → Бот → Каналы → Мобильные приложения → Создать**. Платформа — **iOS**
   (ключ, выданный Android-приложению, ответит `platform_mismatch`).
2. Скопировать показанный один раз ключ `pk_live_…`. Он публичен по замыслу — зашит в
   бинарник; всё, что стоит между ним и платным вызовом модели, — серверные лимиты и допуск.

Разрешённые домены и `Origin` каналу не нужны: это была плата за виджетный контракт в 0.1.x.

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

Регистрация устройства происходит при первом показе экрана, а не в `configure(...)`: она
заводит строку устройства, и вызов на старте приложения приписывал бы владельцу
«пользователей», которые чат не открывали. Нужен прогрев (например, по наведению на кнопку) —
`MeerBot.shared.preconnect()`. Если `configure` не вызвали, `chatView()` покажет явное
сообщение об ошибке, а не пустой экран.

Приветствие над пустой лентой задаёт приложение
(`MeerBot.shared.chatController()?.store.setGreeting("…")`): у мобильного канала серверного
источника для него нет — `ClientMobileApp` не хранит ни названия чата, ни приветствия.

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

### Пуш отправляет ВАШ бэкенд, а не MeerBot

`setPushToken` только сохраняет токен в `MeerBot.shared.pushToken` — в MeerBot он не уходит.
Платформа пуши не отправляет вовсе: когда менеджер отвечает, она зовёт **вебхук** вашего
бэкенда (`X-MeerBot-Signature: sha256=HMAC(timestamp.body)`), а тот адресует уведомление сам —
по `external_user_id`, который вы передали в identity-токене. Заберите токен из
`MeerBot.shared.pushToken` и отправьте на свой сервер вместе с этим же идентификатором.

Почему APNs-токен не уходит в MeerBot: в регистрации поле `deviceToken` — это ключ
уникальности устройства, от которого зависит **тред диалога**. Отправляй мы туда APNs-токен,
его ротация или восстановление из бэкапа заводили бы пользователю новый диалог с пустой
историей, а до выдачи разрешения на уведомления чат был бы недоступен вовсе. Поэтому SDK шлёт
стабильный идентификатор установки.

Пуш открывает нужный диалог через `handlePush(payload)` — полезная нагрузка вашего пуша
должна содержать `conversationId` (число или строка) из вебхука.

### Verified identity

```swift
// после входа пользователя в вашем приложении
MeerBot.shared.identify(token: tokenОтВашегоБэкенда)
// после выхода
MeerBot.shared.identify(token: nil)
```

`token` — HS256-JWT, подписанный **вашим** бэкендом секретом приложения (кабинет → Мобильные
приложения, показывается один раз при создании). Claims: `sub` — ваш id пользователя,
опционально `email`/`name`, обязательный `vid` — `visitorUuid` устройства, и токен должен быть
свежим (принимаются выпущенные не ранее пяти минут назад).

Провал проверки **мягкий**: сессия живёт, пользователь просто анонимен, а причина — в
`await MeerBot.shared.identityStatus()` (`verified` · `rejected` · `stale` · `not_configured` ·
`not_provided`). Если в настройках приложения включён «требовать идентификацию», анонимная
сессия получит `403 identity_required`.

---

## Что делает SDK

| Возможность | Как работает |
|---|---|
| Сессия | `POST /api/v1/mobile/register` — регистрация устройства и JWT одним запросом |
| Потоковый ответ | `POST /api/v1/mobile/chat/stream`, SSE; текст появляется по мере генерации |
| Ответ менеджера | событие `manager_message` в открытом потоке; закрытому приложению — вебхук вашему бэкенду |
| Диалог у менеджера | событие `forwarded_to_manager`: сообщение сохранено и передано человеку, модель не звалась |
| Обрыв связи | частичный текст сохраняется, показывается баннер с «Повторить»; если сервер успел дописать ответ — лента перечитывается через `GET /api/v1/mobile/messages` |
| Протухший токен | 15-минутный JWT обновляется прозрачно, запрос повторяется ровно один раз |
| Пуш → диалог | `handlePush` запоминает `conversationId` и подтягивает свежую ленту |
| Идентификация | `identify(token:)` — связь с пользователем вашей системы |
| Сброс | `MeerBot.shared.reset()` — идентификатор установки, история и токены на устройстве |

Идентификатор установки и `visitorUuid` хранятся в `UserDefaults`; JWT живёт только в памяти
(15 минут, обновляется перерегистрацией) — в Keychain хранить нечего.

⚠️ `reset()` заводит **новый** идентификатор установки, то есть новый тред: прежняя переписка
остаётся на сервере за прежним устройством и в приложении больше не появится. Серверного
эндпоинта стирания у канала пока нет.

---

## Миграция с 0.1.x

| 0.1.x | 0.2.0 |
|---|---|
| `configure(apiKey: <ключ виджета>, pushApiKey: <ключ приложения>)` | `configure(apiKey: <ключ приложения>)` |
| `origin:` в `configure`, домен в «Разрешённых доменах» кабинета | не нужны — удалить |
| канал: headless-виджет | мобильное приложение (кабинет → Каналы → Мобильные приложения) |
| `setPushToken` регистрировал APNs-токен на сервере | токен только сохраняется; пуш шлёт ваш бэкенд по вебхуку |
| приветствие приходило из handshake виджета | задаётся приложением (`store.setGreeting`) |
| identity не поддержана | `identify(token:)` |

История прошлых диалогов **не переезжает**: она осталась в веб-канале, привязанная к виджету.
Пользователь получает пустой тред в мобильном канале.

---

## Границы текущей версии

- **Вложения** не поддержаны — только текст (`capabilities.attachments: false` на бэкенде).
- **App Attest / cert pinning** — не реализованы (на бэкенде проверка аттестации тоже
  заглушка, `/api/v1/mobile/attestation` всегда отвечает `verified: true`).
- **Эскалация в инбокс**: пользователю менеджера не обещают — событие `escalation` канал не
  шлёт, флаг «нужен человек» ставится молча по явной просьбе.
- **Название чата и приветствие** не настраиваются из кабинета — их задаёт приложение.
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
  Networking/APIClient.swift    регистрация+JWT, SSE-поток, история, identity
  Networking/SSEParser.swift    побайтовый разбор event-stream
  Networking/ChatStreamEvent.swift  отображение событий сервера в типы SDK
  State/ChatController.swift    поведение: отправка, обрыв, повтор, догон истории
  State/ChatStore.swift         наблюдаемое состояние экрана
  UI/                           SwiftUI: ChatView, MessageBubbleView
```

### Контракт с бэкендом

Источник правды — `agentbot-platform`:
`src/app/api/v1/mobile/{register,chat/stream,messages}/route.ts` и общий контекст допуска
`src/app/api/v1/mobile/chat/_lib/context.ts`.
Форма SSE-кадров намеренно совпадает с веб-виджетом (`widget/src/chat/api/stream.ts`) —
парсер общий. Меняется контракт — синхронно правятся роут, этот SDK и Android/RN.
