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
    case update(Conversation.ID, ChatMessageUpdateActoin)
    case delete(Conversation.ID)
}

public enum ChatMessageUpdateActoin: Sendable {
    case insert([ChatMessage])
    case update(ChatMessage)
    case delete(ChatMessage.ID)
}

public protocol PersistenceProvider: Sendable {
    func restoreConversations() async throws -> [Conversation]
    
    func updateConversation(
        action: ConversationUpdateAction
    ) async throws
}
