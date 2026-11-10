//
//  LLMStateModels.swift
//  LLMKit
//
//  Created by Chocoford on 11/25/25.
//

import Foundation
import LLMCore

public enum ConversationPhase: String, Codable, Sendable {
    case idle
    case loading
}

/// Non-secret binding prevents silently sending Direct history through another connection.
public struct LLMDirectConversationBinding: Codable, Equatable, Sendable {
    public var configuration: LLMBYOKConfiguration
    public var chatModel: SupportedModel
    public init(configuration: LLMBYOKConfiguration, chatModel: SupportedModel) {
        self.configuration = configuration
        self.chatModel = chatModel
    }
}

public struct Conversation: Identifiable, Codable, Equatable, Sendable {
    public var id: String = UUID().uuidString
    
    public enum ConversationTpye: Codable, Equatable, Sendable {
        case regular
        case temporary
        case custom(_ label: String)

        public var rawValue: String {
            switch self {
                case .regular:
                    "regular"
                case .temporary:
                    "temporary"
                case .custom(let label):
                    label
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            // "normal" 是历史遗留值, 改名 regular 后仍接受旧数据 decode, 避免存量持久化数据迁移问题
            if value == "regular" || value == "normal" {
                self = .regular
            } else if value == "temporary" {
                self = .temporary
            } else {
                self = .custom(value)
            }
        }
    }
    
    public var type: ConversationTpye
    public var agentConfig: AgentConfig  // Agent configuration
    public var title: String
    public var messages: [ChatMessage] = []
    public var phase: ConversationPhase = .idle

    public var createdAt: Date
    public var lastChatAt: Date
    /// nil denotes an existing backend conversation. API keys are never serialized here.
    public var directConnection: LLMDirectConversationBinding?
    /// nil preserves legacy routing. Contains no key; custom persistence must retain this field.
    public var schemeConnection: LLMSchemeConversationBinding?

    public init(
        id: String = UUID().uuidString,
        type: ConversationTpye,
        agentConfig: AgentConfig = .chat,
        title: String,
        messages: [ChatMessage] = [],
        createdAt: Date,
        lastChatAt: Date,
        directConnection: LLMDirectConversationBinding? = nil,
        schemeConnection: LLMSchemeConversationBinding? = nil
    ) {
        self.id = id
        self.type = type
        self.agentConfig = agentConfig
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.lastChatAt = lastChatAt
        self.directConnection = directConnection
        self.schemeConnection = schemeConnection
    }
}
