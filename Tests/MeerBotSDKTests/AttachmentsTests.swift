// Вложения: тело отправки с uploadIds, загрузка файла, разбор attachments из истории и SSE.
// Контракт сверен с роутами `/api/v1/mobile/{upload,media,messages,chat/stream}`.

import XCTest
@testable import MeerBotSDK

final class AttachmentsTests: XCTestCase {

    private let visitorUuid = "11111111-2222-4333-8444-555555555555"
    private let installationId = "99999999-8888-4777-8666-555555555555"

    private let registerPath = "/api/v1/mobile/register"
    private let streamPath = "/api/v1/mobile/chat/stream"
    private let messagesPath = "/api/v1/mobile/messages"
    private let uploadPath = "/api/v1/mobile/upload"
    private let clientId = "a1b2c3d4-0000-4000-8000-000000000042"

    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUpWithError() throws {
        try super.setUpWithError()
        StubURLProtocol.reset()
        suiteName = "MeerBotSDKTests.Attachments.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private var flagStore: IdentityFlagStore { IdentityFlagStore(defaults: defaults) }

    private func makeClient() -> APIClient {
        APIClient(
            config: MeerBotConfiguration(
                apiKey: "pk_live_test",
                baseURL: URL(string: "https://meerbot.test")!,
                sdkVersion: "0.4.0"
            ),
            visitorUuid: visitorUuid,
            installationId: installationId,
            sessionConfiguration: .stubbed(),
            flagStore: flagStore
        )
    }

    private func stubRegister() {
        StubURLProtocol.enqueue(
            path: registerPath,
            .json([
                "deviceId": "42",
                "jwt": "jwt-1",
                "expiresIn": 900,
                "attestationRequired": false,
                "identity": ["status": "not_provided"],
            ])
        )
    }

    private func collectInternal(
        _ stream: AsyncThrowingStream<StreamEvent, Error>
    ) async -> (events: [StreamEvent], error: Error?) {
        var events: [StreamEvent] = []
        do {
            for try await event in stream { events.append(event) }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    // MARK: Тело отправки

    /// `uploadIds` уходят массивом в теле потока; текст при этом может быть пустым.
    func testТелоОтправкиНесётUploadIds() async throws {
        stubRegister()
        StubURLProtocol.enqueue(path: streamPath, .sse("data: [DONE]\n\n"))

        let client = makeClient()
        _ = await collectInternal(
            client.sendMessage("", clientMessageId: clientId, uploadIds: ["up-1", "up-2"])
        )

        let request = try XCTUnwrap(StubURLProtocol.requests(path: streamPath).first)
        XCTAssertEqual(request.body?["message"] as? String, "")
        XCTAssertEqual(request.body?["uploadIds"] as? [String], ["up-1", "up-2"])
        XCTAssertEqual(request.body?["clientMessageId"] as? String, clientId)
    }

    /// Без вложений поле `uploadIds` в тело не попадает — тело прежнее, как у 0.3.x.
    func testБезВложенийUploadIdsВТелеНет() async throws {
        stubRegister()
        StubURLProtocol.enqueue(path: streamPath, .sse("data: [DONE]\n\n"))

        _ = await collectInternal(makeClient().sendMessage("текст", clientMessageId: clientId))

        let request = try XCTUnwrap(StubURLProtocol.requests(path: streamPath).first)
        XCTAssertNil(request.body?["uploadIds"])
    }

    // MARK: Загрузка файла

    /// `uploadAttachment` бьёт в `/mobile/upload` multipart-ом и разбирает ответ сервера.
    func testЗагрузкаФайлаБьётВUploadИРазбираетОтвет() async throws {
        stubRegister()
        StubURLProtocol.enqueue(
            path: uploadPath,
            .json([
                "uploadId": "upl-777",
                "status": "ready",
                "kind": "image",
                "mime": "image/png",
                "fileName": "photo.png",
                "size": 1234,
            ])
        )

        let result = try await makeClient().uploadAttachment(
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            fileName: "photo.png",
            mime: "image/png"
        )

        XCTAssertEqual(result.uploadId, "upl-777")
        XCTAssertEqual(result.kind, "image")
        XCTAssertEqual(result.size, 1234)

        let request = try XCTUnwrap(StubURLProtocol.requests(path: uploadPath).first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["Content-Type"]?.hasPrefix("multipart/form-data; boundary="), true)
        XCTAssertNotNil(request.headers["Authorization"])
    }

    /// Тело multipart несёт поле `file`, имя файла и сами байты.
    func testMultipartТелоНесётФайл() {
        let boundary = "meerbot.B"
        let payload = Data("hello".utf8)
        let body = APIClient.multipartBody(boundary: boundary, fileName: "a.txt", mime: "text/plain", data: payload)
        let text = String(decoding: body, as: UTF8.self)

        XCTAssertTrue(text.contains("--\(boundary)\r\n"))
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"a.txt\""))
        XCTAssertTrue(text.contains("Content-Type: text/plain"))
        XCTAssertTrue(text.contains("hello"))
        XCTAssertTrue(text.hasSuffix("--\(boundary)--\r\n"))
    }

    /// Перевод строки и кавычка в имени файла экранируются — иначе сломали бы заголовок части.
    func testИмяФайлаЭкранируетсяВMultipart() {
        let body = APIClient.multipartBody(
            boundary: "B",
            fileName: "e\"vil\r\n.txt",
            mime: "text/plain",
            data: Data()
        )
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("filename=\"e_vil__.txt\""))
    }

    // MARK: Разбор attachments

    /// История несёт `attachments` — они разбираются в модель со всеми полями.
    func testИсторияРазбираетAttachments() async throws {
        stubRegister()
        StubURLProtocol.enqueue(
            path: messagesPath,
            .json([
                "messages": [
                    [
                        "id": 10,
                        "role": "user",
                        "content": "смотри",
                        "attachments": [
                            [
                                "mediaId": "m-1",
                                "kind": "image",
                                "mime": "image/jpeg",
                                "fileName": "cat.jpg",
                                "size": 999,
                                "width": 800,
                                "height": 600,
                                "duration": NSNull(),
                            ]
                        ],
                    ],
                    ["id": 11, "role": "assistant", "content": "ага"],
                ],
                "hasMore": false,
                "mode": "ai",
            ])
        )

        let page = try await makeClient().history()

        let attachment = try XCTUnwrap(page.messages.first?.attachments.first)
        XCTAssertEqual(attachment.mediaId, "m-1")
        XCTAssertEqual(attachment.kind, "image")
        XCTAssertEqual(attachment.mime, "image/jpeg")
        XCTAssertEqual(attachment.fileName, "cat.jpg")
        XCTAssertEqual(attachment.size, 999)
        XCTAssertEqual(attachment.width, 800)
        XCTAssertEqual(attachment.height, 600)
        XCTAssertNil(attachment.duration)
        XCTAssertTrue(page.messages.last?.attachments.isEmpty ?? false)
    }

    /// Запись вложения без `mediaId` пропускается: без него картинку не раздать.
    func testВложениеБезMediaIdПропускается() async throws {
        stubRegister()
        StubURLProtocol.enqueue(
            path: messagesPath,
            .json([
                "messages": [
                    [
                        "id": 10,
                        "role": "user",
                        "content": "",
                        "attachments": [
                            ["kind": "image", "mime": "image/png", "size": 1],
                            ["mediaId": "ok", "kind": "document", "mime": "application/pdf", "size": 2],
                        ],
                    ]
                ],
                "hasMore": false,
                "mode": "ai",
            ])
        )

        let page = try await makeClient().history()
        XCTAssertEqual(page.messages.first?.attachments.map(\.mediaId), ["ok"])
    }

    /// `manager_message` в потоке несёт `attachments` — они доходят до модели события.
    func testСобытиеМенеджераРазбираетAttachments() async {
        stubRegister()
        StubURLProtocol.enqueue(
            path: streamPath,
            .sse(
                "event: manager_message\ndata: {\"messageId\":88,\"text\":\"держите\",\"authorName\":\"Ирина\","
                    + "\"attachments\":[{\"mediaId\":\"mm-1\",\"kind\":\"document\",\"mime\":\"application/pdf\","
                    + "\"fileName\":\"счёт.pdf\",\"size\":4096}]}\n\n"
            )
        )

        let (events, error) = await collectInternal(makeClient().sendMessage("привет", clientMessageId: clientId))

        XCTAssertNil(error)
        let manager = events.compactMap { event -> ManagerMessage? in
            if case let .event(.managerMessage(message)) = event { return message } else { return nil }
        }.first
        let unwrapped = try? XCTUnwrap(manager)
        XCTAssertEqual(unwrapped?.attachments.map(\.mediaId), ["mm-1"])
        XCTAssertEqual(unwrapped?.attachments.first?.fileName, "счёт.pdf")
        XCTAssertEqual(unwrapped?.attachments.first?.size, 4096)
    }

    // MARK: Слияние ленты

    /// Серверные вложения проставляются своей же (промоутнутой) строке пользователя: только
    /// теперь у отправленной картинки есть mediaId, по которому её можно раздать.
    @MainActor
    func testСлияниеПереноситВложенияНаСвоюСтроку() throws {
        let store = ChatStore()
        let local = store.appendUserMessage("фото", attachments: [
            Attachment(mediaId: "", kind: "image", mime: "image/png", fileName: "p.png", size: 10)
        ])
        XCTAssertTrue(local.attachments.first?.mediaId.isEmpty ?? false)

        store.mergeServerMessages(
            [
                ChatMessage(
                    serverId: 500,
                    role: "user",
                    content: "фото",
                    attachments: [
                        Attachment(mediaId: "srv-m", kind: "image", mime: "image/png", fileName: "p.png", size: 10)
                    ]
                )
            ],
            clientIds: [:]
        )

        let merged = try XCTUnwrap(store.messages.first { $0.id == local.id })
        XCTAssertEqual(merged.serverId, 500)
        XCTAssertEqual(merged.attachments.map(\.mediaId), ["srv-m"])
        XCTAssertEqual(store.messages.count, 1, "своя строка не задвоилась")
    }

    // MARK: Классификация вида

    func testВидОпределяетсяПоMime() {
        XCTAssertEqual(AttachmentKind.classify("image/png"), "image")
        XCTAssertEqual(AttachmentKind.classify("video/mp4"), "video")
        XCTAssertEqual(AttachmentKind.classify("audio/mpeg"), "audio")
        XCTAssertEqual(AttachmentKind.classify("application/pdf"), "document")
        XCTAssertEqual(AttachmentKind.classify("APPLICATION/OCTET-STREAM"), "document")
    }
}
