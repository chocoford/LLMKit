//
//  LLMStatable+CreateConversation.swift
//  LLMKit
//

import Foundation
import StoreKit
import LLMCore
import Logging
import ChocofordEssentials

extension LLMStatable {
    func _createConversation<Metadata: Codable & Equatable & Sendable>(
        id: String,
        type: Conversation.ConversationTpye = .regular,
        model: SupportedModel,
        agentConfig: AgentConfig = .chat,
        appendingPrompt: String? = nil,
        messages: [ChatMessage],
        stream: Bool = true,
        metadata: Metadata = EmptyMetadata(),
        invocationContext: (any ChatInvocationContext)? = nil,
        replyTransformer: ((_ assistantMessage: ChatMessage) async throws -> ChatMessage)? = nil
    ) async throws {
        try await withConversationScheme {
            try LLMSchemeScope.provider(for: llmClient)?.validateAgent(agentConfig.agentID)
            try await _createConversationBody(id: id, type: type, model: model, agentConfig: agentConfig,
                appendingPrompt: appendingPrompt, messages: messages, stream: stream, metadata: metadata,
                invocationContext: invocationContext, replyTransformer: replyTransformer)
        }
    }

    private func _createConversationBody<Metadata: Codable & Equatable & Sendable>(
        id: String,
        type: Conversation.ConversationTpye,
        model: SupportedModel,
        agentConfig: AgentConfig,
        appendingPrompt: String?,
        messages: [ChatMessage],
        stream: Bool,
        metadata: Metadata,
        invocationContext: (any ChatInvocationContext)?,
        replyTransformer: ((_ assistantMessage: ChatMessage) async throws -> ChatMessage)?
    ) async throws {
        guard case .loaded = conversations else {
            throw ConversationNotReadyError()
        }
        guard self.conversations.value?.first(where: { $0.id == id }) == nil else {
            throw NSError(domain: "LLMStatable", code: 1, userInfo: [NSLocalizedDescriptionKey: "Conversation with ID \(id) already exists"])
        }
        try llmClient.validateAgentForCurrentMode(agentConfig.agentID)

        // Create new conversation
        let newConversation: Conversation = .init(
            id: id,
            type: type,
            agentConfig: agentConfig,
            title: "New conversation",
            createdAt: .now,
            lastChatAt: .now,
            directConnection: llmClient.directClient.map { .init(configuration: $0.provider.configuration, chatModel: model) },
            schemeConnection: LLMSchemeScope.provider(for: llmClient)?.conversationBinding
        )
        await MainActor.run {
            self.conversations.transform {
                $0.insert(newConversation, at: 0)
            }
        }
        try await persistenceProvider?.updateConversation(action: .insert(newConversation))

        // Generate and add system message
        guard let index = self.conversations.value?.firstIndex(where: { $0.id == id }) else {
            throw ConversationNotFoundError()
        }

        // Build complete system prompt
        var systemPromptParts: [String] = []

        // 1. AgentConfig prompt (system prompt + strategy instructions)
        let agentPrompt = agentConfig.prompt
        if !agentPrompt.isEmpty {
            systemPromptParts.append(agentPrompt)
        }

        // 2. Tools description (if agent uses tools)
        if !agentConfig.tools.isEmpty {
            let toolsDesc = await toolRegistry.generateToolsDescription(for: agentConfig.tools, nativeToolCalls: llmClient.isDirectBYOK)
            if !toolsDesc.isEmpty {
                systemPromptParts.append(toolsDesc)
            }
        }

        // 3. User-provided appending prompt (if any) appended last
        if let appendingPrompt = appendingPrompt, !appendingPrompt.isEmpty {
            systemPromptParts.append(appendingPrompt)
        }

        // Combine all parts and add as system message
        if !systemPromptParts.isEmpty {
            let completeSystemPrompt = systemPromptParts.joined(separator: "\n\n")
            let systemMsgContent = ChatMessageContent(
                id: UUID().uuidString,
                role: .system,
                content: completeSystemPrompt
            )
            let systemMsg = ChatMessage.content(systemMsgContent)
            await MainActor.run {
                self.conversations.transform {
                    $0[index].messages.append(systemMsg)
                }
            }
            try await persistenceProvider?.updateConversation(
                action: .update(id, .insert([systemMsg]))
            )
        }

        // Keep title generation parallel, but attach its accounting only after input
        // persistence. A fast response must not lose usage before the user message exists.
        var titleUsageTask: Task<[LLMInferenceUsage], Never>?
        if let firstUserMessage = messages.first, let content = firstUserMessage.content, !content.isEmpty {
            let titleClient = llmClient
            titleUsageTask = Task {
              var usageRecords: [LLMInferenceUsage] = []
              do {
                logger.info("Generating title for new conversation...")
                let result = try await titleClient.auxiliaryChat(
                    preferredModel: model,
                    platformModel: .gpt35Turbo,
                    system: """
                    You are a conversation title generator. Generate a concise, descriptive title (3-8 words) based on the user's first message.

                    Rules:
                    - Return ONLY the title text, no quotes, no extra explanation
                    - Keep it short and clear
                    - Capture the main topic or intent
                    - Use title case

                    Example:
                    User: "How do I deploy a Swift app to the App Store?"
                    Title: Deploy Swift App to App Store
                    """,
                    text: content
                )
                usageRecords = result.data?.inferenceUsage ?? []

                if let credits = result.credits {
                    self.updateCreditsInfo(CreditsInfo(
                        balance: credits.remains,
                        periodicCredits: nil,
                        purchasedCredits: 0
                    ))
                }

                let title = result.data?.content ?? "New conversation"
                
                try await persistenceProvider?.updateConversation(
                    action: .update(id, .updateTitle(title))
                )
                await MainActor.run {
                    if let index = self.conversations.value?.firstIndex(where: { $0.id == id }) {
                        self.conversations.transform {
                            $0[index].title = title
                        }
                    }
                }
                return usageRecords
              } catch {
                // A title failure must not escape an unobserved Task or change inference modes.
                logger.warning("Title generation failed; keeping the local conversation title.")
                return usageRecords
              }
            }
        }
        defer {
            if let titleUsageTask, let anchorID = messages.first?.id {
                Task {
                    let records = await titleUsageTask.value
                    do { try await recordAuxiliaryUsage(records, in: id, messageID: anchorID) }
                    catch { logger.error("Failed to persist title usage: \(error)") }
                }
            }
        }

        guard let index = self.conversations.value?.firstIndex(where: { $0.id == id }) else {
            throw ConversationNotFoundError()
        }

        // Insert all messages except the last one as context
        if messages.count > 1 {
            let contextMessages = messages.dropLast()
            await MainActor.run {
                self.conversations.transform {
                    $0[index].messages.append(contentsOf: contextMessages)
                }
            }
            try await persistenceProvider?.updateConversation(
                action: .update(id, .insert(Array(contextMessages)))
            )
        }
        
        // Send only the last message to get a response
        if let lastMessage = messages.last {
            try await _sendMessage(
                to: id,
                model: model,
                message: lastMessage,
                stream: stream,
                metadata: metadata,
                invocationContext: invocationContext,
                replyTransformer: replyTransformer
            )
        }
    }

}
