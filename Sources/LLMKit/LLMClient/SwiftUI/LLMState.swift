//
//  LLMState.swift
//  LLMKit
//
//  Created by Chocoford on 9/5/25.
//

#if canImport(SwiftUI)
import SwiftUI
import LLMCore

public struct Conversation: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var title: String
    public var messages: [ChatMessage] = []
    
    public init(
        id: UUID = UUID(),
        title: String,
        messages: [ChatMessage] = []
    ) {
        self.id = id
        self.title = title
        self.messages = messages
    }
}

@MainActor
public final class LLMStateObject: ObservableObject {
    var llmClient: LLMClient
    
    init(llmClient: LLMClient) {
        self.llmClient = llmClient
    }
    
    @Published public internal(set) var isAuthenticated: Bool = false
    
    @Published public internal(set) var conversations: [Conversation] = []
    
    @Published public internal(set) var credits: Double = 0
    
    func updateCredits(_ credits: Double) {
        self.credits = credits
    }
    
    public func getConversation(by id: UUID) -> Conversation? {
        return conversations.first { $0.id == id }
    }
    
    
    public func sendMessage(
        to conversationID: UUID,
        model: SupportedModel,
        message: ChatMessage
    ) async throws {
        if !conversations.contains(where: {$0.id == conversationID}) {
            await MainActor.run {
                self.conversations.insert(.init(id: conversationID, title: "New conversation"), at: 0)
            }
        }
        
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        await MainActor.run {
            self.conversations[index].messages.append(message)
        }
        print(conversations[index].messages)
        let stream = try await llmClient.chat(model: model, messages: conversations[index].messages)
        var resMessage: ChatMessage?
        for try await result in stream {
            switch result {
                case .message(let result):
                    if let partial = resMessage {
                        let newContent = (partial.content ?? "") + (result.choices.first?.delta.content ?? "")
                        resMessage?.content = newContent
                    } else {
                        resMessage = ChatMessage(id: result.id, role: .system)
                    }
                case .settlement(let creditsResult):
                    resMessage?.usage = creditsResult
            }
            await MainActor.run {
                if let i = self.conversations[index].messages.firstIndex(where: {$0.id == resMessage?.id}) {
                    self.conversations[index].messages[i] = resMessage!
                } else {
                    self.conversations[index].messages.append(resMessage!)
                }
            }
        }
    }
}


@available(macOS 14.0, iOS 17.0, *)
@Observable
public final class LLMState {
    
}

#endif // canImport(SwiftUI)
