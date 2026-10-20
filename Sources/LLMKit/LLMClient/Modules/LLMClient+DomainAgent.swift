//
//  LLMClient+DomainAgent.swift
//  LLMKit
//
//  与服务端"领域 Agent"配置端点对接。
//
//  服务端把每个 agent (例如 "excalidraw-canvas") 的核心 IP (systemPrompt) 留在自己手上,
//  只下发客户端必须的字段 (modelProfiles + legacy fallback models)。客户端跑 ReAct loop 时, 调
//  /chat 带上 agentID, 服务端会自动注入 prompt。
//
//  典型用法:
//
//  ```swift
//  let config = try await client.getDomainAgentConfig(agentID: "excalidraw-canvas")
//  // 新客户端优先用 config.modelProfiles; 老客户端可继续用 config.defaultModel。
//  // 创建 AgentConfig(.. agentID: "excalidraw-canvas")
//  // 创建 conversation, 后续 chat 自动走服务端 prompt 注入
//  ```
//

import Foundation
import LLMCore

extension LLMClient {
    /// 拉取一个 domain agent 的客户端可见配置。
    /// 平台计费优先使用 `modelProfiles`; `defaultModel` / `allowedModels` 仅作为老客户端 fallback。
    /// BYOK 的模型选择来自用户连接配置, 不应被这些平台菜单或套餐档位限制。
    /// 这是公共只读配置端点, 不要求 auth, 不触发 LLM 调用, 不扣 credits。
    public func getDomainAgentConfig(agentID: String) async throws -> DomainAgentConfigResponse {
        try await networking.get("/domain-agents/config/\(agentID)")
    }
}
