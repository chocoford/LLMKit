import Foundation
import LLMCore
import Testing
@testable import LLMKit

@Suite("Backend-mediated BYOK model discovery")
struct LLMBYOKModelDiscoveryTests {
    @Test("Every preset uses the backend and explicitly disables unsupported catalogs", arguments: LLMBYOKPreset.allCases)
    func presetDiscovery(provider: LLMBYOKPreset) async throws {
        let client = LLMClient(authProvider: NoAuthProvider(), byokProvider: .init(configuration: provider.configuration) { "synthetic-key" })
        if provider.configuration.modelDiscovery == nil {
            do { _ = try await client.listBYOKModels(); Issue.record("A disabled catalog must not send a request") }
            catch LLMBYOKConfigurationError.modelDiscoveryUnsupported {}
        }
        let credentials = try await client.modelDiscoveryCredentials(provider: nil)
        let request = try await LLMNetworking().makeRequest(endpoint: "/chat", method: "POST", body: EmptyMetadata(), credentials: credentials)
        #expect(request.url?.path == "/chat/byok")
        #expect(request.url?.host != provider.configuration.baseURL.host)
        let encoded = try #require(request.value(forHTTPHeaderField: "X-LLM-BYOK-Configuration"))
        let data = try #require(Data(base64Encoded: encoded))
        #expect(try JSONDecoder().decode(LLMBYOKConfiguration.self, from: data) == provider.configuration)
    }

    @Test("Signed-out BYOK requests need no App token", arguments: ["/chat", "/chat/stream", "/chat/ask", "/chat/models"])
    func signedOutRequests(endpoint: String) async throws {
        let networking = LLMNetworking()
        let request = try await networking.makeRequest(
            endpoint: endpoint, method: "POST", body: EmptyMetadata(),
            credentials: .init(configuration: .openAI, apiKey: "synthetic-key")
        )
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "X-LLM-BYOK-Key") == "synthetic-key")
        #expect(request.url?.path.hasPrefix("/chat/byok") == true)
    }

    @Test("Discovery uses a dedicated route, keeps app auth and never puts keys in the body")
    func requestIsolation() async throws {
        let networking = LLMNetworking()
        await networking.setToken("app-token")
        let request = try await networking.makeRequest(
            endpoint: "/chat/models", method: "POST", body: EmptyMetadata(),
            credentials: .init(configuration: .gemini, apiKey: "discovery-secret")
        )
        #expect(request.url?.path == "/chat/byok/models")
        #expect(request.url?.host != LLMBYOKConfiguration.gemini.baseURL.host)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer app-token")
        #expect(request.value(forHTTPHeaderField: "X-LLM-BYOK-Key") == "discovery-secret")
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(!String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains("discovery-secret"))
    }

    @Test("Missing/ambiguous BYOK selection never falls back to a platform catalog")
    func requiresProvider() async throws {
        let clients = [
            LLMClient(authProvider: NoAuthProvider()),
            LLMClient(authProvider: NoAuthProvider(), byokCredentialsProvider: { nil }),
            LLMClient(authProvider: NoAuthProvider(), byokModelCredentialsProvider: { _ in nil }, byokProvider: .init(configuration: .openAI) { "must-not-be-used" })
        ]
        for client in clients {
            do { _ = try await client.listBYOKModels(); Issue.record("No provider was selected") }
            catch LLMBYOKConfigurationError.providerRequired {}
        }
        do { _ = try await clients[2].listBYOKModels(for: .gpt4o); Issue.record("Platform selection must not query a catalog") }
        catch LLMBYOKConfigurationError.providerRequired {}
    }

    @Test("An explicit connection overrides ambiguous model-aware selection")
    func explicitProvider() async throws {
        let client = LLMClient(authProvider: NoAuthProvider(), byokModelCredentialsProvider: { _ in throw LLMBYOKConfigurationError.invalidAPIKey })
        let provider = LLMBYOKProvider(configuration: .anthropic) { "synthetic-key" }
        #expect(try await client.modelDiscoveryCredentials(provider: provider).configuration == .anthropic)
        let configured = LLMClient(authProvider: NoAuthProvider(), byokProvider: provider)
        #expect(try await configured.modelDiscoveryCredentials(provider: nil).configuration == .anthropic)
    }

    @Test("A connection can disable discovery without disabling inference")
    func disabledDiscovery() async throws {
        var configuration = LLMBYOKConfiguration.openAI
        configuration.modelDiscovery = nil
        let client = LLMClient(authProvider: NoAuthProvider(), byokProvider: .init(configuration: configuration) { "synthetic-key" })
        do { _ = try await client.listBYOKModels(); Issue.record("Discovery is disabled") }
        catch LLMBYOKConfigurationError.modelDiscoveryUnsupported {}
        #expect(try await client.inferenceCredentials(for: .other("manual-model")) != nil)
    }

    @Test("The networking path decodes advisory models with or without App login", arguments: [false, true])
    func decodedCatalog(authenticated: Bool) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelDiscoveryProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let networking = LLMNetworking(session: session)
        if authenticated { await networking.setToken("app-token") }
        let response: APIResponse<[LLMBYOKModel]> = try await networking.postInference(
            "/chat/models", body: EmptyMetadata(), credentials: .init(configuration: .openAI, apiKey: "discovery-secret")
        )
        #expect(response.data == [.init(id: "future/unknown-model", name: "Future model")])
        #expect(response.credits == nil)
        #expect(response.usage == nil)
        #expect(response.data?.first?.model == .other("future/unknown-model"))
    }
}

private final class ModelDiscoveryProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let appToken = request.value(forHTTPHeaderField: "Authorization")
        let valid = request.url?.path == "/chat/byok/models"
            && (appToken == nil || appToken == "Bearer app-token")
            && request.value(forHTTPHeaderField: "X-LLM-BYOK-Key") == "discovery-secret"
        let response = HTTPURLResponse(url: request.url!, statusCode: valid ? 200 : 400, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"data":[{"id":"future/unknown-model","name":"Future model"}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
