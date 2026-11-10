//
//  File.swift
//  LLMKit
//
//  Created by Chocoford on 1/14/26.
//

#if canImport(SwiftUI)
import SwiftUI

import ChocofordEssentials
import LLMCore
import Logging
import StoreKit


@MainActor
public final class LLMStreamingStateObject: ObservableObject, @MainActor StreamingMessageState {
    @Published public var id: String
    @Published public var conversationID: Conversation.ID
    @Published public var content: String
    @Published public var files: [ChatMessageContent.File]
    /// 当前正在 stream 的 assistant 消息附带的 tool calls (空 = 终态/纯回复)。
    @Published public var toolCalls: [ToolCall]
    @Published public var isFinished: Bool

    public init(conversationID: Conversation.ID) {
        self.id = UUID().uuidString
        self.conversationID = conversationID
        self.content = ""
        self.files = []
        self.toolCalls = []
        self.isFinished = false
    }
}


@MainActor
public final class LLMStateObject: ObservableObject, @MainActor LLMStatable {
    public typealias StreamingState = LLMStreamingStateObject

    let logger = Logger(label: "LLMStateObject")
    var llmClient: LLMClient
    /// 暴露给外部只读: UI 渲染历史消息里的 toolCalls 时, 用它按 name 反查 Tool 拿 displayName。
    public internal(set) var toolRegistry: ToolRegistry
    var persistenceProvider: (any PersistenceProvider)?
    let schemeCredentialsProvider: LLMSchemeConversationCredentialsProvider?
    @Published var schemeConnectionUpdates: Set<String> = []

    /// 流式 chunk 写入 messages 的频率策略, 详见 `StreamPublishStrategy`。
    public let streamPublishStrategy: StreamPublishStrategy

    public init(
        llmClient: LLMClient,
        toolRegistry: ToolRegistry = ToolRegistry(),
        persistenceProvider: PersistenceProvider?,
        streamPublishStrategy: StreamPublishStrategy = .immediate,
        schemeCredentialsProvider: LLMSchemeConversationCredentialsProvider? = nil
    ) {
        self.llmClient = llmClient
        self.toolRegistry = toolRegistry
        self.persistenceProvider = persistenceProvider
        self.streamPublishStrategy = streamPublishStrategy
        self.schemeCredentialsProvider = schemeCredentialsProvider
        // 默认 approval handler 桥到 publisher 模式 (详见 LLMState.init 同段注释)。
        self.toolApprovalHandler = nil
        self.toolApprovalHandler = { [weak self] request in
            guard let self else { return .deny(reason: "client gone") }
            return await self.awaitApprovalDecision(request)
        }
    }

    @Published public internal(set) var isAuthenticated: Bool = false

    @Published public internal(set) var conversations: Loadable<[Conversation]> = .notRequested

    public internal(set) var streamingStore: StreamingStore<LLMStreamingStateObject> = .init()

    @Published public internal(set) var creditsInfo: CreditsInfo? = nil

    var inflightTasks: [String: Task<Void, Error>] = [:]

    @Published public internal(set) var runningConversationIDs: Set<String> = []

    /// 当前等待 approval 的请求。SwiftUI 用 `.sheet(item: ...)` 监听 (用 ObservedObject 投影)。
    @Published public internal(set) var pendingApprovalRequest: ToolApprovalRequest?

    private var pendingApprovalContinuation: CheckedContinuation<ToolApprovalDecision, Never>?

    /// 客户端 UI 弹完 approval sheet 后调这个返回决策。
    public func respondToApproval(_ decision: ToolApprovalDecision) {
        pendingApprovalContinuation?.resume(returning: decision)
        pendingApprovalContinuation = nil
        pendingApprovalRequest = nil
    }

    /// Tool approval handler。默认 bridge 到 publisher 模式; 高级场景可重赋值。
    public var toolApprovalHandler: ToolApprovalHandler?

    /// Bridge 函数: 把 closure handler 转成 publisher 模式 + cancel-aware cleanup。
    private func awaitApprovalDecision(_ request: ToolApprovalRequest) async -> ToolApprovalDecision {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ToolApprovalDecision, Never>) in
                self.pendingApprovalContinuation = continuation
                self.pendingApprovalRequest = request
            }
        } onCancel: {
            Task { @MainActor in
                self.pendingApprovalContinuation?.resume(returning: .deny(reason: "cancelled"))
                self.pendingApprovalContinuation = nil
                self.pendingApprovalRequest = nil
            }
        }
    }

    /// 取消指定 conversation 当前正在跑的生成。Idempotent: 没有 in-flight 时是 no-op。
    /// partial 已 commit 进 conversation.messages 的内容会被保留, 计费按已 settlement 的算。
    public func cancelGeneration(conversationID: String) {
        self._cancelGeneration(conversationID: conversationID)
    }

    /// 这条 message 是不是 conversation 里当前正在接收 assistant token。
    /// 这是 message-level 状态, 只适合渲染某条 assistant bubble 的光标/打字态。
    /// tool call 执行、approval 等待、两轮 agent request 间隙都不会让某条 message 保持 streaming;
    /// 判断整条 run 是否仍在进行用 `isRunning(conversationID:)`。
    public func isStreaming(messageID: String, in conversationID: String) -> Bool {
        self._isStreaming(messageID: messageID, in: conversationID)
    }

    /// 这个 conversation 当前是否有一条 LLM run 在进行中。
    /// `sendMessage` 路径中, 新 user message 已经插入到 `conversation.messages` 后才会变为 true。
    /// `resumeGeneration` 路径中, 尾部 `.error` stub 已经清理后才会变为 true。
    /// true 覆盖整条 run: token streaming、tool call 执行、approval 等待、下一轮 agent request 间隙。
    /// 结束、取消或失败清理后变回 false。
    public func isRunning(conversationID: String) -> Bool {
        self._isRunning(conversationID: conversationID)
    }

    /// 估算指定 conversation 当前活跃上下文消耗的 token 数 (保守启发式, 不是 tokenizer 精确值)。
    /// 跟 `model.maxContextTokens` 对比, 用于 UI 进度条 / 预防性 compact 触发。
    /// **真正防溢出靠 LLMKit 内置的反应式兜底** — 上游报 context overflow 会自动 compact + 重试,
    /// 不需要客户端拿这个估算做精确门槛。
    public func estimatedTokenUsage(in conversationID: String) -> Int {
        self._estimatedTokenUsage(in: conversationID)
    }

    /// 把会话截断到指定 message。inclusive=true 连同 fromMessageID 自身一起删, false 只删它之后的。
    /// 内部会先 cancel 当前 in-flight 生成。
    public func truncateConversation(
        in conversationID: String,
        fromMessageID: String,
        inclusive: Bool
    ) async throws {
        try await self._truncateConversation(
            in: conversationID,
            fromMessageID: fromMessageID,
            inclusive: inclusive
        )
    }

    /// 清空会话内容, 保留 system message。完全重置请用 deleteConversation + createConversation。
    public func clearConversation(_ conversationID: String) async throws {
        try await self._clearConversation(conversationID)
    }

    /// 把会话当前所有活跃历史压缩成一段摘要, 节省 LLM context 用量。
    public func compactConversation(
        _ conversationID: String,
        summaryModel: SupportedModel = .gpt4oMini
    ) async throws {
        try await self._compactConversation(
            conversationID,
            summaryModel: summaryModel
        )
    }

    /// Computed property for backward compatibility
    public var credits: Double {
        creditsInfo?.balance ?? 0
    }

    // @discardableResult
    public func handlePurchase(verificationResult: VerificationResult<StoreKit.Transaction>) async throws {
        try await self._handlePurchase(verificationResult: verificationResult)

    }

    public func configurePersistenceProvider(_ provider: PersistenceProvider) {
        self._configurePersistenceProvider(provider)
    }

    /// Explicit model, platform/BYOK billing or connection selection while idle, within the same Scheme.
    public func updateSchemeConnection(_ binding: LLMSchemeConversationBinding, in conversationID: String) async throws {
        try await _updateSchemeConnection(binding, in: conversationID)
    }

    public func createConversation<Metadata: Codable & Equatable & Sendable>(
        id: String,
        type: Conversation.ConversationTpye = .regular,
        model: SupportedModel,
        agentConfig: AgentConfig = .chat,
        appendingPrompt: String? = nil,
        messages: [ChatMessage],
        stream: Bool = true,
        metadata: Metadata = EmptyMetadata(),
        context invocationContext: (any ChatInvocationContext)? = nil,
        replyTransformer: ((_ assistantMessage: ChatMessage) async throws -> ChatMessage)? = nil
    ) async throws {
        try await self._createConversation(
            id: id,
            type: type,
            model: model,
            agentConfig: agentConfig,
            appendingPrompt: appendingPrompt,
            messages: messages,
            stream: stream,
            metadata: metadata,
            invocationContext: invocationContext,
            replyTransformer: replyTransformer
        )
    }

    public func sendMessage<Metadata: Codable & Equatable & Sendable>(
        to conversationID: String,
        model: SupportedModel,
        message: ChatMessage,
        stream: Bool = true,
        metadata: Metadata = EmptyMetadata(),
        context invocationContext: (any ChatInvocationContext)? = nil,
        replyTransformer: ((_ assistantMessage: ChatMessage) async throws -> ChatMessage)? = nil
    ) async throws {
        // 双层 catch: 即便 _sendMessage 内部 cancel 路径有遗漏, 这里也兜底吞掉用户取消错误。
        do {
            try await self._sendMessage(
                to: conversationID,
                model: model,
                message: message,
                stream: stream,
                metadata: metadata,
                invocationContext: invocationContext,
                replyTransformer: replyTransformer
            )
        } catch let error where isUserCancellationError(error) {
            // 静默吞用户取消
        }
    }

    #if DEBUG
    /// Returns the context that would be sent for this `sendMessage` call without starting a run.
    ///
    /// The method simulates the `sendMessage` append step on a local copy, then returns the active
    /// `contextMessages` that AgentExecutor would receive. It does not mutate conversations, set
    /// `isRunning`, call the server, deduct credits, or persist anything.
    ///
    /// Default `activeContextOnly` mode has no upload side effects. Use `preparedForSend` only when
    /// you need to inspect the post-upload/post-inline file representation; with an uploader
    /// configured, that mode can upload files.
    public func debugChatContext(
        to conversationID: String,
        model: SupportedModel,
        message: ChatMessage,
        stream: Bool = true,
        filePreparationMode: DebugChatContextFilePreparationMode = .activeContextOnly
    ) async throws -> DebugChatContextSnapshot {
        try await self._debugChatContext(
            to: conversationID,
            model: model,
            message: message,
            stream: stream,
            filePreparationMode: filePreparationMode
        )
    }
    #endif

    public func regenerateMessage<Metadata: Codable & Equatable & Sendable>(
        in conversationID: String,
        fromMessageID: String,
        model: SupportedModel,
        stream: Bool = true,
        metadata: Metadata = EmptyMetadata(),
        context invocationContext: (any ChatInvocationContext)? = nil,
        replyTransformer: ((_ assistantMessage: ChatMessage) async throws -> ChatMessage)? = nil
    ) async throws {
        do {
            try await self._regenerateMessage(
                in: conversationID,
                fromMessageID: fromMessageID,
                model: model,
                stream: stream,
                metadata: metadata,
                invocationContext: invocationContext,
                replyTransformer: replyTransformer
            )
        } catch let error where isUserCancellationError(error) {
            // 静默吞用户取消
        }
    }

    /// 让 agent 在现有历史上接着跑。会先清掉尾部连续的 `.error` stub, 然后跑一轮新的 agent loop。
    public func resumeGeneration<Metadata: Codable & Equatable & Sendable>(
        in conversationID: String,
        model: SupportedModel,
        stream: Bool = true,
        metadata: Metadata = EmptyMetadata(),
        context invocationContext: (any ChatInvocationContext)? = nil,
        replyTransformer: ((_ assistantMessage: ChatMessage) async throws -> ChatMessage)? = nil
    ) async throws {
        do {
            try await self._resumeGeneration(
                in: conversationID,
                model: model,
                stream: stream,
                metadata: metadata,
                invocationContext: invocationContext,
                replyTransformer: replyTransformer
            )
        } catch let error where isUserCancellationError(error) {
            // 静默吞用户取消
        }
    }

    public func temporaryChat(
        model: SupportedModel,
        messages: [ChatMessage],
        stream: Bool = true,
        onUpdate: @escaping (_ message: ChatMessage) async throws -> Void,
        onFirstReply: @escaping (_ message: ChatMessage) async throws -> Void = { _ in },
    ) async throws -> ChatMessage {
        try await self._temporaryChat(
            model: model,
            messages: messages,
            stream: stream,
            onUpdate: onUpdate,
            onFirstReply: onFirstReply
        )
    }

    public func refreshConversations() async {
        await self._refreshConversations()
    }

    public func getConversation(by id: String) -> Conversation? {
        self._getConversation(by: id)
    }
}


#endif
