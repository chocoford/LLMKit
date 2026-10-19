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

/// Select credentials for each model request. Return nil only for explicitly selected platform billing.
public typealias LLMBYOKModelCredentialsProvider = @Sendable (SupportedModel) async throws -> LLMBYOKCredentials?

public final class LLMClient: Sendable {
    private let authManager: LLMAuthManager
    internal let networking: LLMNetworking
    internal let uploader: (any LLMFileUploadProvider)?
    internal let uploadPolicy: LLMUploadPolicy?
    internal let byokCredentialsProvider: LLMBYOKCredentialsProvider?
    internal let byokModelCredentialsProvider: LLMBYOKModelCredentialsProvider?
    
    private let logger = Logger(label: "LLMClient")
    
    public init(
        authProvider: LLMAuthProvider,
        uploadProvider: (any LLMFileUploadProvider)? = nil,
        uploadPolicy: LLMUploadPolicy? = nil,
        byokCredentialsProvider: LLMBYOKCredentialsProvider? = nil,
        byokModelCredentialsProvider: LLMBYOKModelCredentialsProvider? = nil
    ) {
        self.networking = LLMNetworking()
        let authStateChangedPublisher = PassthroughSubject<Bool, Never>()
        self.authManager = LLMAuthManager(provider: authProvider) {
            authStateChangedPublisher.send($0)
        }
        self.authStateChangedPublisher = authStateChangedPublisher
        self.uploader = uploadProvider
        self.uploadPolicy = uploadPolicy
        self.byokCredentialsProvider = byokCredentialsProvider
        self.byokModelCredentialsProvider = byokModelCredentialsProvider
    }

    #if DEBUG
    public init(
        authProvider: LLMAuthProvider,
        uploadProvider: (any LLMFileUploadProvider)? = nil,
        uploadPolicy: LLMUploadPolicy? = nil,
        baseURL: URL,
        byokCredentialsProvider: LLMBYOKCredentialsProvider? = nil,
        byokModelCredentialsProvider: LLMBYOKModelCredentialsProvider? = nil
    ) {
        self.networking = LLMNetworking(baseURL: baseURL)
        let authStateChangedPublisher = PassthroughSubject<Bool, Never>()
        self.authManager = LLMAuthManager(provider: authProvider) {
            authStateChangedPublisher.send($0)
        }
        self.authStateChangedPublisher = authStateChangedPublisher
        self.uploader = uploadProvider
        self.uploadPolicy = uploadPolicy
        self.byokCredentialsProvider = byokCredentialsProvider
        self.byokModelCredentialsProvider = byokModelCredentialsProvider
    }
    #endif
    
    public init(
        authProvider: any LLMAuthProviderBuilder,
        uploadProvider: (any LLMFileUploadProviderBuilder)? = nil,
        uploadPolicy: LLMUploadPolicy? = nil,
        byokCredentialsProvider: LLMBYOKCredentialsProvider? = nil,
        byokModelCredentialsProvider: LLMBYOKModelCredentialsProvider? = nil
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
        self.byokCredentialsProvider = byokCredentialsProvider
        self.byokModelCredentialsProvider = byokModelCredentialsProvider
    }

    #if DEBUG
    public init(
        authProvider: any LLMAuthProviderBuilder,
        uploadProvider: (any LLMFileUploadProviderBuilder)? = nil,
        uploadPolicy: LLMUploadPolicy? = nil,
        baseURL: URL,
        byokCredentialsProvider: LLMBYOKCredentialsProvider? = nil,
        byokModelCredentialsProvider: LLMBYOKModelCredentialsProvider? = nil
    ) {
        self.networking = LLMNetworking(baseURL: baseURL)
        let authStateChangedPublisher = PassthroughSubject<Bool, Never>()
        self.authManager = LLMAuthManager(provider: authProvider(self.networking)) { isAuthenticated in
            DispatchQueue.main.async {
                authStateChangedPublisher.send(isAuthenticated)
            }
        }
        self.authStateChangedPublisher = authStateChangedPublisher
        self.uploader = uploadProvider?(self.networking)
        self.uploadPolicy = uploadPolicy
        self.byokCredentialsProvider = byokCredentialsProvider
        self.byokModelCredentialsProvider = byokModelCredentialsProvider
    }
    #endif
    
    init() {
        self.networking = LLMNetworking()
        let authStateChangedPublisher = PassthroughSubject<Bool, Never>()
        self.authManager = LLMAuthManager(provider: NoAuthProvider()) {
            authStateChangedPublisher.send($0)
        }
        self.authStateChangedPublisher = authStateChangedPublisher
        self.uploader = nil
        self.uploadPolicy = nil
        self.byokCredentialsProvider = nil
        self.byokModelCredentialsProvider = nil
    }
    
    internal let authStateChangedPublisher: PassthroughSubject<Bool, Never>
    
    /// Restore the client auth identity and refresh credits if authenticated.
    ///
    /// For App Store subscriptions, configure `subscriptionGroupID` on the auth provider first.
    /// This method is suitable for app launch / cold start. It should not be treated as a
    /// foreground polling hook.
    public func restore() async {
        await authManager.restore()

        if await authManager.isAuthenticated {
            do {
                _ = try await self.getCredits()
            } catch {
                logger.error("Failed to fetch credits after restore: \(error)")
            }
        }
    }

    @available(*, deprecated, message: "Configure subscriptionGroupID in the auth provider and call restore() instead.")
    public func restore(productIDs: [String]) async {
        fatalError("restore(productIDs:) is deprecated. Configure subscriptionGroupID in the auth provider and call restore() instead.")
    }
    
    @available(*, deprecated, message: "Configure subscriptionGroupID in the auth provider and call restore() instead.")
    public func restore(groupID: String) async {
        fatalError("restore(groupID:) is deprecated. Configure subscriptionGroupID in the auth provider and call restore() instead.")
    }
    
    internal let creditsUpdatePublisher = PassthroughSubject<CreditsInfo, Never>()

    /// Read the current authenticated user's basic server-side information.
    ///
    /// This is a plain `GET /auth` snapshot. It returns identity, app, credits, and the latest
    /// server-side subscription state if one exists. It does not touch StoreKit and does not run
    /// restore / transaction-history reconciliation.
    public func getUserInfo() async throws -> AuthUserInfo {
        try await self.networking.get("/auth")
    }
    
    // MARK: - Private Request Helper
    
    private func withUsageMiddleware<T: Codable>(_ response: APIResponse<T>) -> APIResponse<T> {
        if let remainsCredit = response.credits?.remains {
            // Create a minimal CreditsInfo with only balance
            let creditsInfo = CreditsInfo(
                balance: remainsCredit,
                periodicCredits: nil,
                purchasedCredits: 0
            )
            DispatchQueue.main.async {
                self.creditsUpdatePublisher.send(creditsInfo)
            }
        }

        return response
    }
    
    public func ask(
        prompt: String,
        model: SupportedModel = .gpt4oMini
    ) async throws -> APIResponse<ChatMessageContent> {
        let body = AskRequest<EmptyMetadata>(prompt: prompt, model: model)
        let credentials = try await inferenceCredentials(for: model)
        let response: APIResponse<ChatMessageContent> = try await self.networking.postInference(
            "/chat/ask", body: body, credentials: credentials
        )

        return withUsageMiddleware(response)
    }

    func inferenceCredentials(for model: SupportedModel) async throws -> LLMBYOKCredentials? {
        // A model-specific callback takes precedence, including an explicit nil (platform mode).
        if let byokModelCredentialsProvider { return try await byokModelCredentialsProvider(model) }
        return try await byokCredentialsProvider?()
    }
    
    // MARK: - Credits
    /// Get LLM credits information, including total balance, periodic credits, and purchased credits.
    @discardableResult
    public func getCredits() async throws -> CreditsInfo {
        let response: CreditsInfo = try await self.networking.get("/credits")
        // 更新全局状态
        DispatchQueue.main.async {
            self.creditsUpdatePublisher.send(response)
        }
        return response
    }

    /// Read the current subscription state from LLMServer.
    ///
    /// This is a lightweight server-side snapshot read. It does not touch StoreKit, does not
    /// scan local transactions, and does not reconcile Apple state. Use it when the app needs to
    /// display or diagnose what the server currently believes about the subscription.
    ///
    /// For App Store clients, this should not be used as the primary source for local entitlement
    /// or app plan decisions. Prefer StoreKit (`Transaction.currentEntitlements`,
    /// `Transaction.updates`, `Product.purchase()`, and explicit restore flows) for the app's local
    /// subscription UI/state, and use LLMServer primarily for credits, auth, and server-side
    /// diagnostics.
    ///
    /// Throws if LLMServer has no subscription state for the authenticated identity.
    public func getSubscriptionState() async throws -> SubscriptionStateInfo {
        try await self.networking.get("/credits/subscription-state")
    }

    /// Reconcile App Store subscription identity/state with LLMServer, then return the server snapshot.
    ///
    /// This is a recovery / restore / reconciliation API, not a routine refresh API. For App Store
    /// providers it scans the configured `subscriptionGroupID` in StoreKit entitlements / history,
    /// submits the transaction JWS to `/auth/iap`, refreshes credits, and then reads
    /// `getSubscriptionState()`.
    ///
    /// Prefer using this for explicit restore flows, new devices, reinstall, account diagnostics, or
    /// when local StoreKit state and server state appear out of sync. Do not call it frequently from
    /// foreground/background transitions.
    @discardableResult
    public func syncSubscriptionState() async throws -> SubscriptionStateInfo {
        try await authManager.restoreThrowing()
        if await authManager.isAuthenticated {
            _ = try await getCredits()
        }
        return try await getSubscriptionState()
    }

    @discardableResult
    @available(*, deprecated, message: "Configure subscriptionGroupID in the auth provider and call syncSubscriptionState() instead.")
    public func syncSubscriptionState(groupID: String) async throws -> SubscriptionStateInfo {
        fatalError("syncSubscriptionState(groupID:) is deprecated. Configure subscriptionGroupID in the auth provider and call syncSubscriptionState() instead.")
    }

    /// Complete an App Store subscription purchase.
    ///
    /// Call this after `Product.purchase()` returns a verified subscription transaction. The JWS is
    /// sent to LLMServer for verification and identity/state upsert, then credits are refreshed.
    /// The caller should finish the StoreKit transaction only after this method succeeds.
    ///
    /// Do not use this as a routine `Transaction.updates` forwarding hook. StoreKit updates are
    /// best handled by the app for local UI/finish behavior, while long-term subscription lifecycle
    /// changes should come from App Store Server Notifications.
    @discardableResult
    public func completeSubscriptionPurchase(transactionSignedData: String) async throws -> CreditsInfo {
        try await authManager.subscriptionPurchaseCompleted(jws: transactionSignedData)
        return try await getCredits()
    }
    
    /// Get transaction history with pagination
    /// - Parameters:
    ///   - page: Page number (default: 1)
    ///   - pageSize: Number of transactions per page (default: 20)
    ///   - type: Optional filter by transaction type
    public func getTransactionHistory(
        page: Int = 1,
        pageSize: Int = 20,
        type: CreditsTransactionType? = nil
    ) async throws -> TransactionHistory {
        var queryParams: [String: String] = [
            "page": String(page),
            "pageSize": String(pageSize)
        ]
        if let type = type {
            queryParams["type"] = type.rawValue
        }

        let queryString = queryParams
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")

        let response: TransactionHistory = try await self.networking.get("/credits/transactions?\(queryString)")
        return response
    }
    
    @discardableResult
    public func addCredits(transactionSignedData: String) async throws -> CreditsInfo {
        let creditsInfo = try await self.authManager.purchaseCompleted(jws: transactionSignedData)

        // 更新全局状态
        DispatchQueue.main.async {
            self.creditsUpdatePublisher.send(creditsInfo)
        }
        return creditsInfo
    }
}
