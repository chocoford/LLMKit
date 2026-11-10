//
//  LLMStatable+SendMessage.swift
//  LLMKit
//

import Foundation
import StoreKit
import LLMCore
import Logging
import ChocofordEssentials

extension LLMStatable {
    func _regenerateMessage<Metadata: Codable & Equatable & Sendable>(
        in conversationID: String,
        fromMessageID: String,
        model: SupportedModel,
        stream: Bool = true,
        metadata: Metadata = EmptyMetadata(),
        invocationContext: (any ChatInvocationContext)? = nil,
        replyTransformer: ((_ assistantMessage: ChatMessage) async throws -> ChatMessage)? = nil
    ) async throws {
        let task = Task<Void, Error> { [weak self] in
            guard let self else { return }
            try await self.withConversationScheme(conversationID) {
                try await self._regenerateMessageBody(in: conversationID, fromMessageID: fromMessageID,
                    model: model, stream: stream, metadata: metadata, invocationContext: invocationContext,
                    replyTransformer: replyTransformer)
            }
        }
        self.inflightTasks[conversationID] = task
        defer { self.inflightTasks[conversationID] = nil }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func _regenerateMessageBody<Metadata: Codable & Equatable & Sendable>(
        in conversationID: String,
        fromMessageID: String,
        model: SupportedModel,
        stream: Bool,
        metadata: Metadata,
        invocationContext: (any ChatInvocationContext)?,
        replyTransformer: ((_ assistantMessage: ChatMessage) async throws -> ChatMessage)?
    ) async throws {
        guard case .loaded = conversations else {
            throw ConversationNotReadyError()
        }

        guard let index = self.conversations.value?.firstIndex(where: { $0.id == conversationID }) else {
            throw ConversationNotFoundError()
        }

        try llmClient.validateConnection(for: self.conversations.value![index])

        // Find the assistant message to regenerate
        guard let assistantMessageIndex = self.conversations.value![index].messages.firstIndex(where: { $0.id == fromMessageID }) else {
            throw NSError(domain: "LLMStatable", code: 2, userInfo: [NSLocalizedDescriptionKey: "Message with ID \(fromMessageID) not found"])
        }

        // Find the user message that corresponds to this assistant message
        let messagesBeforeAssistant = self.conversations.value![index].messages.prefix(upTo: assistantMessageIndex)
        guard let userMessageIndex = messagesBeforeAssistant.lastIndex(where: {
            if case .content(let content) = $0 {
                return content.role == .user
            }
            return false
        }) else {
            throw NSError(domain: "LLMStatable", code: 3, userInfo: [NSLocalizedDescriptionKey: "No user message found before the assistant message"])
        }

        let userMessage = self.conversations.value![index].messages[userMessageIndex]

        // Remove all messages from the user message onwards (including the user message itself)
        let messagesToRemove = Array(self.conversations.value![index].messages.suffix(from: userMessageIndex))
        await MainActor.run {
            self.conversations.transform {
                $0[index].messages.removeSubrange(userMessageIndex...)
            }
        }

        // Persist the removal
        try await persistenceProvider?.updateConversation(
            action: .update(conversationID, .delete(messagesToRemove.map { $0.id }))
        )

        // Resend the user message to generate a new response
        try await _sendMessage(
            to: conversationID,
            model: model,
            message: userMessage,
            stream: stream,
            metadata: metadata,
            invocationContext: invocationContext,
            replyTransformer: replyTransformer
        )
    }

    func _sendMessage<Metadata: Codable & Equatable & Sendable>(
        to conversationID: String,
        model: SupportedModel,
        message: ChatMessage,
        stream: Bool = true,
        metadata: Metadata = EmptyMetadata(),
        invocationContext: (any ChatInvocationContext)? = nil,
        replyTransformer: ((_ assistantMessage: ChatMessage) async throws -> ChatMessage)? = nil
    ) async throws {
        // 把整个生成主体包成一个 child Task, 注册到 inflightTasks。两条 cancel 路径都覆盖:
        //   1. llmState.cancelGeneration(conversationID:) → _cancelGeneration → task.cancel()
        //   2. 调用方自己 outerTask.cancel() → cancellation 沿 await 链路传到这里 →
        //      withTaskCancellationHandler.onCancel 把它桥接到 inner task.cancel()
        // 任意一条触发都能让 inner task 内部 await 抛 CancellationError, 进入下面 catch 静默吞。
        // 没这个 handler 时, outer cancel 在 sendMessage 的 entry await 直接 rethrow 给调用方,
        // 客户端 catch 到 CancellationError print 出"The operation couldn't be completed..."。
        let task = Task<Void, Error> { [weak self] in
            guard let self else { return }
            try await self.withConversationScheme(conversationID) {
                try await self._sendMessageBody(
                    to: conversationID,
                    model: model,
                    message: message,
                    stream: stream,
                    metadata: metadata,
                    invocationContext: invocationContext,
                    replyTransformer: replyTransformer
                )
            }
        }
        self.inflightTasks[conversationID] = task
        defer {
            self.inflightTasks[conversationID] = nil
            self.runningConversationIDs.remove(conversationID)
        }

        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch let error where isUserCancellationError(error) {
            // 用户主动取消, 不向上抛。loading 占位移除掉避免 UI 一直转。
            await MainActor.run {
                if let i = self.conversations.value?.firstIndex(where: { $0.id == conversationID }) {
                    self.conversations.transform {
                        $0[i].messages.removeAll(where: {
                            if case .loading = $0 { return true } else { return false }
                        })
                    }
                }
            }
            self.logger.info("sendMessage cancelled for conversation \(conversationID)")
        }
    }


    /// 真正的发送主体, 以前是 _sendMessage 的整个 body, 现在被包到可取消的 child Task 里。
    /// 这一层只负责"把新 user message 落到 conversation.messages", 然后委托给共享的 `_runAgentLoop`。
    /// resume 路径走同一个 `_runAgentLoop` 但跳过"append message"步骤。
    func _sendMessageBody<Metadata: Codable & Equatable & Sendable>(
        to conversationID: String,
        model: SupportedModel,
        message: ChatMessage,
        stream: Bool = true,
        metadata: Metadata = EmptyMetadata(),
        invocationContext: (any ChatInvocationContext)? = nil,
        replyTransformer: ((_ assistantMessage: ChatMessage) async throws -> ChatMessage)? = nil
    ) async throws {
        guard case .loaded = conversations else {
            throw ConversationNotReadyError()
        }

        guard let index = self.conversations.value?.firstIndex(where: { $0.id == conversationID }) else {
            throw ConversationNotFoundError()
        }

        try llmClient.validateConnection(for: self.conversations.value![index])

        // 在 append 之前抓 anchor: 持久化时从这里 suffix 拿"用户消息 + 这次 agent run 产出的所有消息"。
        let persistFromIndex = self.conversations.value![index].messages.count

        await MainActor.run {
            self.conversations.transform {
                $0[index].messages.append(message)
            }
        }
        self.runningConversationIDs.insert(conversationID)

        try await _runAgentLoop(
            in: conversationID,
            persistFromIndex: persistFromIndex,
            model: model,
            stream: stream,
            metadata: metadata,
            invocationContext: invocationContext,
            replyTransformer: replyTransformer
        )
    }

}
