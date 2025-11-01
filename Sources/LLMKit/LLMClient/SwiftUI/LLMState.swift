//
//  LLMState.swift
//  LLMKit
//
//  Created by Chocoford on 9/5/25.
//

#if canImport(SwiftUI)
import SwiftUI

import ChocofordEssentials
import LLMCore
import Logging

public enum ConversationPhase: String, Codable, Sendable {
    case idle
    case loading
}

public struct Conversation: Identifiable, Codable, Equatable, Sendable {
    public var id: String = UUID().uuidString
    public var title: String
    public var messages: [ChatMessage] = []
    public var phase: ConversationPhase = .idle
    
    public var createdAt: Date
    public var lastChatAt: Date
    
    public init(
        id: String = UUID().uuidString,
        title: String,
        messages: [ChatMessage] = [],
        createdAt: Date,
        lastChatAt: Date,
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.lastChatAt = lastChatAt
    }
}

//@MainActor
//protocol LLMInternalState: AnyObject {
//    var logger: Logger { get }
//    var llmClient: LLMClient { get }
//    var isAuthenticated: Bool { get set }
//    var conversations: [Conversation] { get set }
//    var credits: Double { get set }
//}

@MainActor
protocol LLMStatable: AnyObject {
    var logger: Logger { get }
    var llmClient: LLMClient { get }
    var isAuthenticated: Bool { get set }
    var conversations: Loadable<[Conversation]> { get set }
    var credits: Double { get set }
    var persistenceProvider: PersistenceProvider? { get }
    
    func sendMessage(
        to conversationID: String,
        model: SupportedModel,
        message: ChatMessage,
        stream: Bool,
    ) async throws
    
    func refreshConversations() async
}
struct ConversationNotReadyError: Error {}

extension LLMStatable {
    func updateCredits(_ credits: Double) {
        self.credits = credits
    }
    
    func _getConversation(by id: String) -> Conversation? {
        return conversations.value?.first { $0.id == id }
    }
    
    func _sendMessage(
        to conversationID: String,
        model: SupportedModel,
        message: ChatMessage,
        stream: Bool = true,
    ) async throws {
        guard case .loaded = conversations else {
            throw ConversationNotReadyError()
        }
        if !conversations.value!.contains(where: {$0.id == conversationID}) {
            let newConversation: Conversation = .init(
                id: conversationID,
                title: "New conversation",
                createdAt: .now,
                lastChatAt: .now
            )
            await MainActor.run {
                self.conversations.transform {
                    $0.insert(newConversation, at: 0)
                }
            }
            try await persistenceProvider?.updateConversation(action: .insert(newConversation))
        }
        
        guard let index = self.conversations.value?.firstIndex(where: { $0.id == conversationID }) else { return }
        
        await MainActor.run {
            self.conversations.transform {
                $0[index].messages.append(message)
            }
        }
        
        let loadingResponseMessage = ChatMessage.loading()
        let canStream = model.supportsStreaming
        await MainActor.run {
            self.conversations.transform {
                $0[index].messages.append(loadingResponseMessage)
            }
        }
        
        do {
            // Upload files if any
            let conversationAfterUploading = try await llmClient.prepareUploadFiles(
                for: self.conversations.value![index]
            )
            
            await MainActor.run {
                self.conversations.transform {
                    $0[index] = conversationAfterUploading
                }
            }
            
            logger.info("Sending message to conversation \(conversationID), model: \(model.rawValue), stream: \(stream), canStream: \(canStream)")
            for message in self.conversations.value![index].messages.contentMessages {
                logger.info("- \(String(describing: message).prefix(1024))")
            }
            logger.info("Sending message end")
            
            if stream && canStream {
                let stream = try await llmClient.streamChat(
                    model: model,
                    messages: self.conversations.value![index].messages.contentMessages
                )
                var resMessage: ChatMessage?
                for try await result in stream {
                    switch result {
                        case .message(let result):
                            if case .content(let partial) = resMessage {
                                let newContent = (partial.content ?? "") + (result.choices.first?.delta.content ?? "")
                                resMessage?.content = newContent
                            } else {
                                if let loaddingMessageIndex = conversations.value![index].messages.firstIndex(where: {$0.id == loadingResponseMessage.id}) {
                                    self.conversations.transform {
                                        $0[index].messages.remove(at: loaddingMessageIndex)
                                    }
                                }
                                resMessage = ChatMessage.content(ChatMessageContent(id: result.id, role: .system))
                            }
                        case .settlement(let creditsResult):
                            resMessage?.usage = creditsResult
                            // update credits
                            self.updateCredits(creditsResult.remains)
                    }
                    await MainActor.run {
                        if let i = conversations.value![index].messages.firstIndex(where: {$0.id == resMessage?.id}) {
                            self.conversations.transform {
                                $0[index].messages[i] = resMessage!
                            }
                        } else {
                            self.conversations.transform {
                                $0[index].messages.append(resMessage!)
                            }
                        }
                    }
                }
                if let resMessage {
                    try await persistenceProvider?.updateConversation(
                        action: .update(conversationID, .insert([message, resMessage]))
                    )
                }
            } else {
                let result = try await self.llmClient.chat(
                    model: model,
                    messages: conversations.value![index].messages.contentMessages
                )
                logger.info("Chat result: \(String(describing: result).prefix(1024))")
                if let loaddingMessageIndex = self.conversations.value![index].messages.firstIndex(where: {
                    $0.id == loadingResponseMessage.id
                }) {
                    await MainActor.run {
                        self.conversations.transform {
                            $0[index].messages.remove(at: loaddingMessageIndex)
                        }
                    }
                }
                if let error = result.error {
                    await MainActor.run {
                        self.conversations.transform {
                            $0[index].messages.append(.error(UUID(), error.message))
                        }
                    }
                } else if let resMessage = result.data?.choices.first?.message {
                    await MainActor.run {
                        self.conversations.transform {
                            $0[index].messages.append(resMessage)
                        }
                    }
                    if let credits = result.credits {
                        self.updateCredits(credits.remains)
                    }
                    
                    try await persistenceProvider?.updateConversation(
                        action: .update(
                            conversationID,
                            .insert([ message, resMessage ])
                        )
                    )
                }
            }
        } catch {
            if let loaddingMessageIndex = conversations.value![index].messages.firstIndex(where: {$0.id == loadingResponseMessage.id}) {
                await MainActor.run {
                    self.conversations.transform {
                        $0[index].messages.remove(at: loaddingMessageIndex)
                    }
                }
            }
            await MainActor.run {
                self.conversations.transform {
                    $0[index].messages.append(.error(UUID(), error.localizedDescription))
                }
            }
            throw error
        }
    }
    
    func _refreshConversations() async {
        self.logger.info("Refreshing conversations from persistence provider: \(String(describing: persistenceProvider))")
        guard let persistenceProvider else {
            self.conversations.setAsLoaded(self.conversations.value ?? [])
            return
        }
        conversations.setIsLoading()
        do {
            let conversations = try await persistenceProvider.restoreConversations()
            self.conversations.setAsLoaded(conversations)
        } catch {
            self.conversations.setAsFailed(error)
        }
    }
}


@MainActor
public final class LLMStateObject: ObservableObject, LLMStatable {
    let logger = Logger(label: "LLMStateObject")
    var llmClient: LLMClient
    var persistenceProvider: (any PersistenceProvider)?
    
    init(llmClient: LLMClient, persistenceProvider: PersistenceProvider?) {
        self.llmClient = llmClient
        self.persistenceProvider = persistenceProvider
    }
    
    @Published public internal(set) var isAuthenticated: Bool = false
    
    @Published public internal(set) var conversations: Loadable<[Conversation]> = .notRequested
    
    @Published public internal(set) var credits: Double = 0
    
    public func sendMessage(
        to conversationID: String,
        model: SupportedModel,
        message: ChatMessage,
        stream: Bool = true
    ) async throws {
        try await self._sendMessage(to: conversationID, model: model, message: message, stream: stream)
    }
    
    public func refreshConversations() async {
        await self._refreshConversations()
    }
    
    public func getConversation(by id: String) -> Conversation? {
        self._getConversation(by: id)
    }
}


@available(macOS 14.0, iOS 17.0, *)
@MainActor
@Observable
public final class LLMState: LLMStatable {
    let logger = Logger(label: "LLMStateObject")
    var llmClient: LLMClient
    var persistenceProvider: (any PersistenceProvider)?
    
    init(llmClient: LLMClient, persistenceProvider: PersistenceProvider?) {
        self.llmClient = llmClient
        self.persistenceProvider = persistenceProvider
    }
    
    
    public internal(set) var isAuthenticated: Bool = false
    public internal(set) var conversations: Loadable<[Conversation]> = .notRequested
    public internal(set) var credits: Double = 0
    
    public func sendMessage(
        to conversationID: String,
        model: SupportedModel,
        message: ChatMessage,
        stream: Bool = true
    ) async throws {
        try await self._sendMessage(to: conversationID, model: model, message: message, stream: stream)
    }
    
    public func refreshConversations() async {
        await self._refreshConversations()
    }
    
    public func getConversation(by id: String) -> Conversation? {
        self._getConversation(by: id)
    }
}

#endif // canImport(SwiftUI)
