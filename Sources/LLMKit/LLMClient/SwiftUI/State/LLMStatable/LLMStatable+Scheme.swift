import LLMCore

extension LLMStatable {
    /// Resolve before changing messages or uploading files. Every entry point uses this
    /// boundary; nested send/overflow work inherits the already-prepared provider.
    func withConversationScheme<Result>(
        _ conversationID: String? = nil,
        operation: @MainActor () async throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        let client = llmClient
        let conversation: Conversation?
        if let conversationID {
            guard !schemeConnectionUpdates.contains(conversationID) else { throw LLMSchemeStateError.generationInProgress }
            guard case .loaded = conversations else { throw ConversationNotReadyError() }
            guard let stored = conversations.value?.first(where: { $0.id == conversationID }) else {
                throw ConversationNotFoundError()
            }
            conversation = stored
        } else { conversation = nil }

        let scoped = LLMSchemeScope.provider(for: client)
        guard let binding = conversation?.schemeConnection else {
            if let scoped {
                if conversation == nil { try scoped.conversationBinding.validate() }
                try scoped.validateAgent(conversation?.agentConfig.agentID)
            }
            return try await operation()
        }
        try binding.validate()
        guard !client.isDirectBYOK, conversation?.directConnection == nil else { throw LLMSchemeStateError.connectionMismatch }
        if let scoped {
            guard scoped.conversationBinding == binding else { throw LLMSchemeStateError.connectionMismatch }
            try scoped.validateAgent(conversation?.agentConfig.agentID)
            return try await operation()
        }

        let resolve: (@Sendable () async throws -> LLMBYOKCredentials)?
        switch binding.billing {
        case .platform: resolve = nil
        case .byok(let model):
            guard let connectionID = binding.connectionID, let credentials = schemeCredentialsProvider else {
                throw LLMSchemeStateError.credentialsProviderRequired
            }
            resolve = { try await credentials(connectionID, model) }
        }
        let provider = try await LLMSchemeProvider(client: client, selection: binding.selection,
            billing: binding.billing, connectionID: binding.connectionID).prepared(credentialsProvider: resolve)
        try provider.validateAgent(conversation?.agentConfig.agentID)
        try Task.checkCancellation()
        return try await LLMSchemeScope.$provider.withValue(provider) { try await operation() }
    }

    func _updateSchemeConnection(_ binding: LLMSchemeConversationBinding, in conversationID: String) async throws {
        try Task.checkCancellation()
        try binding.validate()
        guard case .loaded = conversations else { throw ConversationNotReadyError() }
        guard let conversation = conversations.value?.first(where: { $0.id == conversationID }) else {
            throw ConversationNotFoundError()
        }
        guard !llmClient.isDirectBYOK, conversation.directConnection == nil,
              let previous = conversation.schemeConnection else { throw LLMSchemeStateError.connectionMismatch }
        try previous.validate()
        if previous == binding { return }
        guard previous.selection.schemeID == binding.selection.schemeID else { throw LLMSchemeStateError.connectionMismatch }
        guard inflightTasks[conversationID] == nil, !runningConversationIDs.contains(conversationID),
              !schemeConnectionUpdates.contains(conversationID) else { throw LLMSchemeStateError.generationInProgress }
        if let scoped = LLMSchemeScope.provider(for: llmClient), scoped.conversationBinding != binding {
            throw LLMSchemeStateError.connectionMismatch
        }
        let store: (any LLMSchemeConversationPersistenceProvider)?
        if let persistenceProvider {
            guard let capable = persistenceProvider as? any LLMSchemeConversationPersistenceProvider else {
                throw LLMSchemeStateError.routePersistenceRequired
            }
            store = capable
        } else { store = nil }

        // Reserve this conversation while awaiting storage: sends/retries/resumes must
        // not start against the old route during an in-progress routing write.
        schemeConnectionUpdates.insert(conversationID)
        defer { schemeConnectionUpdates.remove(conversationID) }
        try await store?.updateSchemeConnection(binding, in: conversationID)
        guard let index = conversations.value?.firstIndex(where: { $0.id == conversationID }) else {
            throw ConversationNotFoundError()
        }
        conversations.transform { $0[index].schemeConnection = binding }
    }
}
