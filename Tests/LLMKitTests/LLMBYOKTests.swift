import Foundation
import LLMCore
import Testing
@testable import LLMKit

@Suite("BYOK request isolation")
struct LLMBYOKTests {
    private let credentials = LLMBYOKCredentials(provider: .openRouter, apiKey: "test-user-key")

    @Test("Keys travel in headers, never in the body, and don't replace app authentication")
    func credentialsStayOutOfBody() async throws {
        let networking = LLMNetworking()
        await networking.setToken("app-login-token")
        let request = try await networking.makeRequest(
            endpoint: "/chat", method: "POST", body: ["prompt": "hello"], credentials: credentials
        )
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer app-login-token")
        #expect(request.value(forHTTPHeaderField: "X-LLM-BYOK-Provider") == "openrouter")
        #expect(request.value(forHTTPHeaderField: "X-LLM-BYOK-Key") == "test-user-key")
        #expect(request.url?.path == "/chat/byok")
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        let body = try #require(request.httpBody)
        #expect(!String(decoding: body, as: UTF8.self).contains("test-user-key"))

        let toolRequest = try await networking.makeRequest(
            endpoint: "/tools/web-search", method: "POST", body: ["arguments": "hello"]
        )
        #expect(toolRequest.value(forHTTPHeaderField: "X-LLM-BYOK-Key") == nil)
        let platformRequest = try await networking.makeRequest(endpoint: "/chat", method: "POST", body: ["prompt": "next"])
        #expect(platformRequest.value(forHTTPHeaderField: "X-LLM-BYOK-Key") == nil)
    }

    @Test("Only model endpoints can receive credentials", arguments: ["/auth/iap", "/tools/web-search", "/upload/r2-presign"])
    func rejectNonModelEndpoints(path: String) throws {
        var request = URLRequest(url: URL(string: "https://llm.chocoford.com\(path)")!)
        request.httpMethod = "POST"
        #expect(throws: LLMBYOKConfigurationError.self) { try credentials.apply(to: &request) }
    }

    @Test("Every inference method uses a route that old servers cannot platform-bill", arguments: [
        ("/chat", "/chat/byok"), ("/chat/stream", "/chat/byok/stream"), ("/chat/ask", "/chat/byok/ask")
    ])
    func dedicatedInferenceRoutes(endpoint: String, expectedPath: String) async throws {
        let request = try await LLMNetworking().makeRequest(
            endpoint: endpoint, method: "POST", body: ["prompt": "hello"], credentials: credentials
        )
        #expect(request.url?.path == expectedPath)
    }

    @Test("Empty and header-injection keys fail locally", arguments: ["", "  ", "key\r\nX-Other: value", String(repeating: "a", count: 4097)])
    func rejectInvalidKeys(key: String) throws {
        var request = URLRequest(url: URL(string: "https://llm.chocoford.com/chat/byok")!)
        request.httpMethod = "POST"
        let invalid = LLMBYOKCredentials(provider: .openRouter, apiKey: key)
        #expect(throws: LLMBYOKConfigurationError.self) { try invalid.apply(to: &request) }
    }

    @Test("Plain HTTP is restricted to loopback development")
    func rejectInsecureTransport() throws {
        var remote = URLRequest(url: URL(string: "http://example.com/chat/byok")!)
        remote.httpMethod = "POST"
        #expect(throws: LLMBYOKConfigurationError.self) { try credentials.apply(to: &remote) }
        var local = URLRequest(url: URL(string: "http://127.0.0.1:8080/chat/byok")!)
        local.httpMethod = "POST"
        try credentials.apply(to: &local)
        #expect(local.value(forHTTPHeaderField: "X-LLM-BYOK-Key") == "test-user-key")
    }

    @Test("Credential descriptions are redacted")
    func redactedDescriptions() {
        #expect(!String(describing: credentials).contains("test-user-key"))
        #expect(!String(reflecting: credentials).contains("test-user-key"))
    }

    @Test("An SSE error is thrown even after HTTP 200")
    func streamFailureIsNotASuccessfulPartialAnswer() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BYOKStreamErrorProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let networking = LLMNetworking(session: session)
        let stream = try await networking.streamInference("/chat/stream", body: ["prompt": "hello"], credentials: credentials)
        do {
            for try await _ in stream {
                Issue.record("The error frame must not be emitted as a chat message")
            }
            Issue.record("Expected the BYOK SSE error to terminate with an error")
        } catch LLMError.server(let code, let message) {
            #expect(code == 502)
            #expect(message == "Your BYOK OpenRouter account has insufficient credits.")
        }
    }

    @Test("Partial text/tool arguments and an unterminated DONE frame must not succeed", arguments: [
        BYOKStreamFixture.partialText, .partialTool, .truncatedDone, .unterminatedDone, .empty
    ])
    func prematureEOFIsAnError(fixture: BYOKStreamFixture) async throws {
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        let stream = try await fixtureStream(fixture, session: session)
        var received: [ChatMessageContent] = []
        do {
            for try await frame in stream {
                if case .message(let message) = frame { received.append(message) }
            }
            Issue.record("A missing completion marker must not be accepted as success")
        } catch LLMError.network(let underlying) {
            #expect(underlying as? LLMBYOKStreamFailure == .interruptedStream)
        }
        #expect(received.count == (fixture == .empty ? 0 : 1))
        if fixture == .partialTool {
            #expect(received.first?.toolCalls?.first?.arguments == #"{"ops":"#)
        }
    }

    @Test("Damaged frames fail even when followed by DONE", arguments: [
        BYOKStreamFixture.invalidJSON, .invalidSchema, .invalidSSE, .invalidUTF8
    ])
    func damagedFramesAreNotSkipped(fixture: BYOKStreamFixture) async throws {
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        let stream = try await fixtureStream(fixture, session: session)
        var received = 0
        do {
            for try await _ in stream { received += 1 }
            Issue.record("A damaged frame must not be skipped to reach DONE")
        } catch LLMError.decoding(let underlying) {
            #expect(underlying as? LLMBYOKStreamFailure == .invalidFrame)
        }
        #expect(received == 1)
    }

    @Test("A complete DONE frame succeeds, including byte-sized transport chunks", arguments: [
        BYOKStreamFixture.complete, .chunkedComplete
    ])
    func completedStreamSucceeds(fixture: BYOKStreamFixture) async throws {
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        let stream = try await fixtureStream(fixture, session: session)
        var received = 0
        for try await _ in stream { received += 1 }
        #expect(received == 1)
    }

    @Test("Platform streams retain their legacy EOF compatibility")
    func platformEOFRemainsCompatible() async throws {
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        let stream = try await fixtureStream(.partialText, session: session, byok: false)
        var received = 0
        for try await _ in stream { received += 1 }
        #expect(received == 1)
    }

    @Test("SSE comments, multiline data and standard line endings are supported", arguments: ["\n", "\r\n", "\r"])
    func validFraming(lineEnding: String) throws {
        let lines = [": heartbeat", "", "data:{\"id\":\"m\",", "data: \"content\":\"你好\"}", "", "data: [DONE]", "", ""]
        var decoder = LLMBYOKStreamDecoder<ChatMessageContent>()
        var received: [ChatMessageContent] = []
        for byte in lines.joined(separator: lineEnding).utf8 {
            if decoder.isComplete { break }
            if let message = try decoder.append(byte) { received.append(message) }
        }
        try decoder.validateEnd()
        #expect(received.count == 1)
        #expect(received.first?.content == "你好")
    }

    private func fixtureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BYOKFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func fixtureStream(
        _ fixture: BYOKStreamFixture,
        session: URLSession,
        byok: Bool = true
    ) async throws -> AsyncThrowingStream<StreamChatResponse, Error> {
        let networking = LLMNetworking(session: session)
        await networking.setToken(fixture.rawValue)
        return try await networking.streamInference(
            "/chat/stream", body: ["prompt": "hello"], credentials: byok ? credentials : nil
        )
    }
}

enum BYOKStreamFixture: String, Sendable {
    case partialText, partialTool, truncatedDone, unterminatedDone, empty
    case invalidJSON, invalidSchema, invalidSSE, invalidUTF8
    case complete, chunkedComplete

    var chunks: [Data] {
        let text = Data("data: {\"id\":\"m\",\"role\":\"assistant\",\"content\":\"部分回答\"}\n\n".utf8)
        let done = Data("data: [DONE]\n\n".utf8)
        switch self {
        case .partialText: return [text]
        case .partialTool:
            let tool = #"{"id":"m","role":"assistant","toolCalls":[{"id":"call_1","name":"adjust_elements","arguments":"{\"ops\":"}]}"#
            return [Data("data: \(tool)\n\n".utf8)]
        case .truncatedDone: return [text, Data("data: [DON".utf8)]
        case .unterminatedDone: return [text, Data("data: [DONE]\n".utf8)]
        case .empty: return []
        case .invalidJSON: return [text, Data("data: {broken\n\n".utf8), done]
        case .invalidSchema: return [text, Data("data: {\"unexpected\":true}\n\n".utf8), done]
        case .invalidSSE: return [text, Data("dtaa: {}\n\n".utf8), done]
        case .invalidUTF8: return [text, Data("data: ".utf8) + Data([0xff, 10, 10]), done]
        case .complete: return [text, done]
        case .chunkedComplete: return (text + done).map { Data([$0]) }
        }
    }
}

private final class BYOKFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let token = request.value(forHTTPHeaderField: "Authorization")?.dropFirst("Bearer ".count),
              let fixture = BYOKStreamFixture(rawValue: String(token)) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in fixture.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class BYOKStreamErrorProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let frame = "event: error\ndata: {\"error\":{\"code\":502,\"message\":\"Your BYOK OpenRouter account has insufficient credits.\"}}\n\n"
        client?.urlProtocol(self, didLoad: Data(frame.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
