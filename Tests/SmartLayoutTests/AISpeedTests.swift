import XCTest
@testable import SmartLayout

/// Подставной сервер: отвечает заготовленными ответами и считает запросы.
final class StubAI: URLProtocol {
    static let host = "stub.smartlayout.test"
    static var replies: [String] = []
    static var delay: TimeInterval = 0
    private(set) static var requests = 0

    static func reset(_ replies: [String], delay: TimeInterval = 0) {
        self.replies = replies
        self.delay = delay
        requests = 0
    }

    static var config: AIConfig { AIConfig(baseURL: "https://\(host)/v1", model: "m", apiKey: "k") }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var cancelled = false

    override func startLoading() {
        Self.requests += 1
        let content = Self.replies.isEmpty ? "" : Self.replies.removeFirst()
        let body = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay) { [self] in
            guard !cancelled, let url = request.url else { return }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() { cancelled = true }
}

final class AIClientSpeedTests: XCTestCase {
    override func setUp() { URLProtocol.registerClass(StubAI.self) }
    override func tearDown() { URLProtocol.unregisterClass(StubAI.self) }

    private let text = "короче я вчера посмотрел отчет там все норм"

    /// Вариант формулировки нарушил правила — исправленный текст приходит сразу, без второго запроса.
    func testReviewDoesNotWaitForRewrite() async throws {
        StubAI.reset([#"{"fixed": "Короче, я вчера посмотрел отчёт, там всё норм.", "alternative": "Важно отметить, что отчёт играет ключевую роль.", "note": ""}"#])
        let result = try await AIClient().run(.review, text: text, config: StubAI.config)
        XCTAssertEqual(StubAI.requests, 1)
        XCTAssertEqual(result.text, "Короче, я вчера посмотрел отчёт, там всё норм.")
        XCTAssertNil(result.alternative)
        let rewrite = try XCTUnwrap(result.rewrite)
        XCTAssertTrue(rewrite.messages.last?["content"]?.contains("Перепиши") == true)

        StubAI.reset([#"{"fixed": "Короче, я вчера посмотрел отчёт, там всё норм.", "alternative": "Вчера посмотрел твой отчёт, всё норм.", "note": ""}"#])
        let alternative = try await AIClient().rewriteAlternative(rewrite, config: StubAI.config)
        XCTAssertEqual(alternative, "Вчера посмотрел твой отчёт, всё норм.")
        XCTAssertEqual(StubAI.requests, 1)
    }

    func testRewriteThatStillViolatesIsDropped() async throws {
        StubAI.reset([#"{"fixed": "Ок.", "alternative": "В заключение, всё уникально.", "note": ""}"#])
        let rewrite = AIResult.Rewrite(messages: [["role": "user", "content": "x"]], original: "ок", slang: [])
        let alternative = try await AIClient().rewriteAlternative(rewrite, config: StubAI.config)
        XCTAssertNil(alternative)
    }

    /// «Улучшить» по-прежнему переписывает сам, ведь вы ждёте именно этот вариант.
    func testImproveStillRetries() async throws {
        StubAI.reset([#"{"text": "Важно отметить, что отчёт готов.", "note": ""}"#,
                      #"{"text": "Отчёт готов.", "note": ""}"#])
        let result = try await AIClient().run(.improve, text: "отчет готов", config: StubAI.config)
        XCTAssertEqual(StubAI.requests, 2)
        XCTAssertEqual(result.text, "Отчёт готов.")
    }

    /// Отменённый запрос прерывается сразу и не считается ошибкой.
    func testCancelledRequestStopsQuickly() async {
        StubAI.reset([#"{"fixed": "Ок.", "alternative": "", "note": ""}"#], delay: 5)
        let started = Date()
        let task = Task { try await AIClient().run(.review, text: "ок", config: StubAI.config) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        let result = await task.result
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        guard case .failure(let error) = result else { return XCTFail("запрос должен быть отменён") }
        XCTAssertTrue(AIController.isCancellation(error), "\(error)")
    }

    func testCancellationErrors() {
        XCTAssertTrue(AIController.isCancellation(CancellationError()))
        XCTAssertTrue(AIController.isCancellation(URLError(.cancelled)))
        XCTAssertFalse(AIController.isCancellation(URLError(.timedOut)))
        XCTAssertFalse(AIController.isCancellation(AIError.notConfigured))
    }
}

final class AIPromptOrderTests: XCTestCase {
    /// Системное сообщение не зависит от меняющихся частей: провайдер может его кэшировать.
    func testSystemMessageIsStable() {
        var a = AIClient.Context()
        a.styleProfile = "Стиль автора: просто."
        a.styleRecent = "Свежие тексты: раз"
        a.conversation = "собеседник: привет"
        a.glossary = ["кринж"]
        var b = a
        b.styleRecent = "Свежие тексты: два"
        b.conversation = "собеседник: пока"
        b.previousText = "что-то"
        XCTAssertEqual(AIClient.systemMessage(.review, a), AIClient.systemMessage(.review, b))
        XCTAssertTrue(AIClient.systemMessage(.review, a).hasSuffix("Стиль автора: просто."))
        XCTAssertFalse(AIClient.systemMessage(.review, a).contains("Свежие тексты"))
    }

    func testUserMessageGoesFromStableToChanging() {
        var c = AIClient.Context()
        c.glossary = ["кринж"]
        c.appName = "Telegram"
        c.styleRecent = "Свежие тексты автора"
        c.conversation = "переписка"
        c.previousText = "раньше"
        let m = AIClient.userMessage("ТЕКСТ", c)
        let order = ["кринж", "Telegram", "Свежие тексты автора", "переписка", "раньше", "ТЕКСТ"]
            .map { m.range(of: $0)!.lowerBound }
        XCTAssertEqual(order, order.sorted())
        XCTAssertTrue(m.hasSuffix("ТЕКСТ\n>>>"))
    }

    func testStyleProfileSplit() {
        let p = StyleProfile(directory: TestFiles.tempDir(), resources: TestFiles.resources)
        XCTAssertTrue(p.stableBlock().hasPrefix("Стиль автора:"))
        XCTAssertEqual(p.recentBlock(), "")
        p.addSample("Ну в общем я сегодня всё доделал, завтра покажу )")
        XCTAssertTrue(p.recentBlock().contains("всё доделал"))
        XCTAssertFalse(p.stableBlock().contains("всё доделал"), "свежие тексты не ломают кэш системного сообщения")
    }
}

final class AIResultCacheTests: XCTestCase {
    func testHitExpiryAndEviction() {
        var cache = AIResultCache(capacity: 2, ttl: 60)
        let t0 = Date()
        let k1 = AIResultCache.key(.review, "раз", suggestNext: true)
        cache.put(k1, AIResult(text: "Раз.", note: nil), now: t0)
        XCTAssertEqual(cache.get(k1, now: t0.addingTimeInterval(30))?.text, "Раз.")
        XCTAssertNil(cache.get(k1, now: t0.addingTimeInterval(61)), "старый ответ не используется")
        XCTAssertNil(cache.get(AIResultCache.key(.review, "раз", suggestNext: false)), "другие настройки — другой ключ")

        cache.put("a", AIResult(text: "a", note: nil))
        cache.put("b", AIResult(text: "b", note: nil))
        cache.put("c", AIResult(text: "c", note: nil))
        XCTAssertLessThanOrEqual(cache.count, 2)
        XCTAssertNotNil(cache.get("c"))
    }
}
