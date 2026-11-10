//
//  File.swift
//  LLMKit
//
//  Created by Chocoford on 10/30/25.
//

import Foundation
import LLMCore

public enum ConversationUpdateAction: Sendable {
    case insert(Conversation)
    case update(Conversation.ID, ChatMessageUpdateAction)
    case delete(Conversation.ID)
}

public enum ChatMessageUpdateAction: Sendable {
    case updateTitle(String)
    case insert([ChatMessage])
    case update(ChatMessage)
    case delete([ChatMessage.ID])
}

public protocol PersistenceProvider: Sendable {
    func restoreConversations() async throws -> [Conversation]
    
    func updateConversation(
        action: ConversationUpdateAction
    ) async throws
}

/// Optional additive capability. Existing stores keep working without changing their
/// action switches; opt in to allow explicit model/billing/connection changes in a saved Scheme conversation.
public protocol LLMSchemeConversationPersistenceProvider: PersistenceProvider {
    /// Atomically update only the route of an existing record. Never store provider keys.
    func updateSchemeConnection(_ binding: LLMSchemeConversationBinding, in conversationID: Conversation.ID) async throws
}
