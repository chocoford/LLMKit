//
//  AuthProvider.swift
//  LLMKit
//
//  Created by Chocoford on 9/12/25.
//

import Foundation
import LLMCore

public protocol LLMAuthProvider: Sendable {
    var networking: LLMNetworking { get }
    
    /// 在应用启动时调用，执行一次恢复 / 刷新逻辑
    func restoreAuth(productIDs: [String]) async throws -> String
    func restoreAuth(groupID: String) async throws -> String

    /// 处理一次购买完成后的授权逻辑
    func handlePurchase(transactionJWS: String) async throws -> CreditAddResponse
}

public protocol LLMAuthProviderBuilder: Sendable {
    func callAsFunction(_ networking: LLMNetworking) -> any LLMAuthProvider
}

struct NoAuthProvider: LLMAuthProvider {
    let networking: LLMNetworking = .init()
    
    func restoreAuth(productIDs: [String]) async throws -> String {
        ""
    }
    
    func restoreAuth(groupID: String) async throws -> String {
        ""
    }
    
    func handlePurchase(transactionJWS: String) async throws -> CreditAddResponse {
        return .init(balance: 0)
    }
}
