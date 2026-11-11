//
//  LLMStatable+ConversationLifecycle.swift
//  LLMKit
//

import Foundation
import StoreKit
import LLMCore
import Logging
import ChocofordEssentials

extension LLMStatable {
    /// 在 truncate/clear 这种结构性修改前调一下: cancel 当前生成 + 等任务真正退出再继续,
    /// 避免 in-flight Task 跟我们这边修改 conversations 同时写 race。
    /// `_cancelGeneration` 是 fire-and-forget (UI cancel 按钮用), 这里要等。
    fileprivate func cancelAndAwait(conversationID: String) async {
        guard let task = inflightTasks[conversationID] else { return }
        task.cancel()
        _ = try? await task.value
        inflightTasks[conversationID] = nil
        runningConversationIDs.remove(conversationID)
    }

    /// 把会话截断到指定 message。inclusive=true 时连同 fromMessageID 自身一起删,
    /// false 时只删它之后的。常用于"在这条消息处重新生成 / 分支"场景。
    /// 截断前会先 cancel 当前 in-flight 生成 (如果有), 等它停稳再修改。
    func _truncateConversation(
        in conversationID: String,
        fromMessageID: String,
        inclusive: Bool
    ) async throws {
        guard case .loaded = conversations else { throw ConversationNotReadyError() }
        guard let convIndex = conversations.value?.firstIndex(where: { $0.id == conversationID }) else {
            throw ConversationNotFoundError()
        }

        guard let msgIndex = conversations.value?[convIndex].messages.firstIndex(where: { $0.id == fromMessageID }) else {
            throw ChatMessageNotFoundError()
        }

        await cancelAndAwait(conversationID: conversationID)

        let cutIndex = inclusive ? msgIndex : msgIndex + 1
        let messagesToRemove = Array(conversations.value![convIndex].messages[cutIndex...])
        let removedIDs = messagesToRemove.map(\.id)

        await MainActor.run {
            self.conversations.transform {
                $0[convIndex].messages.removeSubrange(cutIndex...)
            }
        }

        if !removedIDs.isEmpty {
            try await persistenceProvider?.updateConversation(
                action: .update(conversationID, .delete(removedIDs))
            )
        }
    }

    /// 把会话当前所有活跃历史压缩成一段摘要: 全部非-system 消息标 `isCompactedOut`,
    /// 在 messages 末尾追加一条 `isCompactSummary` 的 user role 摘要。
    /// 下次 sendMessage 时, contextMessages = [system, summary, 新发的消息], 干净简洁。
    /// 多次 compact 时旧 summary 也会被新一轮一起压进新 summary, 自然堆叠收敛。
    func _compactConversation(
        _ conversationID: String,
        summaryModel: SupportedModel
    ) async throws {
        guard case .loaded = conversations else { throw ConversationNotReadyError() }
        guard conversations.value?.firstIndex(where: { $0.id == conversationID }) != nil else {
            throw ConversationNotFoundError()
        }

        // 用户主动触发的 compact: 先取消 in-flight 生成, 等任务真正退出, 避免 race。
        await cancelAndAwait(conversationID: conversationID)

        try await withConversationScheme(conversationID) {
            try await _compactConversationCore(conversationID: conversationID, summaryModel: summaryModel)
        }
    }

    /// compaction 的核心逻辑, 不含"cancel in-flight"。
    /// 用户触发的 `_compactConversation` 会先 cancelAndAwait 再调它;
    /// `_runAgentLoop` 的 overflow 兜底从已经 in-flight 的上下文里调它 — 此时调 cancelAndAwait
    /// 会取消自己, 所以必须走这个 core 版本。
    func _compactConversationCore(
        conversationID: String,
        summaryModel: SupportedModel
    ) async throws {
        guard case .loaded = conversations else { throw ConversationNotReadyError() }
        guard let convIndex = conversations.value?.firstIndex(where: { $0.id == conversationID }) else {
            throw ConversationNotFoundError()
        }

        let summaryClient = llmClient
        let summaryModel = try summaryClient.summaryModel(for: conversations.value![convIndex], requested: summaryModel)

        let messages = conversations.value![convIndex].messages

        // 当前活跃非-system 消息全部压。一刀切, 不切割也就不存在 tool_use / tool_result 配对问题。
        var toCompactIndices: [Int] = []
        for (i, msg) in messages.enumerated() {
            guard case .content(let c) = msg, !c.isCompactedOut else { continue }
            if c.role != .system {
                toCompactIndices.append(i)
            }
        }

        guard !toCompactIndices.isEmpty else {
            self.logger.info("compact: nothing to compact for \(conversationID)")
            return
        }

        let toCompactContents = toCompactIndices.compactMap { i -> ChatMessageContent? in
            if case .content(let c) = messages[i] { return c }
            return nil
        }

        // 调便宜 model 生成 summary。这次调用本身不在 conversation 上下文里, 不影响主对话。
        let summary = try await self.generateCompactSummary(
            messages: toCompactContents,
            model: summaryModel,
            client: summaryClient,
            conversationID: conversationID
        )

        // 摘要消息: role=.user (避免冲淡主 system prompt), content 带前缀让模型识别;
        // isCompactSummary=true 让 UI 区分渲染。
        let summaryContent = ChatMessageContent(
            role: .user,
            content: "[Summary of earlier conversation]\n\n\(summary.content ?? "")",
            isCompactSummary: true,
            inferenceUsage: summary.inferenceUsage
        )
        let summaryMessage = ChatMessage.content(summaryContent)

        await MainActor.run {
            self.conversations.transform { convs in
                // 1. 给被压的消息标 isCompactedOut
                for i in toCompactIndices {
                    if case .content(var c) = convs[convIndex].messages[i] {
                        c.isCompactedOut = true
                        convs[convIndex].messages[i] = .content(c)
                    }
                }
                // 2. 在 messages 末尾追加 summary
                convs[convIndex].messages.append(summaryMessage)
            }
        }

        // 持久化: 更新被改的消息 + 追加 summary
        if let provider = persistenceProvider {
            let updatedMessages = self.conversations.value![convIndex].messages
            for i in toCompactIndices {
                try await provider.updateConversation(
                    action: .update(conversationID, .update(updatedMessages[i]))
                )
            }
            try await provider.updateConversation(
                action: .update(conversationID, .insert([summaryMessage]))
            )
        }
    }

    /// 用便宜 model 单独发一次 chat (不进 agent loop / 不进当前 conversation 上下文) 生成
    /// "earlier conversation"摘要。保留独立的实际用量, 调用方负责包成 isCompactSummary 消息。
    private func generateCompactSummary(
        messages: [ChatMessageContent],
        model: SupportedModel,
        client: LLMClient,
        conversationID: String
    ) async throws -> ChatMessageContent {
        let systemPrompt = """
        You are summarizing a conversation between a user and an assistant for context compression.
        Output a concise summary in 3-8 bullet points covering:
        - Key user goals and requests
        - Major decisions / approaches taken
        - Files / entities / state that were discussed or modified
        - Open questions or pending items

        Do NOT include filler, preamble, or follow-up suggestions. Output only the bulleted summary.
        """

        // 序列化成 LLM 可读的对话稿 (限制 toolCall arguments 长度避免 prompt 爆掉)
        let conversationText = messages.map { msg -> String in
            let label = "[\(msg.role.rawValue)]"
            var parts: [String] = []
            if let content = msg.content, !content.isEmpty {
                parts.append(content)
            }
            if let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                let calls = toolCalls.map { "tool_call \($0.name)(\($0.arguments.prefix(200)))" }
                parts.append(calls.joined(separator: ", "))
            }
            return "\(label) \(parts.joined(separator: " "))"
        }.joined(separator: "\n\n")

        let response: APIResponse<ChatMessageContent>
        if client.isDirectBYOK || LLMSchemeScope.provider(for: client) != nil {
            response = try await client.auxiliaryChat(preferredModel: model, platformModel: model, system: systemPrompt, text: "Conversation to summarize:\n\n\(conversationText)", purpose: "summary")
        } else {
            let result = try await client.chat(model: model, system: systemPrompt, text: "Conversation to summarize:\n\n\(conversationText)")
            response = result.classifyingUsage(purpose: "summary", model: model, billingSource: .platform)
        }
        guard let summary = response.data, summary.content?.isEmpty == false else {
            if let anchorID = messages.last?.id {
                try await recordAuxiliaryUsage(response.data?.inferenceUsage ?? [], in: conversationID, messageID: anchorID)
            }
            throw NSError(
                domain: "LLMStatable",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "LLM returned empty compact summary"]
            )
        }
        if let credits = response.credits {
            updateCreditsInfo(CreditsInfo(balance: credits.remains, periodicCredits: nil, purchasedCredits: 0))
        }
        return summary
    }

    /// 清空会话内容, 但**保留 system message** (它是 conversation 配置的一部分,
    /// 没了下次发送会拿不到 prompt)。想完全重置请用 deleteConversation + createConversation。
    func _clearConversation(_ conversationID: String) async throws {
        guard case .loaded = conversations else { throw ConversationNotReadyError() }
        guard let convIndex = conversations.value?.firstIndex(where: { $0.id == conversationID }) else {
            throw ConversationNotFoundError()
        }

        await cancelAndAwait(conversationID: conversationID)

        let messages = conversations.value![convIndex].messages
        let removedIDs = messages.compactMap { msg -> String? in
            if case .content(let c) = msg, c.role == .system { return nil }
            return msg.id
        }

        await MainActor.run {
            self.conversations.transform {
                $0[convIndex].messages.removeAll { msg in
                    if case .content(let c) = msg, c.role == .system { return false }
                    return true
                }
            }
        }

        if !removedIDs.isEmpty {
            try await persistenceProvider?.updateConversation(
                action: .update(conversationID, .delete(removedIDs))
            )
        }
    }

    /// 取消对应 conversation 当前的生成。partial 已 commit 的消息不会被回滚。
    /// 计费按已收到的 settlement 算 (上游 OpenRouter 在断流前通常会回最后那条 usage chunk)。
    public func _cancelGeneration(conversationID: String) {
        guard let task = inflightTasks[conversationID] else { return }
        task.cancel()
        inflightTasks[conversationID] = nil
        runningConversationIDs.remove(conversationID)
    }


}
