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
    internal let uploader: (any LLMFileUploadProvider)?
    internal let uploadPolicy: LLMUploadPolicy?

    private let logger = Logger(label: "LLMClient")
    
    public init(
        authProvider: LLMAuthProvider,
        uploadProvider: (any LLMFileUploadProvider)? = nil,
        uploadPolicy: LLMUploadPolicy? = nil
    ) {
        self.networking = LLMNetworking()
        let authStateChangedPublisher = PassthroughSubject<Bool, Never>()
        self.authManager = LLMAuthManager(provider: authProvider) {
            authStateChangedPublisher.send($0)
        }
        self.authStateChangedPublisher = authStateChangedPublisher
        self.uploader = uploadProvider
        self.uploadPolicy = uploadPolicy
    }
    
    public init(
        authProvider: any LLMAuthProviderBuilder,
        uploadProvider: (any LLMFileUploadProviderBuilder)? = nil,
        uploadPolicy: LLMUploadPolicy? = nil
    ) {
        self.networking = LLMNetworking()
        let authStateChangedPublisher = PassthroughSubject<Bool, Never>()
        self.authManager = LLMAuthManager(provider: authProvider(self.networking)) { isAuthenticated in
            DispatchQueue.main.async {
                authStateChangedPublisher.send(isAuthenticated)
            }
        }
        self.authStateChangedPublisher = authStateChangedPublisher
        self.uploader = uploadProvider?(self.networking)
        self.uploadPolicy = uploadPolicy
    }
    
    init() {
        self.networking = LLMNetworking()
        let authStateChangedPublisher = PassthroughSubject<Bool, Never>()
        self.authManager = LLMAuthManager(provider: NoAuthProvider()) {
            authStateChangedPublisher.send($0)
        }
        self.authStateChangedPublisher = authStateChangedPublisher
        self.uploader = nil
        self.uploadPolicy = nil
    }
    
    internal let authStateChangedPublisher: PassthroughSubject<Bool, Never>
    
    // 应用启动时调用
    public func restore(productIDs: [String]) async {
        await authManager.restore(productIDs: productIDs)
        
        if await authManager.isAuthenticated {
            do {
                _ = try await self.getCredits()
            } catch {
                logger.error("Failed to fetch credits after restore: \(error)")
            }
        }
    }
    
    public func restore(groupID: String) async {
        await authManager.restore(groupID: groupID)
        
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
