//
//  LLMStatable+AgentLoop.swift
//  LLMKit
//

import Foundation
import StoreKit
import LLMCore
import Logging
import ChocofordEssentials

extension LLMStatable {
    /// 共享的 agent 跑动主体: 装 loading placeholder → 上传文件 → 跑 AgentExecutor → 消费流 → 持久化。
    /// 失败时把 loading 占位删掉、追加 `.error` stub、再 rethrow。
    /// `persistFromIndex` 是持久化锚点 — 持久化时只存 `messages[persistFromIndex..<end]` 这一段。
    /// - sendMessage 传"append user message 之前的 count" → 持久化覆盖 user message + agent 全部输出
    /// - resumeGeneration 传"resume 启动时的 count" → 持久化只覆盖这次 resume 新跑出来的部分
    /// 想换 tools 的客户端直接 mutate `conversation.agentConfig.tools` 即可, 这里读最新值。
    /// `contextOverflowRetried` 是内部递归标志, 别从外面手动传。catch 到 context overflow 错误时
    /// 会自动 compact + 用 `true` 递归重试一次; `true` 时再发生 overflow 不再重试, 走正常报错。
    func _runAgentLoop<Metadata: Codable & Equatable & Sendable>(
        in conversationID: String,
        persistFromIndex: Int,
        model: SupportedModel,
        stream: Bool,
        metadata: Metadata,
        invocationContext: (any ChatInvocationContext)?,
        replyTransformer: ((_ assistantMessage: ChatMessage) async throws -> ChatMessage)?,
        contextOverflowRetried: Bool = false
    ) async throws {
        guard case .loaded = conversations else {
            throw ConversationNotReadyError()
        }

        guard let index = self.conversations.value?.firstIndex(where: { $0.id == conversationID }) else {
            throw ConversationNotFoundError()
        }
        let llmClient = self.llmClient
        let schemeProvider = LLMSchemeScope.provider(for: llmClient)
        let model = schemeProvider?.executionModel ?? model
        try llmClient.validateConnection(for: self.conversations.value![index])
        if llmClient.isDirectBYOK {
            self.conversations.transform { $0[index].directConnection?.chatModel = model }
        }

        let loadingResponseMessage = ChatMessage.loading()
        let canStream = model.supportsStreaming
        await MainActor.run {
            self.conversations.transform {
                $0[index].messages.append(loadingResponseMessage)
            }
        }
        await MainActor.run {
            let streamState = self.streamingStore.stream(for: conversationID)
            streamState.id = UUID().uuidString
            streamState.isFinished = false
            // content/files/toolCalls 不再在 streamState 维护 — conversation.messages 是单一数据源,
            // streamState 只用作 "isStreaming(messageID:in:) API 需要的 (id + isFinished) 指针"。
            // 避免每帧 chunk 触发 5 个 @Published 字段 publish 累积出 100+/s 的无谓信号。
        }

        // upsertMessage 和 assistantThrottler 提到 do 块之外, 让 catch 块也能 flushNow,
        // 保证 cancel/error 时 pending 的最后一帧不被节流窗口吞掉。
        func upsertMessage(_ message: ChatMessage) {
            guard let i = self.conversations.value?.firstIndex(where: { $0.id == conversationID }) else {
                return
            }
            if let msgIdx = self.conversations.value![i].messages.firstIndex(where: { $0.id == message.id }) {
                self.conversations.transform { $0[i].messages[msgIdx] = message }
            } else {
                self.conversations.transform { $0[i].messages.append(message) }
            }
        }
        // 流式 assistant chunk 按 streamPublishStrategy 节流写入 messages。
        // tool 消息 / final commit / cancel 兜底走"立即 flush + 立即 upsert"路径, 不被节流影响。
        let assistantThrottler = StreamUpsertThrottler(strategy: self.streamPublishStrategy) { content in
            upsertMessage(.content(content))
        }
        var persistedMessageIDs: Set<String> = []

        func persistCompletedMessage(_ message: ChatMessage) async {
            guard case .content = message else { return }
            guard !persistedMessageIDs.contains(message.id) else { return }
            do {
                try await persistenceProvider?.updateConversation(
                    action: .update(conversationID, .insert([message]))
                )
                persistedMessageIDs.insert(message.id)
            } catch {
                logger.error("Failed to persist completed message \(message.id): \(error)")
            }
        }

        func messageInConversation(id: String) -> ChatMessage? {
            guard let i = self.conversations.value?.firstIndex(where: { $0.id == conversationID }) else {
                return nil
            }
            return self.conversations.value![i].messages.first(where: { $0.id == id })
        }

        do {
            // The state layer prepares/persists images before AgentExecutor calls chat().
            // Apply the host's optional admission check before those upload side effects too.
            try schemeProvider?.validateAgent(self.conversations.value![index].agentConfig.agentID)
            if schemeProvider == nil, llmClient.accessPolicy != nil, !llmClient.isDirectBYOK {
                _ = try await llmClient.inferenceCredentials(for: model, agentID: self.conversations.value![index].agentConfig.agentID)
            }
            // Upload/inline only the active context that will be sent to the model.
            // Compacted-out historical messages may contain stale local file URLs; they are not
            // part of contextMessages, so they must not fail the current run.
            let conversationAfterUploading = try await llmClient.prepareUploadFilesForActiveContext(
                for: self.conversations.value![index]
            )

            await MainActor.run {
                self.conversations.transform {
                    $0[index] = conversationAfterUploading
                }
            }

            // 本轮入口处先落完整输入消息(通常是刚 append 的 user message)。
            // context overflow 自动 compact 后递归重试时不重复做这步: 原 user 已经落库,
            // compact 生成的 summary 也由 compact 流程自己 insert。
            if !contextOverflowRetried,
               let i = conversations.value?.firstIndex(where: { $0.id == conversationID }) {
                let messages = conversations.value![i].messages
                let safeIndex = min(persistFromIndex, messages.endIndex)
                for message in messages.suffix(from: safeIndex) {
                    await persistCompletedMessage(message)
                }
            }

            logger.info("Running agent loop for conversation \(conversationID), model: \(model.rawValue), stream: \(stream), canStream: \(canStream)")
            for message in self.conversations.value![index].messages.contextMessages {
                logger.info("- \(String(describing: message).prefix(1024))")
            }
            logger.info("Running agent loop end")

            let conversation = self.conversations.value![index]
            let provider: any LLMProvider = schemeProvider.map { $0 as any LLMProvider } ?? llmClient
            let executor = AgentExecutor(llmProvider: provider, toolRegistry: toolRegistry)

            // Use AgentExecutor for all interactions (native tool-use; no separate onStep callback).
            // 流里会拿到三种 ChatMessageContent:
            //   - role=.assistant + toolCalls 非空 → 中间一轮(模型说话+决定调工具)
            //   - role=.tool                   → 工具执行结果
            //   - role=.assistant + 无 toolCalls → 终态(最终回复)
            let approvalHandler = self.toolApprovalHandler
            let responseStream = try await executor.execute(
                conversationID: conversation.id,
                agentConfig: conversation.agentConfig,
                // contextMessages 已经过滤掉 isCompactedOut 的旧消息, 只发当前活跃上下文 (system + summary + 最近 N 条)
                contextMessages: conversation.messages.contextMessages,
                model: model,
                metadata: metadata,
                invocationContext: invocationContext,
                toolResultTransformer: { toolMessage in
                    // 工具产出的图片(base64) 自动走 R2, 跟 user message 同一条 prepareUploadFiles 路径
                    try await llmClient.prepareUploadFiles(for: toolMessage)
                },
                toolApprovalHandler: approvalHandler
            )

            // Consume the stream
            var responseMessage: ChatMessage?
            // 当前正在 stream 的 assistant 消息 id (UI 渲染光标 / 流式 indicator 时用)。
            var streamingAssistantID: String?

            // upsertMessage / assistantThrottler 在 do 块外定义, 让 catch 块也能 flushNow。
            // removeLoadingIfPresent 这里就近定义, 仅给流式 loop 内用。

            func removeLoadingIfPresent() {
                if let i = self.conversations.value?.firstIndex(where: { $0.id == conversationID }),
                   let loaddingIndex = self.conversations.value![i].messages.firstIndex(where: { $0.id == loadingResponseMessage.id }) {
                    self.conversations.transform {
                        $0[i].messages.remove(at: loaddingIndex)
                    }
                }
            }

            for try await chatMessage in responseStream {
                responseMessage = chatMessage

                guard case .content(let content) = chatMessage else { continue }

                let completedAssistantMessage: ChatMessage? = await MainActor.run {
                    var completedAssistantMessage: ChatMessage?
                    removeLoadingIfPresent()

                    // 增量更新余额: 每收到一条带 usage 的 assistant chunk 立即刷, 不等流结束。
                    // 这样即便后续 throw (maxThoughtsReached / 网络中断 / cancel),
                    // 余额 widget 也能反映已确认扣款的最新值。
                    if let creditsResult = content.usage {
                        self.updateCreditsInfo(CreditsInfo(
                            balance: creditsResult.remains,
                            periodicCredits: nil,
                            purchasedCredits: 0
                        ))
                    }

                    switch content.role {
                    case .tool:
                        // 切换流: tool 结果到达前, 把 assistant throttler 里 pending 的最后一帧
                        // 强制 flush 进 messages — 保证 UI 看到 assistant 完整内容, 再看到 tool 卡片。
                        assistantThrottler.flushNow()
                        // tool 结果到达后, 上一条 assistant 已经不再出 token, 把 streamState 标完成 —
                        // 下一轮 assistant chunk 到来前, message-level 光标不应继续挂在上一条消息上。
                        // 下一轮 assistant 进来时 streamState 会被重新置 false (case .assistant 末尾)。
                        self.streamingStore.stream(for: conversationID).isFinished = true
                        if let streamingAssistantID,
                           let assistantMessage = messageInConversation(id: streamingAssistantID) {
                            completedAssistantMessage = assistantMessage
                        }
                        streamingAssistantID = nil
                        // tool 消息整条到来一次, 直接 upsert, 不进 throttler (节流是流式 assistant 专用)。
                        upsertMessage(.content(content))

                    case .assistant:
                        // 流式 chunk 进 throttler — `.immediate` 直接 upsert, `.throttled` 按窗口 coalesce。
                        // 同 id chunk 后帧 superset 前帧 (content/toolCalls 是累积态), "最后一帧覆盖" 安全。
                        // settlement 之后的 chunk 会带 usage, 同样走 in-place 覆盖, 计费信息不丢。
                        assistantThrottler.update(content)
                        streamingAssistantID = content.id

                        // streamState 只维护 (id + isFinished) 给 isStreaming() API 用。
                        // 不再每帧覆写 content/files/toolCalls — 它们本来就是 conversation.messages 那条
                        // 的镜像, 没有视图读, 写它们等于每帧浪费 5 倍 @Published publish (100+/s)。
                        let streamState = self.streamingStore.stream(for: conversationID)
                        if streamState.id != content.id {
                            // 只在 id 真切到新一轮 chunk 时才写, 同 id 多 chunk 不重复 publish
                            streamState.id = content.id
                        }
                        if streamState.isFinished {
                            // 多轮中间 (上一轮已完成, 新一轮开始) 才需要从 true 翻回 false
                            streamState.isFinished = false
                        }

                    default:
                        break
                    }
                    return completedAssistantMessage
                }
                if let completedAssistantMessage {
                    await persistCompletedMessage(completedAssistantMessage)
                }
                if case .content(let content) = chatMessage, content.role == .tool {
                    await persistCompletedMessage(chatMessage)
                }
            }

            // 流式 loop 退出, 强制 flush throttler — 最后一帧 pending 不能被节流窗口吞掉。
            await MainActor.run { assistantThrottler.flushNow() }

            // Cancel race: stream 可能在 inner task 还没消费下一个 chunk 时被打断 finish()
            // 而非 finish(throwing:), 这时下面的 guard 会拿到空 responseMessage 抛"No response"。
            // 但语义上这是 cancel 不是真正的"agent 没回复", 主动抛 CancellationError 让外层吞掉。
            try Task.checkCancellation()

            guard let finalMessage = responseMessage else {
                throw NSError(domain: "LLMStatable", code: 4, userInfo: [NSLocalizedDescriptionKey: "No response received from agent"])
            }

            // 余额更新已经在 stream 消费过程中增量完成 (见上面 for-loop 里的 updateCreditsInfo),
            // 这里不再补刷, 避免错误路径丢更新。

            // Apply transformer if provided
            var transformedMessage = finalMessage
            if let replyTransformer {
                transformedMessage = try await replyTransformer(transformedMessage)
            }

            if case .content(let content) = transformedMessage {
                await MainActor.run {
                    let streamState = self.streamingStore.stream(for: conversationID)
                    streamState.id = content.id
                    streamState.isFinished = true
                    // content/files/toolCalls 不再 mirror — 单一数据源在 conversation.messages
                }
            }

            await MainActor.run {
                if let i = self.conversations.value?.firstIndex(where: { $0.id == conversationID }) {
                    if let messageIndex = self.conversations.value![i].messages.firstIndex(where: { $0.id == transformedMessage.id }) {
                        self.conversations.transform {
                            $0[i].messages[messageIndex] = transformedMessage
                        }
                    } else {
                        self.conversations.transform {
                            $0[i].messages.append(transformedMessage)
                        }
                    }
                }
                self.streamingStore.removeStream(for: conversationID)
            }
            await persistCompletedMessage(transformedMessage)
        } catch {
            // 先 flush throttler pending — 即便 cancel/error, 节流窗口里最后一帧的内容也要落到 messages,
            // 否则 partial assistant 内容截止时间会是"最后一次 flush" 而非"cancel 那一刻", 短少 0-N ms 内容。
            await MainActor.run { assistantThrottler.flushNow() }

            if Task.isCancelled || isUserCancellationError(error) {
                if let i = conversations.value?.firstIndex(where: { $0.id == conversationID }) {
                    conversations.transform { $0[i].messages.removeAll { $0.id == loadingResponseMessage.id } }
                }
                streamingStore.removeStream(for: conversationID)
                throw CancellationError()
            }

            // 反应式 context overflow 兜底: 上游报"上下文超限"且本次还没重试过, 自动 compact + 重试一次。
            // - 用 _compactConversationCore (不走 cancelAndAwait, 避免取消自己)
            // - 重试用 contextOverflowRetried=true 标志, 防 compact 后仍 overflow 时无限递归
            // - 重试前必须清理本次失败留下的 UI state: 移 loading, 不 append .error (要让重试有干净起点),
            //   清 streamState; partial assistant 留在 messages 里 (作为本轮已生成内容的快照, compact
            //   会把它一起折叠进 summary, 不会浪费)
            if !contextOverflowRetried, isContextOverflowError(error) {
                self.logger.info("Context overflow detected for \(conversationID), auto-compacting and retrying once")

                if let loaddingMessageIndex = conversations.value![index].messages.firstIndex(where: { $0.id == loadingResponseMessage.id }) {
                    await MainActor.run {
                        self.conversations.transform {
                            $0[index].messages.remove(at: loaddingMessageIndex)
                        }
                    }
                }
                await MainActor.run {
                    self.streamingStore.removeStream(for: conversationID)
                }

                // 跑 compact (用同一个 model 当 summary model — 客户端如果要用便宜 model 跑 compact,
                // 应该走主动 compactConversation 路径, 这里 fallback 用当前 model 简化)。
                // compact 失败也不再 retry, 直接抛 — 上游报 overflow + compact 又挂, 这种 case 用户应该看到原错误。
                do {
                    try await self._compactConversationCore(conversationID: conversationID, summaryModel: model)
                } catch {
                    self.logger.error("Compact failed during overflow recovery: \(error). Surfacing original overflow.")
                    // compact 失败, 走正常 error 流程
                    await MainActor.run {
                        self.conversations.transform {
                            $0[index].messages.append(.error(UUID(), error.localizedDescription))
                        }
                    }
                    throw error
                }

                // 重试整个 _runAgentLoop。注意 persistFromIndex 用原来的, 因为 compact 之后 messages 里
                // 新增了 summary 消息但前面被压的也还在, suffix 仍然从 persistFromIndex 开始拿"这一轮的产出"。
                try await _runAgentLoop(
                    in: conversationID,
                    persistFromIndex: persistFromIndex,
                    model: model,
                    stream: stream,
                    metadata: metadata,
                    invocationContext: invocationContext,
                    replyTransformer: replyTransformer,
                    contextOverflowRetried: true
                )
                return
            }

            // 不可重试的错误 (cancel / 真正失败 / 已经重试过的 overflow): 走正常清理 + 报错路径。
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
            await MainActor.run {
                self.streamingStore.removeStream(for: conversationID)
            }

            throw error
        }
    }

}
