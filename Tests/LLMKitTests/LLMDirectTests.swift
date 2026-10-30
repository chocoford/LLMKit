import Foundation
import Testing
import LLMCore
@testable import LLMKit

@Suite("Direct BYOK isolation and transport")
struct LLMDirectTests {
    @Test("Preset requests carry only the upstream key, never App auth or backend headers", arguments: LLMBYOKPreset.allCases)
    func presetRequests(preset: LLMBYOKPreset) throws {
        let provider = LLMBYOKProvider(configuration: preset.configuration) { "direct-secret" }
        let transport = LLMDirectClient(provider: provider, options: .init())
        let credentials = LLMBYOKCredentials(configuration: preset.configuration, apiKey: "direct-secret")
        let request = try transport.makeRequest(credentials: credentials, catalog: false)
        #expect(request.url == preset.configuration.chatCompletionsURL)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer direct-secret")
        #expect(request.value(forHTTPHeaderField: "X-LLM-BYOK-Key") == nil)
        #expect(request.value(forHTTPHeaderField: "X-LLM-BYOK-Configuration") == nil)
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(!request.httpShouldHandleCookies)
    }

    @Test("Direct chat accepts arbitrary IDs, local prompts and tools without platform credits")
    func directChat() async throws {
        try await withDirectFixture([.json(Self.answer)]) { client, id, _ in
            let tool = ToolSchema(name: "draw", description: "Local drawing", parameters: .init(["type": "object"]))
            let response = try await client.chat(model: .other("future/model:v9"), text: "Draw", tools: [tool])
            #expect(response.data?.content == "Hi")
            #expect(response.credits == nil)
            #expect(response.data?.usage == nil)
            #expect(response.usage?.totalTokens == 3)
            let request = try #require(DirectFixtureProtocol.store.requests(id).first)
            let body = try Self.payload(request)
            #expect(body["model"] as? String == "future/model:v9")
            #expect(body["agentID"] == nil)
            #expect(body["metadata"] == nil)
            let messages = try #require(body["messages"] as? [[String: Any]])
            #expect(messages.first?["content"] as? String == "Local base prompt")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer direct-secret")
            #expect(request.value(forHTTPHeaderField: "X-LLM-BYOK-Key") == nil)
        }
    }

    @Test("Native calls and local tool results survive multiple rounds on the same connection")
    func toolRoundTrip() async throws {
        let call = #"{"id":"r","choices":[{"index":0,"message":{"role":"assistant","tool_calls":[{"id":"call-1","type":"function","function":{"name":"draw","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#
        try await withDirectFixture([.json(call), .json(Self.answer)]) { client, id, _ in
            let first = try await client.chat(model: .other("manual-model"), text: "Draw")
            let message = try #require(first.data)
            #expect(message.toolCalls?.first?.name == "draw")
            _ = try await client.chat(model: .other("manual-model"), messages: [message, .init(role: .tool, content: "drawn", toolCallId: "call-1")])
            let request = try #require(DirectFixtureProtocol.store.requests(id).last)
            let messages = try #require(Self.payload(request)["messages"] as? [[String: Any]])
            #expect(messages.last?["role"] as? String == "tool")
            #expect(messages.last?["tool_call_id"] as? String == "call-1")
            #expect(DirectFixtureProtocol.store.requests(id).count == 2)
        }
    }

    @Test("Local tools execute only after a fully completed upstream round", arguments: [false, true])
    @MainActor
    func nativeToolLoop(completed: Bool) async throws {
        let call = "data: {\"id\":\"tool-round\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call-1\",\"type\":\"function\",\"function\":{\"name\":\"draw\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"tool_calls\"}]}\n\n" + (completed ? "data: [DONE]\n\n" : "")
        try await withDirectFixture([.sse(call), .sse(Self.complete)]) { client, id, _ in
            let probe = DirectToolProbe()
            let registry = ToolRegistry()
            await registry.register(DirectDrawingTool(probe: probe))
            let executor = AgentExecutor(llmProvider: client, toolRegistry: registry)
            var messages: [ChatMessageContent] = []
            do {
                let stream = try await executor.execute(conversationID: "direct", agentConfig: .withTools(["draw"]), contextMessages: [.init(role: .user, content: "Draw")], model: .other("manual-model"))
                for try await event in stream { if case .content(let message) = event { messages.append(message) } }
                #expect(completed)
            } catch is LLMChatCompletionsError { #expect(!completed) }
            #expect(await probe.calls == (completed ? 1 : 0))
            #expect(DirectFixtureProtocol.store.requests(id).count == (completed ? 2 : 1))
            if completed {
                #expect(messages.contains(where: { $0.role == .tool && $0.toolCallId == "call-1" }))
                #expect(messages.last?.content == "Hi")
            }
        }
    }

    @Test("Complete streams emit cumulative snapshots without a settlement event")
    func completeStream() async throws {
        try await withDirectFixture([.sse(Self.complete)]) { client, id, _ in
            let stream = try await client.streamChat(model: .other("manual-model"), text: "hello")
            var contents: [String] = []
            for try await event in stream {
                switch event {
                case .message(let message): contents.append(message.content ?? ""); #expect(message.usage == nil)
                case .settlement: Issue.record("Direct must never emit platform settlement")
                }
            }
            #expect(contents.first == "H")
            #expect(contents.last == "Hi")
            #expect(DirectFixtureProtocol.store.requests(id).count == 1)
        }
    }

    @Test("Partial EOF, corrupt frames and truncated tool arguments never succeed", arguments: [
        "data: {\"id\":\"r\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"partial\"},\"finish_reason\":null}]}\n\n",
        "data: {\"id\":\"r\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"complete\"},\"finish_reason\":\"stop\"}]}\n\n",
        "data: {broken}\n\ndata: [DONE]\n\n",
        "data: {\"id\":\"r\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c\",\"type\":\"function\",\"function\":{\"name\":\"draw\",\"arguments\":\"{\"}}]},\"finish_reason\":\"tool_calls\"}]}\n\ndata: [DONE]\n\n"
    ])
    func brokenStreams(wire: String) async throws {
        try await withDirectFixture([.sse(wire)]) { client, id, _ in
            do {
                let stream = try await client.streamChat(model: .other("manual-model"), text: "hello")
                for try await _ in stream {}
                Issue.record("An incomplete response must fail")
            } catch is LLMChatCompletionsError {}
            #expect(DirectFixtureProtocol.store.requests(id).count == 1)
        }
    }

    @Test("Upstream auth failures never impersonate App auth and do not leak provider bodies")
    func sanitizedFailure() async throws {
        try await withDirectFixture([.json(#"{"error":{"message":"direct-secret"}}"#, status: 401)]) { client, id, _ in
            do { _ = try await client.ask(prompt: "hello", model: .other("manual-model")); Issue.record("Must fail") }
            catch let error as LLMChatCompletionsError {
                #expect(error == .upstream(401))
                #expect(!error.localizedDescription.contains("direct-secret"))
            }
            #expect(DirectFixtureProtocol.store.requests(id).count == 1)
        }
    }

    @Test("Discovery is advisory and missing catalogs are explicit", arguments: [200, 404, 405, 501])
    func modelDiscovery(status: Int) async throws {
        try await withDirectFixture([.json(#"{"data":[{"id":"future-model","name":"Future"}]}"#, status: status)]) { client, id, _ in
            do {
                let models = try await client.listBYOKModels()
                #expect(status == 200)
                #expect(models == [.init(id: "future-model", name: "Future")])
            } catch LLMBYOKConfigurationError.modelDiscoveryUnsupported { #expect(status != 200) }
            let request = try #require(DirectFixtureProtocol.store.requests(id).first)
            #expect(request.httpMethod == "GET")
            #expect(request.url?.lastPathComponent == "models")
        }
    }

    @Test("An explicit upstream completion-marker opt-out still requires a valid finish frame")
    func optionalDoneMarker() async throws {
        let wire = Self.complete.replacingOccurrences(of: "data: [DONE]\n\n", with: "")
        try await withDirectFixture([.sse(wire)], configure: { $0.options.requiresDoneMarker = false }) { client, _, _ in
            var last: ChatMessageContent?
            for try await event in try await client.streamChat(model: .other("manual-model"), text: "hello") {
                if case .message(let message) = event { last = message }
            }
            #expect(last?.content == "Hi")
        }
    }

    @Test("Native catalog pagination remains on the selected connection with its own auth headers")
    func paginatedDiscovery() async throws {
        try await withDirectFixture([
            .json(#"{"data":[{"id":"a","display_name":"A"}],"has_more":true,"last_id":"a"}"#),
            .json(#"{"data":[{"id":"a"},{"id":"b"}],"has_more":false}"#)
        ], configure: { $0.modelDiscovery?.format = .anthropic }) { client, id, _ in
            #expect(try await client.listBYOKModels().map(\.id) == ["a", "b"])
            let requests = DirectFixtureProtocol.store.requests(id)
            #expect(requests.count == 2)
            #expect(requests.last?.value(forHTTPHeaderField: "x-api-key") == "direct-secret")
            #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == nil)
            let query = URLComponents(url: try #require(requests.last?.url), resolvingAgainstBaseURL: false)?.queryItems
            #expect(query?.first(where: { $0.name == "after_id" })?.value == "a")
        }
    }

    @Test("Cancelled credential resolution cannot start a new HTTP task", arguments: ["chat", "stream", "models"])
    func cancelledAdmission(operation: String) async throws {
        try await withDirectFixture([.json(Self.answer)]) { _, id, configuration in
            let client = LLMClient(directBYOK: .init(configuration: configuration) {
                withUnsafeCurrentTask { $0?.cancel() }
                return "direct-secret"
            })
            let task = Task {
                do {
                    switch operation {
                    case "stream": _ = try await client.streamChat(model: .other("manual-model"), text: "hello")
                    case "models": _ = try await client.listBYOKModels()
                    default: _ = try await client.ask(prompt: "hello", model: .other("manual-model"))
                    }
                    Issue.record("Cancelled admission must throw")
                } catch is CancellationError {}
            }
            try await task.value
            #expect(DirectFixtureProtocol.store.requests(id).isEmpty)
        }
    }

    @Test("Cancelling a retained response stream stops its HTTP request")
    func cancelledStream() async throws {
        var response = DirectFixtureResponse.sse("data: {\"id\":\"r\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"partial\"},\"finish_reason\":null}]}\n\n")
        response.finishes = false
        try await withDirectFixture([response]) { client, id, _ in
            let stream = try await client.streamChat(model: .other("manual-model"), text: "hello")
            let consumer = Task {
                for try await _ in stream { withUnsafeCurrentTask { $0?.cancel() } }
                #expect(Task.isCancelled)
            }
            _ = try? await consumer.value
            for _ in 0..<200 {
                if DirectFixtureProtocol.store.wasStopped(id) { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            #expect(DirectFixtureProtocol.store.wasStopped(id))
        }
    }

    @Test("Server endpoints, Domain Agents and cross-connection history fail closed")
    func serverAndConversationIsolation() async throws {
        try await withDirectFixture([.json(Self.answer)]) { client, id, configuration in
            for path in ["/auth", "/credits", "/access/evaluate", "/tools/web-search", "/upload/r2-presign"] {
                do { _ = try await client.networking.makeRequest(endpoint: path, method: "POST", body: EmptyMetadata()); Issue.record("Server endpoint must fail") }
                catch LLMDirectError.unsupportedCapability {}
            }
            do { _ = try await client.chat(model: .gpt4o, text: "hello", agentID: "canvas"); Issue.record("Private server agents are unavailable") }
            catch LLMDirectError.unsupportedCapability {}
            let server = LLMClient(authProvider: NoAuthProvider())
            let legacy = Conversation(type: .regular, title: "Old", createdAt: .now, lastChatAt: .now)
            try server.validateConnection(for: legacy)
            #expect(throws: LLMDirectError.self) { try client.validateConnection(for: legacy) }
            var direct = legacy
            direct.directConnection = .init(configuration: configuration, chatModel: .other("chat-model"))
            try client.validateConnection(for: direct)
            #expect(try client.summaryModel(for: direct, requested: .gpt4o) == .other("chat-model"))
            #expect(throws: LLMDirectError.self) { try server.validateConnection(for: direct) }
            direct.directConnection?.configuration.baseURL = URL(string: "https://other-service.invalid/v1/")!
            #expect(throws: LLMDirectError.self) { try client.validateConnection(for: direct) }
            #expect(DirectFixtureProtocol.store.requests(id).isEmpty)
        }
    }

    @Test("Image preparation stays inline and auxiliary prompts do not inherit the drawing prompt")
    func imagesAndAuxiliary() async throws {
        try await withDirectFixture([.json(Self.answer)]) { client, id, _ in
            #expect(client.uploader == nil)
            #expect(client.uploadPolicy == nil)
            let image = ChatMessageContent.File.base64EncodedImage("data:image/png;base64,YQ==")
            let prepared = try await client.prepareUploadFiles(for: ChatMessageContent(role: .user, files: [image]))
            #expect(prepared.files == [image])
            _ = try await client.auxiliaryChat(preferredModel: .other("chat-model"), platformModel: .gpt4o, system: "Title instructions", text: "hello")
            let body = try Self.payload(#require(DirectFixtureProtocol.store.requests(id).first))
            #expect(body["model"] as? String == "chat-model")
            let messages = try #require(body["messages"] as? [[String: Any]])
            #expect(messages.first?["content"] as? String == "Title instructions")
            #expect(!String(describing: messages).contains("Local base prompt"))
        }
    }

    @Test("Auxiliary model precedence and conversation serialization are key-free")
    func auxiliaryAndPersistence() throws {
        var configuration = LLMBYOKConfiguration.openAI
        configuration.options.auxiliaryModel = "configured-summary"
        let provider = LLMBYOKProvider(configuration: configuration) { "never-persist-this-key" }
        let configured = LLMDirectClient(provider: provider, options: .init())
        #expect(configured.auxiliaryModel(fallback: .gpt4o) == .other("configured-summary"))
        let explicit = LLMDirectClient(provider: provider, options: .init(auxiliaryModel: .other("explicit-summary")))
        #expect(explicit.auxiliaryModel(fallback: .gpt4o) == .other("explicit-summary"))
        let legacy = Conversation(type: .regular, title: "Old", createdAt: .now, lastChatAt: .now)
        let oldData = try JSONEncoder().encode(legacy)
        #expect(try JSONDecoder().decode(Conversation.self, from: oldData).directConnection == nil)
        var direct = legacy
        direct.directConnection = .init(configuration: configuration, chatModel: .other("chat-model"))
        let data = try JSONEncoder().encode(direct)
        #expect(!String(decoding: data, as: UTF8.self).contains("never-persist-this-key"))
        #expect(try JSONDecoder().decode(Conversation.self, from: data) == direct)
    }

    @Test("Mode mismatches do not mutate or delete existing conversation history")
    @MainActor
    func stateConnectionGuards() async throws {
        try await withDirectFixture([.json(Self.answer)]) { client, id, _ in
            let state = LLMStateObject(llmClient: client, persistenceProvider: nil)
            let user = ChatMessage.content(.init(role: .user, content: "Original user"))
            let assistant = ChatMessage.content(.init(role: .assistant, content: "Original answer"))
            let old = Conversation(type: .regular, title: "Server conversation", messages: [user, assistant], createdAt: .now, lastChatAt: .now)
            state.conversations = .loaded([old])
            do { try await state._sendMessageBody(to: old.id, model: .gpt4o, message: user); Issue.record("Cannot send server history through Direct") }
            catch LLMDirectError.conversationConnectionMismatch {}
            #expect(state.conversations.value == [old])
            do { try await state._regenerateMessage(in: old.id, fromMessageID: assistant.id, model: .gpt4o); Issue.record("Cannot regenerate on another connection") }
            catch LLMDirectError.conversationConnectionMismatch {}
            #expect(state.conversations.value == [old])
            do { try await state._createConversation(id: "invalid-agent", model: .gpt4o, agentConfig: .init(agentID: "private-server-agent"), messages: [user]); Issue.record("Cannot create a server agent in Direct") }
            catch LLMDirectError.unsupportedCapability {}
            #expect(state.conversations.value == [old])
            #expect(DirectFixtureProtocol.store.requests(id).isEmpty)
        }
    }

    @Test("Temporary Direct chat replaces cumulative snapshots and supports non-streaming", arguments: [false, true])
    @MainActor
    func temporaryChat(streaming: Bool) async throws {
        try await withDirectFixture([streaming ? .sse(Self.complete) : .json(Self.answer)]) { client, _, _ in
            let state = LLMStateObject(llmClient: client, persistenceProvider: nil)
            var firstReplies = 0
            let message = try await state._temporaryChat(model: .other("manual-model"), messages: [.content(.init(role: .user, content: "hello"))], stream: streaming, onUpdate: { _ in }, onFirstReply: { _ in firstReplies += 1 })
            #expect(message.content == "Hi")
            #expect(firstReplies == 1)
            #expect(state.creditsInfo == nil)
        }
    }

    @Test("Redirect and cache delegates never forward keys or retain responses")
    func redirectAndCache() {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: URL(string: "https://source.invalid/v1/")!)
        let task = session.dataTask(with: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let delegate = LLMDirectRequestDelegate()
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: "https://other.invalid/")!)) { #expect($0 == nil) }
        delegate.urlSession(session, dataTask: task, willCacheResponse: CachedURLResponse(response: response, data: Data())) { #expect($0 == nil) }
    }

    private static let answer = #"{"id":"r","choices":[{"index":0,"message":{"role":"assistant","content":"Hi"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":3}}"#
    private static let complete = "data: {\"id\":\"r\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"H\"},\"finish_reason\":null}]}\n\ndata: {\"id\":\"r\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"i\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"

    private static func payload(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                guard count > 0 else { break }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private actor DirectToolProbe { var calls = 0; func record() { calls += 1 } }
private struct DirectDrawingTool: Tool {
    let probe: DirectToolProbe
    let name = "draw"
    let description = "Draw locally"
    var inputSchema: ToolInputSchema { .parameters(.init(properties: [:])) }
    func execute(_ input: String, context: (any ChatInvocationContext)?) async throws -> ToolResult {
        await probe.record()
        return .text("drawn")
    }
}

private struct DirectFixtureResponse: Sendable {
    var body: Data
    var contentType: String
    var status: Int
    var finishes = true
    static func json(_ body: String, status: Int = 200) -> Self { .init(body: Data(body.utf8), contentType: "application/json", status: status) }
    static func sse(_ body: String) -> Self { .init(body: Data(body.utf8), contentType: "text/event-stream", status: 200) }
}

@MainActor
private func withDirectFixture(_ responses: [DirectFixtureResponse], configure: (inout LLMBYOKConfiguration) -> Void = { _ in }, body: @MainActor (LLMClient, String, LLMBYOKConfiguration) async throws -> Void) async throws {
    let id = UUID().uuidString
    var configuration = LLMBYOKConfiguration(baseURL: URL(string: "https://direct-test.invalid/\(id)/v1/")!)
    configure(&configuration)
    DirectFixtureProtocol.store.install(id, responses: responses)
    let options = URLSessionConfiguration.ephemeral
    options.protocolClasses = [DirectFixtureProtocol.self]
    let session = URLSession(configuration: options)
    defer { session.invalidateAndCancel(); DirectFixtureProtocol.store.remove(id) }
    let client = LLMClient(directBYOK: .init(configuration: configuration) { "direct-secret" }, options: .init(systemPrompt: "Local base prompt"), session: session)
    try await body(client, id, configuration)
}

private final class DirectFixtureProtocol: URLProtocol, @unchecked Sendable {
    final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private struct Entry { var responses: [DirectFixtureResponse]; var requests: [URLRequest] = []; var stopped = false }
        private var entries: [String: Entry] = [:]
        func install(_ id: String, responses: [DirectFixtureResponse]) { lock.lock(); defer { lock.unlock() }; entries[id] = .init(responses: responses) }
        func remove(_ id: String) { lock.lock(); defer { lock.unlock() }; entries[id] = nil }
        func requests(_ id: String) -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return entries[id]?.requests ?? [] }
        func wasStopped(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return entries[id]?.stopped == true }
        func response(for request: URLRequest) -> DirectFixtureResponse? {
            lock.lock(); defer { lock.unlock() }
            guard let id = request.url?.pathComponents.dropFirst().first, var entry = entries[id], !entry.responses.isEmpty else { return nil }
            let response = entry.responses[min(entry.requests.count, entry.responses.count - 1)]
            entry.requests.append(request); entries[id] = entry
            return response
        }
        func stop(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; if let id = request.url?.pathComponents.dropFirst().first { entries[id]?.stopped = true } }
    }
    static let store = Store()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = Self.store.response(for: request), let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        let response = HTTPURLResponse(url: url, statusCode: fixture.status, httpVersion: nil, headerFields: ["Content-Type": fixture.contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.body)
        if fixture.finishes { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { Self.store.stop(request) }
}
