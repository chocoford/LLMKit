import Foundation
import Testing
import LLMCore
@testable import LLMKit

@Suite("Direct BYOK isolation and transport")
struct LLMDirectTests {
    @Test("Explicit hosted search preserves Direct conversation binding and does not opt auxiliary calls in")
    func searchRequests() async throws {
        try await withDirectFixture([.json(Self.answer), .json(Self.answer)], configure: {
            $0.webSearch = .init(adapter: .groq, isEnabled: true)
        }) { client, id, configuration in
            let local = ToolSchema(name: "draw", description: "Local", parameters: .init(["type": "object"]))
            _ = try await client.chat(model: .other("any-model"), text: "News", tools: [local])
            _ = try await client.auxiliaryChat(preferredModel: .other("chat"), platformModel: .gpt4o, system: "Title", text: "News")
            let requests = DirectFixtureProtocol.store.requests(id)
            #expect(requests.count == 2)
            let chat = try Self.payload(try #require(requests.first))
            let tools = try #require(chat["tools"] as? [[String: Any]])
            #expect(tools.count == 2 && tools.last?["type"] as? String == "browser_search")
            let auxiliary = try Self.payload(try #require(requests.last))
            #expect(auxiliary["tools"] == nil && auxiliary["web_search_options"] == nil && auxiliary["enable_search"] == nil)
            var old = configuration
            old.webSearch = nil
            let conversation = Conversation(type: .regular, title: "Old binding", createdAt: .now, lastChatAt: .now,
                directConnection: .init(configuration: old, chatModel: .other("any-model")))
            try client.validateConnection(for: conversation)
        }
    }

    @Test("Direct streams retain upstream citations and search meters without search configuration")
    @MainActor
    func hostedSearchMetadata() async throws {
        let wire = "data: {\"id\":\"r\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Answer\"},\"finish_reason\":\"stop\"}]}\n\ndata: {\"id\":\"r\",\"choices\":[{\"index\":0,\"delta\":{\"annotations\":[{\"type\":\"url_citation\",\"url_citation\":{\"url\":\"https://example.com/news\",\"title\":\"News\"}}]},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":2,\"total_tokens\":3,\"server_tool_use_details\":{\"web_search_requests\":2}}}\n\ndata: [DONE]\n\n"
        try await withDirectFixture([.sse(wire)]) { client, id, _ in
            let state = LLMStateObject(llmClient: client, persistenceProvider: nil)
            var firstReplies = 0
            let reply = try await state._temporaryChat(model: .other("any-model"), messages: [.content(.init(role: .user, content: "News"))],
                onUpdate: { _ in }, onFirstReply: { _ in firstReplies += 1 })
            #expect(reply.content == "Answer" && firstReplies == 1)
            #expect(reply.citations?.count == 1)
            #expect(reply.usageSummary.providerToolUsage?["web_search_requests"] == 2)
            #expect(reply.usage == nil)
            let request = try #require(DirectFixtureProtocol.store.requests(id).first)
            let body = try Self.payload(request)
            #expect(body["tools"] == nil && body["web_search_options"] == nil && body["enable_search"] == nil)
        }
    }

    @Test("Auxiliary requests do not configure upstream search")
    func auxiliaryRequestsDoNotConfigureSearch() async throws {
        try await withDirectFixture([.json(Self.answer)]) { client, id, _ in
            _ = try await client.auxiliaryChat(preferredModel: .other("chat"), platformModel: .gpt4o, system: "Title", text: "Hello")
            let request = try #require(DirectFixtureProtocol.store.requests(id).first)
            let body = try Self.payload(request)
            #expect(body["tools"] == nil && body["web_search_options"] == nil && body["enable_search"] == nil)
        }
    }

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
            #expect(response.data?.usageSummary.tokens?.totalTokens == 3)
            #expect(response.data?.inferenceUsage?.first?.billingSource == .byok)
            #expect(response.data?.usageSummary.isComplete == true)
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

    @Test("Usage snapshots update the same response without platform settlement", arguments: [false, true])
    func completeStream(openRouterUsageTail: Bool) async throws {
        let tail = "data: {\"id\":\"r\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"\"},\"finish_reason\":\"stop\",\"native_finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":2,\"total_tokens\":3}}\n\n"
        let wire = openRouterUsageTail
            ? Self.complete.replacingOccurrences(of: "data: [DONE]\n\n", with: tail + "data: [DONE]\n\n")
            : Self.complete
        try await withDirectFixture([.sse(wire)]) { client, id, _ in
            let stream = try await client.streamChat(model: .other("manual-model"), text: "hello")
            var contents: [String] = []
            var last: ChatMessageContent?
            for try await event in stream {
                switch event {
                case .message(let message):
                    contents.append(message.content ?? "")
                    last = message
                    #expect(message.id == "r" && message.usage == nil)
                case .settlement: Issue.record("Direct must never emit platform settlement")
                }
            }
            #expect(contents.first == "H" && contents.last == "Hi")
            #expect(Set(contents) == ["H", "Hi"])
            #expect(last?.usageSummary.tokens?.totalTokens == (openRouterUsageTail ? 3 : nil))
            #expect(last?.inferenceUsage?.first?.isComplete == true)
            #expect(last?.inferenceUsage?.first?.billingSource == .byok)
            #expect(DirectFixtureProtocol.store.requests(id).count == 1)
        }
    }

    @Test("State saves multi-round usage and regeneration keeps previous incurred usage")
    @MainActor
    func persistedMultiRoundUsage() async throws {
        let call = "data: {\"id\":\"tool-round\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call-1\",\"type\":\"function\",\"function\":{\"name\":\"draw\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"tool_calls\"}]}\n\ndata: [DONE]\n\n"
        try await withDirectFixture([.sse(Self.withUsage(call, id: "tool-round", finish: "tool_calls")), .sse(Self.withUsage(Self.complete))]) { client, _, configuration in
            let original = Conversation(id: "usage", type: .regular, agentConfig: .withTools(["draw"]),
                title: "Saved", createdAt: .now, lastChatAt: .now,
                directConnection: .init(configuration: configuration, chatModel: .other("manual-model")))
            let persistence = DirectUsagePersistence(original)
            let tools = ToolRegistry()
            await tools.register(DirectDrawingTool(probe: DirectToolProbe()))
            let state = LLMStateObject(llmClient: client, toolRegistry: tools, persistenceProvider: persistence)
            await state.refreshConversations()
            try await state.sendMessage(to: original.id, model: .other("manual-model"),
                message: .content(.init(role: .user, content: "Draw")))
            let conversation = try #require(state.conversations.value?.first)
            let finalID = try #require(conversation.messages.last?.id)
            #expect(conversation.usageSummary.requestCount == 2)
            #expect(conversation.usageSummary.tokens?.totalTokens == 6)
            #expect(conversation.usageSummary(forMessageID: finalID).tokens?.totalTokens == 6)
            #expect(conversation.usageSummary.isComplete)
            let restored = try #require(try await persistence.restoreConversations().first)
            #expect(restored.usageSummary == conversation.usageSummary)
            #expect(restored.messages.allSatisfy { $0.usage == nil })

            try await state.regenerateMessage(in: original.id, fromMessageID: finalID, model: .other("manual-model"))
            let retried = try #require(state.conversations.value?.first)
            let retriedID = try #require(retried.messages.last?.id)
            #expect(retried.usageSummary.requestCount == 3)
            #expect(retried.usageSummary.tokens?.totalTokens == 9)
            #expect(retried.usageSummary(forMessageID: retriedID).tokens?.totalTokens == 3)
            #expect(try await persistence.restoreConversations().first?.usageSummary == retried.usageSummary)
        }
    }

    @Test("Usage received before premature EOF is persisted as incomplete, not free")
    @MainActor
    func persistPartialUsage() async throws {
        let wire = Self.withUsage(Self.complete).replacingOccurrences(of: "data: [DONE]\n\n", with: "")
        try await withDirectFixture([.sse(wire)]) { client, _, configuration in
            let original = Conversation(id: "partial", type: .regular, title: "Saved", createdAt: .now,
                lastChatAt: .now, directConnection: .init(configuration: configuration, chatModel: .other("manual-model")))
            let persistence = DirectUsagePersistence(original)
            let state = LLMStateObject(llmClient: client, persistenceProvider: persistence)
            await state.refreshConversations()
            do {
                try await state.sendMessage(to: original.id, model: .other("manual-model"),
                    message: .content(.init(role: .user, content: "Hello")))
                Issue.record("Missing DONE must still fail")
            } catch is LLMChatCompletionsError {}
            let restored = try #require(try await persistence.restoreConversations().first)
            #expect(restored.usageSummary.tokens?.totalTokens == 3)
            #expect(restored.usageSummary.incompleteRequestCount == 1)
            #expect(!restored.usageSummary.isComplete)
        }
    }

    @Test("Cancelling after reported usage preserves that accounting in history")
    @MainActor
    func persistCancelledUsage() async throws {
        var response = DirectFixtureResponse.sse(Self.withUsage(Self.complete).replacingOccurrences(of: "data: [DONE]\n\n", with: ""))
        response.finishes = false
        try await withDirectFixture([response]) { client, _, configuration in
            let original = Conversation(id: "cancel-usage", type: .regular, title: "Saved", createdAt: .now,
                lastChatAt: .now, directConnection: .init(configuration: configuration, chatModel: .other("manual-model")))
            let persistence = DirectUsagePersistence(original)
            let state = LLMStateObject(llmClient: client, persistenceProvider: persistence)
            await state.refreshConversations()
            let send = Task {
                try await state.sendMessage(to: original.id, model: .other("manual-model"),
                    message: .content(.init(role: .user, content: "Hello")))
            }
            for _ in 0..<200 {
                if state.conversations.value?.first?.usageSummary.tokens != nil { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            #expect(state.conversations.value?.first?.usageSummary.tokens?.totalTokens == 3)
            state.cancelGeneration(conversationID: original.id)
            try await send.value
            let restored = try #require(try await persistence.restoreConversations().first)
            #expect(restored.usageSummary.tokens?.totalTokens == 3)
            #expect(restored.usageSummary.incompleteRequestCount == 1)
            #expect(!restored.usageSummary.isComplete)
        }
    }

    @Test("Auxiliary metadata uses existing message updates; legacy usage stays unknown")
    @MainActor
    func auxiliaryUsagePersistence() async throws {
        try await withDirectFixture([.json(Self.answer)]) { client, _, configuration in
            let user = ChatMessage.content(.init(role: .user, content: "Hello"))
            var original = Conversation(id: "aux", type: .regular, title: "Saved", createdAt: .now, lastChatAt: .now,
                directConnection: .init(configuration: configuration, chatModel: .other("manual-model")))
            original.messages = [user, .content(.init(id: "legacy", role: .assistant, content: "Old"))]
            let persistence = DirectUsagePersistence(original)
            let state = LLMStateObject(llmClient: client, persistenceProvider: persistence)
            await state.refreshConversations()
            let result = try await client.auxiliaryChat(preferredModel: .other("manual-model"),
                platformModel: .gpt4o, system: "Title", text: "Hello")
            try await state.recordAuxiliaryUsage(result.data?.inferenceUsage ?? [], in: original.id, messageID: user.id)
            let restored = try #require(try await persistence.restoreConversations().first)
            #expect(restored.usageSummary.filtered(purpose: "title").tokens?.totalTokens == 3)
            #expect(restored.usageSummary.unreportedRequestCount == 1)
            #expect(restored.usageSummary(forMessageID: "legacy").tokens == nil)
            #expect(!restored.usageSummary.isComplete)
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
            #expect(message.inferenceUsage?.count == 1)
            #expect(message.usageSummary.tokens?.totalTokens == (streaming ? nil : 3))
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

    private static func withUsage(_ wire: String, id: String = "r", finish: String = "stop") -> String {
        let tail = #"{"id":"\#(id)","choices":[{"index":0,"delta":{},"finish_reason":"\#(finish)"}],"usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":3}}"#
        return wire.replacingOccurrences(of: "data: [DONE]\n\n", with: "data: \(tail)\n\ndata: [DONE]\n\n")
    }

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
private actor DirectUsagePersistence: PersistenceProvider {
    private var saved: Conversation
    init(_ saved: Conversation) { self.saved = saved }
    func restoreConversations() throws -> [Conversation] {
        try JSONDecoder().decode([Conversation].self, from: JSONEncoder().encode([saved]))
    }
    func updateConversation(action: ConversationUpdateAction) throws {
        switch action {
        case .insert(let conversation): saved = conversation
        case .delete: break
        case .update(_, let change):
            switch change {
            case .insert(let messages):
                for message in messages {
                    if let index = saved.messages.firstIndex(where: { $0.id == message.id }) { saved.messages[index] = message }
                    else { saved.messages.append(message) }
                }
            case .update(let message):
                if let index = saved.messages.firstIndex(where: { $0.id == message.id }) { saved.messages[index] = message }
            case .delete(let ids): saved.messages.removeAll { ids.contains($0.id) }
            case .updateTitle(let title): saved.title = title
            }
        }
    }
}
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
