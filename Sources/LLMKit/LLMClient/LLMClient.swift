//
//  LLMClient.swift
//  LLMKit
//
//  Created by Chocoford on 9/5/25.
//

import Foundation
@preconcurrency import Combine
import Logging
import LLMCore

public final class LLMClient: Sendable {
    private let authManager: LLMAuthManager
    internal let networking: LLMNetworking

    private let logger = Logger(label: "LLMClient")
    
    public init(
        provider: LLMAuthProvider
    ) {
        self.networking = LLMNetworking()
        let authStateChangedPublisher = PassthroughSubject<Bool, Never>()
        self.authManager = LLMAuthManager(provider: provider) {
            authStateChangedPublisher.send($0)
        }
        self.authStateChangedPublisher = authStateChangedPublisher
    }
    
    public init(
        provider: any LLMAuthProviderBuilder
    ) {
        self.networking = LLMNetworking()
        let authStateChangedPublisher = PassthroughSubject<Bool, Never>()
        self.authManager = LLMAuthManager(provider: provider(self.networking)) { isAuthenticated in
            DispatchQueue.main.async {
                authStateChangedPublisher.send(isAuthenticated)
            }
        }
        self.authStateChangedPublisher = authStateChangedPublisher
    }
    
    init() {
        self.networking = LLMNetworking()
        let authStateChangedPublisher = PassthroughSubject<Bool, Never>()
        self.authManager = LLMAuthManager(provider: NoAuthProvider()) {
            authStateChangedPublisher.send($0)
        }
        self.authStateChangedPublisher = authStateChangedPublisher
    }
    
    internal let authStateChangedPublisher: PassthroughSubject<Bool, Never>
    
    // 应用启动时调用
    public func restore(productID: String) async {
        await authManager.restore(productID: productID)
        
        if await authManager.isAuthenticated {
            do {
                _ = try await self.getCredits()
            } catch {
                logger.error("Failed to fetch credits after restore: \(error)")
            }
        }
    }
    
    internal let creditsUpdatePublisher = PassthroughSubject<Double, Never>()
    
    // MARK: - Private Request Helper
    
    private func withUsageMiddleware<T: Codable>(_ response: APIResponse<T>) -> APIResponse<T> {
        if let remainsCredit = response.credits?.remains {
            // self.usageStreamContinuation.yield(usage)
            DispatchQueue.main.async {
                self.creditsUpdatePublisher.send(remainsCredit)
            }
        }
        
        return response
    }
    
    public func ask(
        systemPrompt: String? = nil,
        userPrompt: String,
        model: SupportedModel = .gpt4oMini
    ) async throws -> String {
        let body = AskRequest(systemPrompt: systemPrompt, userPrompt: userPrompt, model: model)
        let data: String = try await self.networking.post("/chat/ask", body: body)
        
//        let result = String(data: data, encoding: .utf8)
        return data
    }
    
    // MARK: - Credits
    @discardableResult
    public func getCredits() async throws -> Double {
        let response: CreditAddResponse = try await self.networking.get("/credits")
        print(response)
        let balance = response.balance
        // 更新全局状态
        DispatchQueue.main.async {
            self.creditsUpdatePublisher.send(balance)
        }
        return balance
    }
    
    @discardableResult
    public func addCredits(transactionSignedData: String) async throws -> Double {
        let balance = try await self.authManager.purchaseCompleted(jws: transactionSignedData)
        
        // 更新全局状态
        DispatchQueue.main.async {
            self.creditsUpdatePublisher.send(balance)
        }
        return balance
    }
}
