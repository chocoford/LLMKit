import Foundation
import LLMCore

/// Direct is a transport choice, not a provider, subscription, or automatic fallback.
public enum LLMInferenceMode: Sendable { case server, directBYOK }

public struct LLMDirectOptions: Sendable {
    /// App-owned, distributable instructions. Never put a private server Domain Agent prompt here.
    public var systemPrompt: String?
    /// Optional model on the SAME connection for titles and summaries. nil uses the
    /// connection's auxiliaryModel, then the chat model.
    public var auxiliaryModel: SupportedModel?
    public init(systemPrompt: String? = nil, auxiliaryModel: SupportedModel? = nil) {
        self.systemPrompt = systemPrompt
        self.auxiliaryModel = auxiliaryModel
    }
}

public enum LLMDirectError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedCapability(String)
    case connectionFailed
    case contextLimitExceeded
    case invalidModelList
    case conversationConnectionMismatch

    public var errorDescription: String? {
        switch self {
        case .unsupportedCapability(let capability): return "Direct BYOK does not support \(capability). No backend fallback was attempted."
        case .connectionFailed: return "Could not connect to the selected model service. No backend fallback was attempted."
        case .contextLimitExceeded: return "The model context length limit was exceeded."
        case .invalidModelList: return "The model service returned an invalid model list."
        case .conversationConnectionMismatch: return "This conversation belongs to a different inference mode or connection. Start a new conversation to switch."
        }
    }
}

extension LLMClient {
    func validateAgentForCurrentMode(_ agentID: String?) throws {
        guard let directClient else { return }
        try directClient.provider.configuration.validate()
        try directClient.validateAgent(agentID)
    }

    func validateConnection(for conversation: Conversation) throws {
        switch (directClient, conversation.directConnection) {
        case (nil, nil): return
        case (.some(let client), .some(let binding)) where client.provider.configuration == binding.configuration:
            try validateAgentForCurrentMode(conversation.agentConfig.agentID)
        default: throw LLMDirectError.conversationConnectionMismatch
        }
    }

    func summaryModel(for conversation: Conversation, requested: SupportedModel) throws -> SupportedModel {
        try validateConnection(for: conversation)
        if let provider = LLMSchemeScope.provider(for: self) {
            return provider.auxiliaryModel(fallback: requested)
        }
        if let directClient, let binding = conversation.directConnection {
            return directClient.auxiliaryModel(fallback: binding.chatModel)
        }
        return requested
    }
}

/// Request-only transport. No platform networking, token, account or credit dependency.
final class LLMDirectClient: Sendable {
    let provider: LLMBYOKProvider
    let options: LLMDirectOptions
    private let session: URLSession
    private let ownsSession: Bool

    init(provider: LLMBYOKProvider, options: LLMDirectOptions, session: URLSession? = nil) {
        self.provider = provider
        self.options = options
        ownsSession = session == nil
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 300
            self.session = URLSession(configuration: configuration)
        }
    }

    deinit { if ownsSession { session.invalidateAndCancel() } }

    func auxiliaryModel(fallback: SupportedModel) -> SupportedModel {
        options.auxiliaryModel ?? provider.configuration.options.auxiliaryModel.map(SupportedModel.init(rawValue:)) ?? fallback
    }

    func chat(model: SupportedModel, messages: [ChatMessageContent], agentID: String?, tools: [ToolSchema]?, includeBasePrompt: Bool = true) async throws -> APIResponse<ChatMessageContent> {
        try Task.checkCancellation()
        try validateAgent(agentID)
        let credentials = try await provider.credentials()
        try Task.checkCancellation()
        var request = try makeRequest(credentials: credentials, catalog: false)
        request.httpBody = try LLMChatCompletionsCodec.encode(model: model.rawValue, messages: includeBasePrompt ? withPrompt(messages) : messages, tools: tools, configuration: credentials.configuration, stream: false)
        let data = try await responseData(for: request, limit: 16 * 1024 * 1024)
        var response = try LLMChatCompletionsCodec.decode(data)
        if var message = response.data {
            var record = message.inferenceUsage?.first ?? .init(responseID: message.id)
            record.billingSource = .byok
            if record.modelID == nil { record.modelID = try credentials.configuration.modelMapping.resolve(model.rawValue) }
            record.tokens = response.usage
            record.isComplete = true
            message.inferenceUsage = [record]
            response.data = message
        }
        return response
    }

    func streamChat(model: SupportedModel, messages: [ChatMessageContent], agentID: String?, tools: [ToolSchema]?) async throws -> AsyncThrowingStream<StreamChatResponse, Error> {
        try Task.checkCancellation()
        try validateAgent(agentID)
        let credentials = try await provider.credentials()
        try Task.checkCancellation()
        var request = try makeRequest(credentials: credentials, catalog: false)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try LLMChatCompletionsCodec.encode(model: model.rawValue, messages: withPrompt(messages), tools: tools, configuration: credentials.configuration, stream: true)
        let streamRequest = request
        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    try Task.checkCancellation()
                    let (bytes, response) = try await session.bytes(for: streamRequest, delegate: LLMDirectRequestDelegate())
                    defer { bytes.task.cancel() }
                    if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
                        var body = Data()
                        for try await byte in bytes { body.append(byte); if body.count >= 64 * 1024 { break } }
                        try validateHTTP(response, body: body)
                    }
                    try validateHTTP(response)
                    guard (response as? HTTPURLResponse)?.mimeType?.lowercased() == "text/event-stream" else { throw LLMChatCompletionsError.invalidResponse }
                    var frames = LLMChatCompletionsFrames()
                    var accumulator = LLMChatCompletionsAccumulator()
                    var record = LLMInferenceUsage(modelID: try credentials.configuration.modelMapping.resolve(model.rawValue), billingSource: .byok)
                    var hasMessage = false
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        guard let frame = try frames.append(byte) else { continue }
                        switch frame {
                        case .data(let data):
                            let update = try accumulator.append(data)
                            if update != nil { hasMessage = true }
                            if hasMessage, update != nil || record.tokens != accumulator.usage {
                                record.responseID = accumulator.currentMessage.id
                                record.modelID = accumulator.modelID ?? record.modelID
                                record.tokens = accumulator.usage
                                var message = accumulator.currentMessage
                                message.inferenceUsage = [record]
                                continuation.yield(.message(message))
                            }
                        case .done: break
                        }
                        if frames.isComplete { break }
                    }
                    try Task.checkCancellation()
                    try frames.validateEnd(requiresDoneMarker: credentials.configuration.options.requiresDoneMarker)
                    try accumulator.validateEnd()
                    record.isComplete = true
                    var completed = accumulator.currentMessage
                    completed.inferenceUsage = [record]
                    continuation.yield(.message(completed))
                    // There is deliberately no platform settlement event.
                    continuation.finish()
                } catch { continuation.finish(throwing: safeError(error)) }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    func listModels(provider selectedProvider: LLMBYOKProvider? = nil) async throws -> [LLMBYOKModel] {
        try Task.checkCancellation()
        let credentials = try await (selectedProvider ?? provider).credentials()
        try Task.checkCancellation()
        guard let discovery = credentials.configuration.modelDiscovery else { throw LLMBYOKConfigurationError.modelDiscoveryUnsupported }
        var models: [LLMBYOKModel] = []
        var seenIDs: Set<String> = []
        var cursors: Set<String> = []
        var cursor: String?
        for _ in 0..<20 {
            try Task.checkCancellation()
            let request = try makeRequest(credentials: credentials, catalog: true, cursor: cursor)
            let data = try await responseData(for: request, limit: 4 * 1024 * 1024, catalog: true)
            guard let page = try? JSONDecoder().decode(CatalogPage.self, from: data), page.data.count <= 10_000 else { throw LLMDirectError.invalidModelList }
            for entry in page.data {
                guard (try? LLMBYOKConfiguration.ModelMapping().resolve(entry.id)) != nil,
                      (entry.display_name ?? entry.name ?? "").utf8.count <= 4096 else { throw LLMDirectError.invalidModelList }
                if seenIDs.insert(entry.id).inserted {
                    models.append(.init(id: entry.id, name: entry.display_name ?? entry.name))
                    guard models.count <= 10_000 else { throw LLMDirectError.invalidModelList }
                }
            }
            guard page.has_more == true else { try Task.checkCancellation(); return models }
            guard discovery.format == .anthropic, !page.data.isEmpty, let next = page.last_id,
                  (try? LLMBYOKConfiguration.ModelMapping().resolve(next)) != nil, cursors.insert(next).inserted else { throw LLMDirectError.invalidModelList }
            cursor = next
        }
        throw LLMDirectError.invalidModelList
    }

    func makeRequest(credentials: LLMBYOKCredentials, catalog: Bool, cursor: String? = nil) throws -> URLRequest {
        let configuration = credentials.configuration
        try configuration.validate()
        guard let endpoint = catalog ? configuration.modelsURL : configuration.chatCompletionsURL else { throw LLMBYOKConfigurationError.modelDiscoveryUnsupported }
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { throw LLMBYOKConfigurationError.insecureConnection }
        let anthropic = catalog && configuration.modelDiscovery?.format == .anthropic
        if anthropic {
            components.queryItems = [URLQueryItem(name: "limit", value: "1000")]
            if let cursor { components.queryItems?.append(.init(name: "after_id", value: cursor)) }
        }
        guard let url = components.url else { throw LLMBYOKConfigurationError.insecureConnection }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpShouldHandleCookies = false
        request.httpMethod = catalog ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let key = try credentials.validatedAPIKey()
        if anthropic {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func responseData(for request: URLRequest, limit: Int, catalog: Bool = false) async throws -> Data {
        do {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request, delegate: LLMDirectRequestDelegate())
            defer { bytes.task.cancel() }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < limit else { throw LLMChatCompletionsError.invalidResponse }
                data.append(byte)
            }
            try Task.checkCancellation()
            if catalog, let http = response as? HTTPURLResponse, [404, 405, 501].contains(http.statusCode) {
                throw LLMBYOKConfigurationError.modelDiscoveryUnsupported
            }
            try validateHTTP(response, body: data)
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let error = object["error"] as? [String: Any] {
                    if error["code"] as? String == "context_length_exceeded" { throw LLMDirectError.contextLimitExceeded }
                    throw LLMChatCompletionsError.upstream(502)
                }
                if let base = object["base_resp"] as? [String: Any], let status = base["status_code"] as? Int, status != 0 { throw LLMChatCompletionsError.upstream(502) }
            }
            return data
        } catch { throw safeError(error) }
    }

    private func validateHTTP(_ response: URLResponse, body: Data? = nil) throws {
        guard let response = response as? HTTPURLResponse else { throw LLMChatCompletionsError.invalidResponse }
        if let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let error = object["error"] as? [String: Any], error["code"] as? String == "context_length_exceeded" {
            throw LLMDirectError.contextLimitExceeded
        }
        guard (200..<300).contains(response.statusCode) else { throw LLMChatCompletionsError.upstream(response.statusCode) }
    }
    private func safeError(_ error: any Error) -> any Error {
        if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError { return CancellationError() }
        if error is LLMChatCompletionsError || error is LLMDirectError || error is LLMBYOKConfigurationError { return error }
        // URL errors/decoder contexts may contain a URL, response or credential. Never echo them.
        return LLMDirectError.connectionFailed
    }
    fileprivate func validateAgent(_ id: String?) throws {
        guard id == nil else { throw LLMDirectError.unsupportedCapability("server Domain Agents; supply an App-owned prompt and local tools instead") }
    }
    private func withPrompt(_ messages: [ChatMessageContent]) -> [ChatMessageContent] {
        guard let prompt = options.systemPrompt, !prompt.isEmpty else { return messages }
        return [.init(role: .system, content: prompt)] + messages
    }
    private struct CatalogPage: Decodable {
        struct Entry: Decodable { let id: String; let name: String?; let display_name: String? }
        let data: [Entry]; let has_more: Bool?; let last_id: String?
    }
}

/// Do not forward credentials across redirects, use shared cookie/credential stores, or cache results.
final class LLMDirectRequestDelegate: NSObject, URLSessionDataDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, willCacheResponse proposedResponse: CachedURLResponse, completionHandler: @escaping @Sendable (CachedURLResponse?) -> Void) { completionHandler(nil) }
}
