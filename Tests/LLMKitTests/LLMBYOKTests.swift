import Foundation
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
