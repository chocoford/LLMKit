import Foundation
import LLMCore

/// Explicit transport/billing selection. Missing BYOK credentials never select platform billing.
public enum LLMSchemeBilling: Sendable {
    case platform
    case byok(model: SupportedModel)
}

extension LLMClient {
    /// App-scoped, public scheme metadata; never reads or sends a provider key.
    public func getSchemes() async throws -> [LLMSchemeDescriptor] {
        guard !isDirectBYOK else { throw LLMDirectError.unsupportedCapability("server schemes") }
        return try await networking.get("/schemes")
    }

    public func getScheme(id: String) async throws -> LLMSchemeDescriptor {
        guard !isDirectBYOK else { throw LLMDirectError.unsupportedCapability("server schemes") }
        try LLMSchemeSelection(schemeID: id).validate()
        return try await networking.get("/schemes/\(id)")
    }

    /// Conversations pass messages/tools; image schemes pass their declared parameters.
    /// Platform models/prompts are resolved by the server from stable scheme/profile IDs.
    public func invokeScheme<Metadata: ContentModel>(
        _ selection: LLMSchemeSelection,
        billing: LLMSchemeBilling,
        messages: [ChatMessageContent] = [],
        parameters: [String: String] = [:],
        metadata: Metadata? = EmptyMetadata(),
        tools: [ToolSchema]? = nil
    ) async throws -> APIResponse<ChatMessageContent> {
        let credentials = try await schemeCredentials(selection, billing: billing)
        return try await invokePreparedScheme(selection, billing: billing, credentials: credentials,
            messages: messages, parameters: parameters, metadata: metadata, tools: tools)
    }

    internal func invokePreparedScheme<Metadata: ContentModel>(
        _ selection: LLMSchemeSelection, billing: LLMSchemeBilling, credentials: LLMBYOKCredentials?,
        messages: [ChatMessageContent], parameters: [String: String] = [:], metadata: Metadata?, tools: [ToolSchema]?
    ) async throws -> APIResponse<ChatMessageContent> {
        let body = LLMSchemeRequest(
            scheme: selection, messages: try await prepareUploadFiles(for: messages),
            parameters: parameters, metadata: metadata, tools: tools,
            byokModelID: billing.modelID
        )
        return try await networking.postInference("/schemes/invoke", body: body, credentials: credentials)
    }

    /// Strict completion is required for both platform and BYOK scheme streams.
    public func streamScheme<Metadata: ContentModel>(
        _ selection: LLMSchemeSelection,
        billing: LLMSchemeBilling,
        messages: [ChatMessageContent] = [],
        parameters: [String: String] = [:],
        metadata: Metadata? = EmptyMetadata(),
        tools: [ToolSchema]? = nil
    ) async throws -> AsyncThrowingStream<StreamChatResponse, Error> {
        let credentials = try await schemeCredentials(selection, billing: billing)
        return try await streamPreparedScheme(selection, billing: billing, credentials: credentials,
            messages: messages, parameters: parameters, metadata: metadata, tools: tools)
    }

    internal func streamPreparedScheme<Metadata: ContentModel>(
        _ selection: LLMSchemeSelection, billing: LLMSchemeBilling, credentials: LLMBYOKCredentials?,
        messages: [ChatMessageContent], parameters: [String: String] = [:], metadata: Metadata?, tools: [ToolSchema]?
    ) async throws -> AsyncThrowingStream<StreamChatResponse, Error> {
        let body = LLMSchemeRequest(
            scheme: selection, messages: try await prepareUploadFiles(for: messages),
            parameters: parameters, metadata: metadata, tools: tools,
            byokModelID: billing.modelID
        )
        return try await networking.streamInference("/schemes/stream", body: body, credentials: credentials)
    }

    internal func schemeCredentials(_ selection: LLMSchemeSelection, billing: LLMSchemeBilling) async throws -> LLMBYOKCredentials? {
        guard !isDirectBYOK else { throw LLMDirectError.unsupportedCapability("server schemes") }
        try selection.validate()
        let credentials: LLMBYOKCredentials?
        switch billing {
        case .platform:
            credentials = nil // Explicit selection; do not read the App's provider key.
        case .byok(let model):
            guard selection.profileID == nil else { throw LLMSchemeValidationError.invalidSelection }
            guard let value = try await modelCredentials(for: model) else { throw LLMBYOKConfigurationError.providerRequired }
            credentials = value
        }

        // Optional host preflight uses exactly the same identities as the authoritative server.
        // Discovery is advisory, not a token; the server resolves and checks again at execution.
        if accessPolicy != nil {
            let scheme = try await getScheme(id: selection.schemeID)
            let profileID = credentials == nil ? selection.profileID ?? scheme.defaultProfileID : nil
            let modelID = billing.modelID ?? scheme.profiles.first(where: { $0.id == profileID })?.modelID
            let model = modelID.map(SupportedModel.init(rawValue:))
            let source: LLMAccessBillingSource = credentials == nil ? .platform : .byok
            try await authorizeAccess(.init(resource: .init(kind: "inference", id: "chat", billingSource: source), model: model))
            try await authorizeAccess(.init(resource: .init(
                kind: scheme.kind == .conversation ? "agent" : "image-scene", id: scheme.id,
                billingSource: source, modelProfileID: profileID
            ), model: model))
        }
        return credentials
    }
}

private extension LLMSchemeBilling {
    var modelID: String? {
        if case .byok(let model) = self { return model.rawValue }
        return nil
    }
}
