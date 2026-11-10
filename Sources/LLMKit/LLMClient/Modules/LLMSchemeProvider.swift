import LLMCore

/// Reuses AgentExecutor/local tools while pinning routing to a stable server selection.
/// The LLMProvider `model` argument is only a legacy loop hint; it cannot override this
/// selection. BYOK's actual model is explicitly carried by `billing` instead.
public struct LLMSchemeProvider: LLMProvider {
    public let client: LLMClient
    public let selection: LLMSchemeSelection
    public let billing: LLMSchemeBilling
    public let connectionID: String?

    // A prepared provider owns one credential snapshot for every round of a generation.
    internal struct Credentials: Sendable { let value: LLMBYOKCredentials? }
    internal var credentials: Credentials?
    internal var executionModel: SupportedModel?

    internal func prepared(credentialsProvider: (@Sendable () async throws -> LLMBYOKCredentials)? = nil) async throws -> Self {
        let prepared = try await client.prepareScheme(selection, billing: billing, credentialsProvider: credentialsProvider)
        guard prepared.kind == .conversation else { throw LLMSchemeStateError.conversationRequired }
        var copy = Self(client: client, selection: prepared.selection, billing: billing, connectionID: connectionID)
        copy.credentials = Credentials(value: prepared.credentials)
        copy.executionModel = prepared.model
        return copy
    }

    public init(client: LLMClient, selection: LLMSchemeSelection, billing: LLMSchemeBilling, connectionID: String? = nil) {
        self.client = client; self.selection = selection; self.billing = billing; self.connectionID = connectionID
    }

    internal var conversationBinding: LLMSchemeConversationBinding {
        .init(selection: selection, billing: billing, connectionID: connectionID)
    }

    internal func auxiliaryModel(fallback: SupportedModel) -> SupportedModel {
        if case .byok(let model) = billing {
            return credentials?.value?.configuration.options.auxiliaryModel.map(SupportedModel.init(rawValue:)) ?? model
        }
        return fallback
    }

    public func chat<Metadata: ContentModel>(model: SupportedModel, messages: [ChatMessageContent],
        metadata: Metadata?, agentID: String?, tools: [ToolSchema]?) async throws -> APIResponse<ChatMessageContent> {
        try validateAgent(agentID)
        if let credentials {
            return try await client.invokePreparedScheme(selection, billing: billing, credentials: credentials.value,
                messages: messages, metadata: metadata, tools: tools)
        }
        return try await client.invokeScheme(selection, billing: billing, messages: messages, metadata: metadata, tools: tools)
    }

    public func streamChat<Metadata: ContentModel>(model: SupportedModel, messages: [ChatMessageContent],
        metadata: Metadata?, agentID: String?, tools: [ToolSchema]?) async throws -> AsyncThrowingStream<StreamChatResponse, Error> {
        try validateAgent(agentID)
        if let credentials {
            return try await client.streamPreparedScheme(selection, billing: billing, credentials: credentials.value,
                messages: messages, metadata: metadata, tools: tools)
        }
        return try await client.streamScheme(selection, billing: billing, messages: messages, metadata: metadata, tools: tools)
    }

    internal func validateAgent(_ agentID: String?) throws {
        guard agentID == nil || agentID == selection.schemeID else { throw LLMSchemeValidationError.invalidSelection }
    }
}
