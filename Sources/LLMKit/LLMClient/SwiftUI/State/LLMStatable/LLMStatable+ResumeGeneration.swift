//
//  LLMStatable+ResumeGeneration.swift
//  LLMKit
//

import Foundation
import StoreKit
import LLMCore
import Logging
import ChocofordEssentials

extension LLMStatable {
    /// 让 agent 在现有历史上接着跑。若尾部有连续 `.error(...)` stub, 先清掉再继续。
    /// 跟 _sendMessage 一样, 包成 child Task 注册到 inflightTasks, cancel 路径完整覆盖。
    func _resumeGeneration<Metadata: Codable & Equatable & Sendable>(
        in conversationID: String,
        model: SupportedModel,
        stream: Bool = true,
        metadata: Metadata = EmptyMetadata(),
        invocationContext: (any ChatInvocationContext)? = nil,
        replyTransformer: ((_ assistantMessage: ChatMessage) async throws -> ChatMessage)? = nil
    ) async throws {
        let task = Task<Void, Error> { [weak self] in
            guard let self else { return }
            try await self.withConversationScheme(conversationID) {
                try await self._resumeGenerationBody(
                    in: conversationID,
                    model: model,
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
            await MainActor.run {
                if let i = self.conversations.value?.firstIndex(where: { $0.id == conversationID }) {
                    self.conversations.transform {
                        $0[i].messages.removeAll(where: {
                            if case .loading = $0 { return true } else { return false }
                        })
                    }
                }
            }
            self.logger.info("resumeGeneration cancelled for conversation \(conversationID)")
        }
    }

    func _resumeGenerationBody<Metadata: Codable & Equatable & Sendable>(
        in conversationID: String,
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

        // .error stub 是 UI-only (不持久化), 只清理尾部连续的 error, 不需要同步 persistence delete。
        await MainActor.run {
            self.conversations.transform { conversations in
                while let last = conversations[index].messages.last {
                    guard case .error = last else { break }
                    conversations[index].messages.removeLast()
                }
            }
        }

        // 清完尾部 error stub 之后的 count 就是这次 resume 的持久化锚点 —
        // 之后 _runAgentLoop 跑出来的所有新消息都从这里 suffix 拿。
        let persistFromIndex = self.conversations.value![index].messages.count
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
