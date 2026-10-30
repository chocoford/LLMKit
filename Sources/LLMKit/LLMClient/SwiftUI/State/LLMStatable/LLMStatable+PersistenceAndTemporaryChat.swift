//
//  LLMStatable+PersistenceAndTemporaryChat.swift
//  LLMKit
//

import Foundation
import StoreKit
import LLMCore
import Logging
import ChocofordEssentials

extension LLMStatable {
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
    
    @discardableResult
    func _temporaryChat(
        model: SupportedModel,
        messages: [ChatMessage],
        stream: Bool = true,
        onUpdate: @escaping (_ message: ChatMessage) async throws -> Void,
        onFirstReply: @escaping (_ message: ChatMessage) async throws -> Void,
    ) async throws -> ChatMessage {
        let client = llmClient
        if stream {
            let stream = try await client.streamChat(
                model: model,
                messages: messages.contentMessages
            )
            var resMessage: ChatMessage?
            for try await result in stream {
                print("[_temporaryChat] Received stream result: \(String(describing: result).prefix(1024))")
                switch result {
                    case .message(let result):
                        if client.isDirectBYOK {
                            // Direct emits cumulative native-tool snapshots, not text deltas.
                            let isFirstReply = resMessage == nil
                            resMessage = .content(result)
                            if isFirstReply { try await onFirstReply(resMessage!) }
                        } else if case .content(let partial) = resMessage {
                            let newContent = (partial.content ?? "") + (result.content ?? "")
                            resMessage?.content = newContent
                        } else {
                            resMessage = ChatMessage.content(result)
                            try await onFirstReply(resMessage!)
                        }
                    case .settlement(let creditsResult):
                        resMessage?.usage = creditsResult
                        // update credits
                        self.updateCreditsInfo(CreditsInfo(
                            balance: creditsResult.remains,
                            periodicCredits: nil,
                            purchasedCredits: 0
                        ))
                }
                if let resMessage {
                    try await onUpdate(resMessage)
                }
            }
            try Task.checkCancellation()
            guard resMessage != nil else {
                logger.error("No response message received in streaming")
                throw NSError() // Should never called
            }
            return resMessage!
        } else {
            let result = try await client.chat(model: model, messages: messages.contentMessages)
            if let error = result.error { throw LLMError.server(statusCode: error.code, message: error.message) }
            guard var content = result.data else { throw LLMError.server(statusCode: 502, message: "No response received") }
            if let credits = result.credits {
                content.usage = credits
                self.updateCreditsInfo(CreditsInfo(balance: credits.remains, periodicCredits: nil, purchasedCredits: 0))
            }
            let message = ChatMessage.content(content)
            try await onFirstReply(message)
            try await onUpdate(message)
            return message
        }
    }
}
