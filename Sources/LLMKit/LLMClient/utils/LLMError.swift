//
//  LLMError.swift
//  LLMKit
//
//  Created by Chocoford
//
//  统一暴露给客户端调用方的语义化错误。LLMNetworking 拿到非-2xx 响应后,
//  会按 status code 映射成对应 case, 调用方 `catch LLMError.xxx` 即可,
//  不需要解析 NSError.domain / status code。
//

import Foundation
import LLMCore

public enum LLMError: LocalizedError, Sendable {
    /// 余额不足 (HTTP 402)。UI 提示用户充值。
    case insufficientCredits
    /// 未鉴权 / token 过期 (HTTP 401)。UI 引导重新登录。
    case unauthorized
    /// App/server access policy denied this operation. Not a credit-balance failure.
    case accessDenied(requirementIDs: [String])
    /// 请求被拒绝 (HTTP 403), 例如 agent 不允许该 model、配额受限等。
    /// reason 透传服务端 message 用于日志/排查, 不要直接 show 给用户。
    case forbidden(reason: String?)
    /// 限流 (HTTP 429)。
    case rateLimited
    /// 兜底: 5xx / 4xx 未识别。message 用于日志, UI 应展示通用文案。
    case server(statusCode: Int, message: String?)
    /// 本地解码失败。
    case decoding(underlying: Error)
    /// 网络层底层错误 (URLError 等)。
    case network(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .insufficientCredits:
            return "Insufficient credits"
        case .unauthorized:
            return "Unauthorized"
        case .accessDenied:
            return "Your current subscription does not grant access to this feature."
        case .forbidden(let reason):
            return reason.map { "Forbidden: \($0)" } ?? "Forbidden"
        case .rateLimited:
            return "Rate limited"
        case .server(let code, let message):
            return message.map { "Server error (\(code)): \($0)" } ?? "Server error (\(code))"
        case .decoding(let underlying):
            return "Decoding failed: \(underlying.localizedDescription)"
        case .network(let underlying):
            return "Network error: \(underlying.localizedDescription)"
        }
    }

    /// 把 HTTP status code + 可选 server reason 映射成具体 case。
    /// data 用来尝试解出 ErrorResponse.error.message; 解不出就 nil。
    static func fromHTTP(statusCode: Int, body: Data?) -> LLMError {
        if statusCode == 403, let body,
           let envelope = try? JSONDecoder().decode(LLMErrorEnvelope.self, from: body),
           let access = envelope.error.access, !access.allowed {
            return .accessDenied(requirementIDs: access.missingRequirementIDs.isEmpty ? access.requirementIDs : access.missingRequirementIDs)
        }
        let message: String? = body.flatMap { data in
            (try? JSONDecoder().decode(LLMErrorEnvelope.self, from: data))?.error.message
        }
        switch statusCode {
        case 401: return .unauthorized
        case 402: return .insufficientCredits
        case 403: return .forbidden(reason: message)
        case 429: return .rateLimited
        default:  return .server(statusCode: statusCode, message: message)
        }
    }
}

/// 与服务端 APIResponse / Vapor Abort 一致的错误信封。
/// 仅用于在客户端这一层解出 message, 不对外暴露。
private struct LLMErrorEnvelope: Decodable {
    struct ErrorBody: Decodable {
        let code: Int?
        let message: String
        let access: LLMAccessDecision?
    }
    let error: ErrorBody
}
