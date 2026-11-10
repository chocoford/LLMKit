import Foundation
import LLMCore

/// Explicit transport/billing selection. Missing BYOK credentials never select platform billing.
public enum LLMSchemeBilling: Codable, Equatable, Sendable {
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
        let prepared = try await prepareScheme(selection, billing: billing)
        return try await invokePreparedScheme(prepared.selection, billing: billing, credentials: prepared.credentials,
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
        let prepared = try await prepareScheme(selection, billing: billing)
        return try await streamPreparedScheme(prepared.selection, billing: billing, credentials: prepared.credentials,
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

    internal func prepareScheme(_ requested: LLMSchemeSelection, billing: LLMSchemeBilling,
                               credentialsProvider: (@Sendable () async throws -> LLMBYOKCredentials)? = nil) async throws
        -> (selection: LLMSchemeSelection, credentials: LLMBYOKCredentials?, kind: LLMSchemeKind, model: SupportedModel?) {
        guard !isDirectBYOK else { throw LLMDirectError.unsupportedCapability("server schemes") }
        var selection = requested
        try selection.validate()
        let credentials: LLMBYOKCredentials?
        switch billing {
        case .platform:
            credentials = nil // Explicit selection; do not read the App's provider key.
        case .byok(let model):
            guard selection.profileID == nil else { throw LLMSchemeValidationError.invalidSelection }
            let value: LLMBYOKCredentials
            if let credentialsProvider { value = try await credentialsProvider() }
            else {
                guard let resolved = try await modelCredentials(for: model) else { throw LLMBYOKConfigurationError.providerRequired }
                value = resolved
            }
            try value.configuration.validate()
            _ = try value.validatedAPIKey()
            _ = try value.configuration.modelMapping.resolve(model.rawValue)
            credentials = value
        }

        try Task.checkCancellation()
        let scheme = try await getScheme(id: selection.schemeID)
        guard scheme.id == selection.schemeID else { throw LLMSchemeValidationError.invalidSelection }
        if credentials == nil {
            selection.profileID = selection.profileID ?? scheme.defaultProfileID
            guard scheme.profiles.contains(where: { $0.id == selection.profileID }) else { throw LLMSchemeValidationError.invalidSelection }
        }
        let modelID = billing.modelID ?? scheme.profiles.first(where: { $0.id == selection.profileID })?.modelID
        let model = modelID.map(SupportedModel.init(rawValue:))
        let source: LLMAccessBillingSource = credentials == nil ? .platform : .byok
        let resources: [LLMAccessResource] = [
            .init(kind: "inference", id: "chat", billingSource: source),
            .init(kind: scheme.kind == .conversation ? "agent" : "image-scene", id: scheme.id,
                  billingSource: source, modelProfileID: selection.profileID)
        ]
        // Always preflight actual server identities before uploads. The server still
        // rechecks at invocation; public discovery/access metadata is never an admission token.
        for resource in resources {
            try await authorizeAccess(.init(resource: resource, model: model))
            let decision = try await getAccessDecision(for: resource)
            guard decision.allowed else {
                throw LLMError.accessDenied(requirementIDs: decision.missingRequirementIDs.isEmpty
                    ? decision.requirementIDs : decision.missingRequirementIDs)
            }
        }
        try Task.checkCancellation()
        return (selection, credentials, scheme.kind, model)
    }
}

private extension LLMSchemeBilling {
    var modelID: String? {
        if case .byok(let model) = self { return model.rawValue }
        return nil
    }
}
