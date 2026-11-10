import Foundation
import Testing
import LLMCore
@testable import LLMKit

#if DEBUG && canImport(SwiftUI)
@MainActor
@Suite("Scheme state-layer routing and billing isolation")
struct LLMSchemeStateTests {
    private let model = SupportedModel.other("user/model")
    private let selection = LLMSchemeSelection(schemeID: "drawing", profileID: "quality")

    @Test("Unbound legacy conversations retain their original chat route without Scheme discovery")
    func legacyRouting() async throws {
        try await fixture { client, store in
            let state = LLMStateObject(llmClient: client, persistenceProvider: nil)
            await state.refreshConversations()
            try await state.createConversation(id: "legacy", model: model, messages: [])
            try await state.sendMessage(to: "legacy", model: model, message: .content(.init(role: .user, content: "Hello")))
            #expect(state.conversations.value?.first?.schemeConnection == nil)
            #expect(store.requests.map { $0.url?.path } == ["/chat/stream"])
        }
    }

    @Test("New conversations persist only a pinned non-secret route; old JSON stays legacy")
    func persistedRoute() async throws {
        try await fixture { client, store in
            let persistence = SchemeMemoryPersistence()
            let state = LLMStateObject(llmClient: client, persistenceProvider: persistence)
            await state.refreshConversations()
            try await client.withScheme(.init(schemeID: "drawing"), billing: .platform) {
                try await state.createConversation(id: "new", model: model, messages: [])
            }
            let conversation = try #require(state.conversations.value?.first)
            #expect(conversation.schemeConnection?.selection == selection)
            #expect(conversation.schemeConnection?.billing == .platform)
            #expect(await persistence.inserted?.schemeConnection == conversation.schemeConnection)
            let data = try JSONEncoder().encode(conversation)
            #expect(try JSONDecoder().decode(Conversation.self, from: data).schemeConnection == conversation.schemeConnection)
            #expect(!String(decoding: data, as: UTF8.self).contains("secret"))
            var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            legacy.removeValue(forKey: "schemeConnection")
            let decoded = try JSONDecoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: legacy))
            #expect(decoded.schemeConnection == nil)
            #expect(store.requests.filter { $0.url?.path == "/access/evaluate" }.count == 2)
        }
    }

    @Test("Tool rounds, approvals, titles and overflow recovery share one BYOK snapshot")
    func generationSnapshot() async throws {
        let keyReads = SchemeCounter()
        try await fixture(credentials: { _ in
            await keyReads.record()
            return .init(configuration: .openAI, apiKey: "generation-secret")
        }) { client, store in
            store.mainReplies = [.tool, .overflow, .answer]
            let tools = ToolRegistry()
            let calls = SchemeCounter()
            await tools.register(SchemeDrawingTool(calls: calls))
            let state = LLMStateObject(llmClient: client, toolRegistry: tools, persistenceProvider: nil)
            let approvals = SchemeCounter()
            state.toolApprovalHandler = { _ in await approvals.record(); return .approve }
            await state.refreshConversations()
            try await client.withScheme(.init(schemeID: "drawing"), billing: .byok(model: model), connectionID: "connection-a") {
                try await state.createConversation(id: "snapshot", model: .gpt4o,
                    agentConfig: .withTools(["draw"]), messages: [])
                try await state.sendMessage(to: "snapshot", model: .gpt4o,
                    message: .content(.init(role: .user, content: "Draw")))
                _ = try await client.auxiliaryChat(preferredModel: .gpt4o, platformModel: .gpt35Turbo,
                    system: "Title only", text: "Draw")
            }
            #expect(await keyReads.count == 1)
            #expect(await calls.count == 1)
            #expect(await approvals.count == 1)
            #expect(!state.isRunning(conversationID: "snapshot"))
            let inference = store.requests.filter {
                $0.url?.path.hasPrefix("/schemes/byok/") == true || $0.url?.path == "/chat/byok"
            }
            #expect(inference.count == 5) // Three model rounds, overflow summary, title.
            for request in inference {
                #expect(request.value(forHTTPHeaderField: "X-LLM-BYOK-Key") == "generation-secret")
                let body = try payload(request)
                if let scheme = body["scheme"] as? [String: Any] {
                    #expect(scheme["schemeID"] as? String == "drawing" && scheme["profileID"] == nil)
                    #expect(body["byokModelID"] as? String == model.rawValue)
                } else {
                    #expect(request.url?.path == "/chat/byok")
                    #expect(body["model"] as? String == model.rawValue)
                    #expect(body["agentID"] == nil)
                }
            }
            #expect(!store.requests.contains { $0.url?.path == "/chat" || $0.url?.path == "/schemes/stream" })
        }
    }

    @Test("Restored send, regenerate, resume and compact resolve the saved connection, not global billing")
    func restoredEntryPoints() async throws {
        let reads = SchemeCounter()
        try await fixture(credentials: { _ in
            Issue.record("Restoring a bound conversation must not read global credentials")
            return nil
        }) { client, store in
            let route = LLMSchemeConversationBinding(selection: .init(schemeID: "drawing"),
                billing: .byok(model: model), connectionID: "saved-connection")
            let original = Conversation(id: "restored", type: .regular, title: "Saved", createdAt: .now,
                lastChatAt: .now, schemeConnection: route)
            let restored = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(original))
            let state = LLMStateObject(llmClient: client, persistenceProvider: nil, schemeCredentialsProvider: { id, model in
                #expect(id == "saved-connection" && model.rawValue == "user/model")
                await reads.record()
                return .init(configuration: .openAI, apiKey: "restored-secret")
            })
            state.conversations.setAsLoaded([restored])
            try await state.sendMessage(to: restored.id, model: .gpt4o, message: .content(.init(role: .user, content: "Hello")))
            let messageID = try #require(state.conversations.value?.first?.messages.last?.id)
            try await state.regenerateMessage(in: restored.id, fromMessageID: messageID, model: .gpt4o)
            try await state.resumeGeneration(in: restored.id, model: .gpt4o)
            try await state.compactConversation(restored.id)
            #expect(await reads.count == 4)
            #expect(store.requests.filter { $0.url?.path == "/schemes/byok/stream" }.count == 3)
            #expect(store.requests.filter { $0.url?.path == "/chat/byok" }.count == 1)
            #expect(state.conversations.value?.first?.schemeConnection == route)
        }
    }

    @Test("Denied preflight precedes message deletion, uploads and model requests", arguments: ["send", "retry", "resume"])
    func deniedBeforeSideEffects(operation: String) async throws {
        let uploads = SchemeCounter()
        try await fixture(upload: SchemeUploadProbe(calls: uploads)) { client, store in
            store.deny = true
            let route = LLMSchemeConversationBinding(selection: selection, billing: .platform)
            var conversation = Conversation(id: "denied", type: .regular, title: "Saved", createdAt: .now,
                lastChatAt: .now, schemeConnection: route)
            conversation.messages = [.content(.init(role: .user, content: "Before")), .content(.init(role: .assistant, content: "Keep"))]
            let state = LLMStateObject(llmClient: client, persistenceProvider: nil)
            state.conversations.setAsLoaded([conversation])
            do {
                switch operation {
                case "retry": try await state.regenerateMessage(in: conversation.id, fromMessageID: conversation.messages[1].id, model: model)
                case "resume": try await state.resumeGeneration(in: conversation.id, model: model)
                default:
                    try await state.sendMessage(to: conversation.id, model: model,
                        message: .content(.init(role: .user, content: "New", files: [.base64EncodedImage("data:image/png;base64,AQID")])))
                }
                Issue.record("Denied Scheme access must fail before side effects")
            } catch LLMError.accessDenied {}
            #expect(state.conversations.value?.first == conversation)
            #expect(await uploads.count == 0)
            #expect(store.requests.allSatisfy { $0.url?.path.hasPrefix("/schemes/") == true || $0.url?.path == "/access/evaluate" })
            #expect(!store.requests.contains { $0.url?.path.hasSuffix("/stream") == true })
        }
    }

    @Test("Missing restored credentials never become platform requests or mutate history")
    func missingConnection() async throws {
        let client = LLMClient(authProvider: NoAuthProvider(), byokModelCredentialsProvider: { _ in
            Issue.record("Must not use another connection")
            return nil
        })
        let route = LLMSchemeConversationBinding(selection: .init(schemeID: "drawing"),
            billing: .byok(model: model), connectionID: "removed")
        let conversation = Conversation(id: "missing", type: .regular, title: "Saved", createdAt: .now,
            lastChatAt: .now, schemeConnection: route)
        let state = LLMStateObject(llmClient: client, persistenceProvider: nil)
        state.conversations.setAsLoaded([conversation])
        do {
            try await state.sendMessage(to: conversation.id, model: model, message: .content(.init(role: .user, content: "Hello")))
            Issue.record("Missing connection must fail closed")
        } catch LLMSchemeStateError.credentialsProviderRequired {}
        #expect(state.conversations.value?.first == conversation)
    }

    @Test("Cancelling while restoring credentials stops before uploads or history mutation")
    func cancelPreflight() async throws {
        let entered = SchemeCounter()
        let client = LLMClient(authProvider: NoAuthProvider())
        let route = LLMSchemeConversationBinding(selection: .init(schemeID: "drawing"),
            billing: .byok(model: model), connectionID: "saved")
        let conversation = Conversation(id: "cancelled", type: .regular, title: "Saved", createdAt: .now,
            lastChatAt: .now, schemeConnection: route)
        let state = LLMStateObject(llmClient: client, persistenceProvider: nil, schemeCredentialsProvider: { _, _ in
            await entered.record()
            try await Task.sleep(nanoseconds: 30_000_000_000)
            throw CancellationError()
        })
        state.conversations.setAsLoaded([conversation])
        let task = Task { try await state.resumeGeneration(in: conversation.id, model: model) }
        await entered.waitForRecord()
        state.cancelGeneration(conversationID: conversation.id)
        try await task.value
        #expect(state.conversations.value?.first == conversation)
        #expect(state.inflightTasks.isEmpty && !state.isRunning(conversationID: conversation.id))
    }

    @Test("An explicit conflicting Scheme scope cannot change a bound conversation")
    func conflictingScope() async throws {
        let client = LLMClient(authProvider: NoAuthProvider())
        let route = LLMSchemeConversationBinding(selection: selection, billing: .platform)
        let conversation = Conversation(id: "bound", type: .regular, title: "Saved", createdAt: .now,
            lastChatAt: .now, schemeConnection: route)
        let state = LLMStateObject(llmClient: client, persistenceProvider: nil)
        state.conversations.setAsLoaded([conversation])
        let provider = LLMSchemeProvider(client: client, selection: .init(schemeID: "another", profileID: "quality"), billing: .platform)
        do {
            try await LLMSchemeScope.$provider.withValue(provider) {
                try await state.sendMessage(to: conversation.id, model: model, message: .content(.init(role: .user, content: "Hello")))
            }
            Issue.record("A conflicting route must not overwrite or bypass the saved binding")
        } catch LLMSchemeStateError.connectionMismatch {}
        #expect(state.conversations.value?.first == conversation)
    }

    @Test("Explicit idle Profile changes persist before use; failed writes keep the old selection")
    func explicitModelChanges() async throws {
        try await fixture { client, store in
            let original = LLMSchemeConversationBinding(selection: selection, billing: .platform)
            let next = LLMSchemeConversationBinding(selection: .init(schemeID: "drawing", profileID: "standard"), billing: .platform)
            let conversation = Conversation(id: "change", type: .regular, title: "Saved", createdAt: .now,
                lastChatAt: .now, schemeConnection: original)
            let persistence = SchemeRoutePersistence(conversation)
            let state = LLMStateObject(llmClient: client, persistenceProvider: persistence)
            await state.refreshConversations()
            try await state.updateSchemeConnection(next, in: conversation.id)
            #expect(state.conversations.value?.first?.schemeConnection == next)
            #expect(await persistence.saved.schemeConnection == next)
            try await state.sendMessage(to: conversation.id, model: model, message: .content(.init(role: .user, content: "Hello")))
            let request = try #require(store.requests.last)
            let scheme = try #require(try payload(request)["scheme"] as? [String: Any])
            #expect(scheme["profileID"] as? String == "standard")
            await persistence.failUpdates()
            do {
                try await state.updateSchemeConnection(original, in: conversation.id)
                Issue.record("Failed persistence must not change routing")
            } catch SchemeStoreFailure.write {}
            #expect(state.conversations.value?.first?.schemeConnection == next)
            #expect(await persistence.saved.schemeConnection == next)
            #expect(!state.isRunning(conversationID: conversation.id))
        }
    }

    @Test("Sending is blocked while a model selection is being persisted")
    func concurrentModelChange() async throws {
        let entered = SchemeCounter()
        let gate = SchemeRouteGate()
        let route = LLMSchemeConversationBinding(selection: selection, billing: .platform)
        let next = LLMSchemeConversationBinding(selection: .init(schemeID: "drawing", profileID: "standard"), billing: .platform)
        let conversation = Conversation(id: "changing", type: .regular, title: "Saved", createdAt: .now,
            lastChatAt: .now, schemeConnection: route)
        let persistence = SchemeRoutePersistence(conversation, entered: entered, gate: gate)
        let client = LLMClient(authProvider: NoAuthProvider())
        let state = LLMStateObject(llmClient: client, persistenceProvider: persistence)
        await state.refreshConversations()
        let update = Task { try await state.updateSchemeConnection(next, in: conversation.id) }
        await entered.waitForRecord()
        #expect(state.schemeConnectionUpdates.contains(conversation.id))
        do {
            try await state.sendMessage(to: conversation.id, model: model, message: .content(.init(role: .user, content: "Hello")))
            Issue.record("Sending must wait until the routing write completes")
        } catch LLMSchemeStateError.generationInProgress {}
        #expect(state.conversations.value?.first == conversation)
        await gate.release()
        try await update.value
        #expect(state.conversations.value?.first?.schemeConnection == next)
        #expect(!state.isRunning(conversationID: conversation.id))
    }

    @Test("Unupgraded persistence and active generation cannot silently change a saved model")
    func guardedModelChanges() async throws {
        let client = LLMClient(authProvider: NoAuthProvider())
        let route = LLMSchemeConversationBinding(selection: selection, billing: .platform)
        let next = LLMSchemeConversationBinding(selection: .init(schemeID: "drawing", profileID: "standard"), billing: .platform)
        let conversation = Conversation(id: "guarded", type: .regular, title: "Saved", createdAt: .now,
            lastChatAt: .now, schemeConnection: route)
        let state = LLMStateObject(llmClient: client, persistenceProvider: SchemeMemoryPersistence())
        state.conversations.setAsLoaded([conversation])
        do {
            try await state.updateSchemeConnection(next, in: conversation.id)
            Issue.record("A store without routing-update support must fail before changing memory")
        } catch LLMSchemeStateError.routePersistenceRequired {}
        state.runningConversationIDs.insert(conversation.id)
        do {
            try await state.updateSchemeConnection(next, in: conversation.id)
            Issue.record("An active generation must retain its original model")
        } catch LLMSchemeStateError.generationInProgress {}
        #expect(state.conversations.value?.first == conversation)
    }

    @Test("Explicit BYOK model changes retain the connection and cannot change billing")
    func byokModelChanges() async throws {
        let client = LLMClient(authProvider: NoAuthProvider())
        let selection = LLMSchemeSelection(schemeID: "drawing")
        let original = LLMSchemeConversationBinding(selection: selection, billing: .byok(model: model), connectionID: "saved")
        let next = LLMSchemeConversationBinding(selection: selection, billing: .byok(model: .other("user/another")), connectionID: "saved")
        let conversation = Conversation(id: "own-model", type: .regular, title: "Saved", createdAt: .now,
            lastChatAt: .now, schemeConnection: original)
        let state = LLMStateObject(llmClient: client, persistenceProvider: nil)
        state.conversations.setAsLoaded([conversation])
        try await state.updateSchemeConnection(next, in: conversation.id)
        #expect(state.conversations.value?.first?.schemeConnection == next)
        for rejected in [LLMSchemeConversationBinding(selection: selection, billing: .byok(model: model), connectionID: "another-connection"),
                         .init(selection: .init(schemeID: "drawing", profileID: "quality"), billing: .platform)] {
            do {
                try await state.updateSchemeConnection(rejected, in: conversation.id)
                Issue.record("A model update must not change connection or billing source")
            } catch LLMSchemeStateError.connectionMismatch {}
        }
        #expect(state.conversations.value?.first?.schemeConnection == next)
    }

    @Test("Platform Scheme auxiliary requests ignore a globally selected BYOK connection")
    func explicitPlatform() async throws {
        try await fixture(credentials: { _ in Issue.record("Platform must not read BYOK keys"); return nil }) { client, store in
            try await client.withScheme(selection, billing: .platform) {
                _ = try await client.auxiliaryChat(preferredModel: model, platformModel: .gpt4oMini, system: "Title", text: "Hello")
            }
            let request = try #require(store.requests.last)
            #expect(request.url?.path == "/chat")
            #expect(request.value(forHTTPHeaderField: "X-LLM-BYOK-Key") == nil)
            #expect(try payload(request)["model"] as? String == SupportedModel.gpt4oMini.rawValue)
        }
    }

    private func fixture(
        credentials: LLMBYOKModelCredentialsProvider? = nil,
        upload: (any LLMFileUploadProvider)? = nil,
        body: @MainActor (LLMClient, SchemeFixtureStore) async throws -> Void
    ) async throws {
        let store = SchemeFixtureStore()
        let host = "\(UUID().uuidString.lowercased()).scheme-test.invalid"
        SchemeFixtureProtocol.stores.install(store, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SchemeFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); SchemeFixtureProtocol.stores.remove(host) }
        let client = LLMClient(authProvider: NoAuthProvider(), uploadProvider: upload, uploadPolicy: .automatic,
            baseURL: URL(string: "https://\(host)")!, session: session, byokModelCredentialsProvider: credentials)
        try await body(client, store)
    }

    private func payload(_ request: URLRequest) throws -> [String: Any] {
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

private actor SchemeCounter {
    var count = 0
    private var observers: [CheckedContinuation<Void, Never>] = []
    func record() {
        count += 1
        let pending = observers
        observers.removeAll()
        pending.forEach { $0.resume() }
    }
    func waitForRecord() async {
        if count > 0 { return }
        await withCheckedContinuation { observers.append($0) }
    }
}
private actor SchemeMemoryPersistence: PersistenceProvider {
    var inserted: Conversation?
    func restoreConversations() -> [Conversation] { [] }
    func updateConversation(action: ConversationUpdateAction) {
        if case .insert(let conversation) = action { inserted = conversation }
    }
}
private enum SchemeStoreFailure: Error { case write }
private actor SchemeRouteGate {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}
private actor SchemeRoutePersistence: LLMSchemeConversationPersistenceProvider {
    var saved: Conversation
    private var fail = false
    private let entered: SchemeCounter?
    private let gate: SchemeRouteGate?
    init(_ conversation: Conversation, entered: SchemeCounter? = nil, gate: SchemeRouteGate? = nil) {
        saved = conversation; self.entered = entered; self.gate = gate
    }
    func failUpdates() { fail = true }
    func restoreConversations() -> [Conversation] { [saved] }
    func updateConversation(action: ConversationUpdateAction) {}
    func updateSchemeConnection(_ binding: LLMSchemeConversationBinding, in conversationID: String) async throws {
        if fail { throw SchemeStoreFailure.write }
        await entered?.record()
        await gate?.wait()
        saved.schemeConnection = binding
    }
}
private struct SchemeUploadProbe: LLMFileUploadProvider {
    let calls: SchemeCounter
    func uploadFile(data: Data, fileName: String, mimeType: String) async throws -> URL {
        await calls.record()
        return URL(string: "https://uploads.invalid/image.png")!
    }
}
private struct SchemeDrawingTool: Tool {
    let calls: SchemeCounter
    let name = "draw"
    let description = "Draw locally"
    var inputSchema: ToolInputSchema { .parameters(.init(properties: [:])) }
    func approvalPolicy(input: String) -> ApprovalPolicy { .requiresApproval(reason: "Draw") }
    func execute(_ input: String, context: (any ChatInvocationContext)?) async throws -> ToolResult {
        await calls.record()
        return .text("Drawn")
    }
}

private final class SchemeFixtureStore: @unchecked Sendable {
    enum Reply { case tool, overflow, answer }
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var replies: [Reply] = []
    private var denied = false
    var requests: [URLRequest] { lock.withLock { recorded } }
    var mainReplies: [Reply] {
        get { lock.withLock { replies } }
        set { lock.withLock { replies = newValue } }
    }
    var deny: Bool {
        get { lock.withLock { denied } }
        set { lock.withLock { denied = newValue } }
    }
    func response(_ request: URLRequest) throws -> (Int, String, Data) {
        try lock.withLock {
            recorded.append(request)
            let path = request.url?.path ?? ""
            if request.httpMethod == "GET" {
                let scheme = LLMSchemeDescriptor(id: "drawing", name: "Drawing", summary: "", kind: .conversation,
                    defaultProfileID: "quality", profiles: [
                        .init(id: "quality", name: "Quality", rank: 0, modelID: "vendor/platform"),
                        .init(id: "standard", name: "Standard", rank: 1, modelID: "vendor/standard")])
                return (200, "application/json", try JSONEncoder().encode(scheme))
            }
            if path == "/access/evaluate" {
                return (200, "application/json", try JSONEncoder().encode(LLMAccessDecision(allowed: !denied,
                    requirementIDs: denied ? ["access"] : [], missingRequirementIDs: denied ? ["access"] : [])))
            }
            var message = ChatMessageContent(role: .assistant, content: "Answer")
            if path.contains("/schemes/") {
                let reply = replies.isEmpty ? .answer : replies.removeFirst()
                switch reply {
                case .tool: message = .init(role: .assistant, toolCalls: [.init(id: "call-draw", name: "draw", arguments: "{}")])
                case .overflow: return (400, "application/json", Data(#"{"error":{"code":400,"message":"context length exceeded"}}"#.utf8))
                case .answer: break
                }
            }
            if path.hasSuffix("/stream") {
                var data = Data("data: ".utf8)
                data.append(try JSONEncoder().encode(message))
                data.append(Data("\n\ndata: [DONE]\n\n".utf8))
                return (200, "text/event-stream", data)
            }
            return (200, "application/json", try JSONEncoder().encode(APIResponse(data: message, usage: nil, credits: nil)))
        }
    }
}
private final class SchemeFixtureProtocol: URLProtocol, @unchecked Sendable {
    final class Stores: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: SchemeFixtureStore] = [:]
        func install(_ store: SchemeFixtureStore, host: String) { lock.withLock { values[host] = store } }
        func remove(_ host: String) { lock.withLock { values[host] = nil } }
        func get(_ host: String) -> SchemeFixtureStore? { lock.withLock { values[host] } }
    }
    static let stores = Stores()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".scheme-test.invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let url = request.url, let store = Self.stores.get(url.host ?? "") else { throw URLError(.unsupportedURL) }
            let (status, type, data) = try store.response(request)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": type])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
#endif
