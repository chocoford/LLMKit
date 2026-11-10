//
//  LLMStatable.swift
//  LLMKit
//

import Foundation
import StoreKit
import LLMCore
import Logging
import ChocofordEssentials

@MainActor
protocol LLMStatable: AnyObject {
    associatedtype StreamingState: StreamingMessageState

    var logger: Logger { get }
    var llmClient: LLMClient { get }
    var toolRegistry: ToolRegistry { get }
    var isAuthenticated: Bool { get set }
    var conversations: Loadable<[Conversation]> { get set }
    var streamingStore: StreamingStore<StreamingState> { get set }

    var creditsInfo: CreditsInfo? { get set }
    var persistenceProvider: PersistenceProvider? { get set }
    var schemeCredentialsProvider: LLMSchemeConversationCredentialsProvider? { get }
    var schemeConnectionUpdates: Set<String> { get set }

    /// 同一会话同时只允许一个 in-flight 生成, 注册的是 _sendMessage 的内层 Task,
    /// `cancelGeneration(conversationID:)` 找到这个 Task 调 cancel(),
    /// cancellation 沿 URLSession SSE 关闭传到服务端, 上游 OpenRouter 连接被关。
    var inflightTasks: [String: Task<Void, Error>] { get set }

    /// Conversation-level run state. 不等同于 message-level streaming:
    /// sendMessage 插入 user message 后变 true; resumeGeneration 清理尾部 error stub 后变 true。
    /// tool 执行、等待 approval、下一轮 LLM 请求之间都算 running。
    var runningConversationIDs: Set<String> { get set }

    /// Tool approval handler: tool 声明 `requiresApproval` 时, 执行前 raise 给客户端弹 UI 等决策。
    /// nil = 自动 approve (向后兼容)。客户端 closure 内部自己负责 UI、cancel 响应、跨会话持久化。
    var toolApprovalHandler: ToolApprovalHandler? { get set }

    /// 流式 chunk 写入 conversation.messages 的频率策略。默认 `.immediate`。
    /// 高频流式时把这个换成 `.throttled(0.033)` 可以把 UI 重渲染压到 ~30Hz, 降低 chat view body
    /// 的 evaluate 频率。详见 `StreamPublishStrategy` 文档。
    var streamPublishStrategy: StreamPublishStrategy { get }

    /// Computed property for backward compatibility
    var credits: Double { get }

    func handlePurchase(verificationResult: VerificationResult<Transaction>) async throws

    func createConversation<Metadata: Codable & Equatable & Sendable>(
        id: String,
        type: Conversation.ConversationTpye,
        model: SupportedModel,
        agentConfig: AgentConfig,
        appendingPrompt: String?,
        messages: [ChatMessage],
        stream: Bool,
        metadata: Metadata,
        context invocationContext: (any ChatInvocationContext)?,
        replyTransformer: ((_ assistantMessage: ChatMessage) async throws -> ChatMessage)?
    ) async throws

    func sendMessage<Metadata: Codable & Equatable & Sendable>(
        to conversationID: String,
        model: SupportedModel,
        message: ChatMessage,
        stream: Bool,
        metadata: Metadata,
        context invocationContext: (any ChatInvocationContext)?,
        replyTransformer: ((_ assistantMessage: ChatMessage) async throws -> ChatMessage)?
    ) async throws

    func regenerateMessage<Metadata: Codable & Equatable & Sendable>(
        in conversationID: String,
        fromMessageID: String,
        model: SupportedModel,
        stream: Bool,
        metadata: Metadata,
        context invocationContext: (any ChatInvocationContext)?,
        replyTransformer: ((_ assistantMessage: ChatMessage) async throws -> ChatMessage)?
    ) async throws

    func resumeGeneration<Metadata: Codable & Equatable & Sendable>(
        in conversationID: String,
        model: SupportedModel,
        stream: Bool,
        metadata: Metadata,
        context invocationContext: (any ChatInvocationContext)?,
        replyTransformer: ((_ assistantMessage: ChatMessage) async throws -> ChatMessage)?
    ) async throws

    func temporaryChat(
        model: SupportedModel,
        messages: [ChatMessage],
        stream: Bool,
        onUpdate: @escaping @Sendable (_ message: ChatMessage) async throws -> Void,
        onFirstReply: @escaping @Sendable (_ message: ChatMessage) async throws -> Void,
    ) async throws -> ChatMessage

    func refreshConversations() async
}
struct ConversationNotReadyError: Error {}
struct ConversationNotFoundError: Error {}
struct ChatMessageNotFoundError: Error {}

/// CancellationError 是 Swift Task cancel 的标准抛出, URLError(.cancelled) 是 URLSession
/// 在被 cancel 时抛的 (异步 stream API 不一定包成 CancellationError)。两者都是用户主动
/// 取消的语义, 应该一视同仁吞掉。
/// 提到 internal 让 LLMState / LLMStateObject 的 public 方法也能在最外层 catch 兜底,
/// 即便 _xxx 内部 cancel 路径有遗漏, 调用方也不会拿到 CancellationError。
internal func isUserCancellationError(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    return false
}

/// 启发式识别上游返回的"上下文超限"错误。各 provider 错误格式不同, 但 message 里通常
/// 含 "context_length" / "maximum context" / "exceed ... token" 之类关键词。
/// 命中后 LLMKit 会自动调 compact + 重试一次, 见 `_runAgentLoop` catch 块。
/// **可能有假阳性** (其它带 "exceed" / "token" 的错误也会触发 compact), 假阳性的代价是
/// 一次无谓的 compact 调用, 不会丢数据。
internal func isContextOverflowError(_ error: Error) -> Bool {
    let message = error.localizedDescription.lowercased()
    if message.contains("context_length") { return true }
    if message.contains("context length") { return true }
    if message.contains("maximum context") { return true }
    if message.contains("context window") { return true }
    if message.contains("too many tokens") { return true }
    if message.contains("exceed") && message.contains("token") { return true }
    if message.contains("exceed") && message.contains("context") { return true }
    return false
}
