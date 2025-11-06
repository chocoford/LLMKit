//
//  AppStoreAuthProvider.swift
//  LLMKit
//
//  Created by Chocoford on 9/12/25.
//

import Foundation
import LLMCore
#if canImport(StoreKit)
import StoreKit
import Logging

public struct AppStoreAuthProvider: LLMAuthProvider {
    private let logger = Logger(label: "AppStoreAuthProvider")
    
    public let networking: LLMNetworking
    private let bundleID: String
    private let ascAppID: Int64?

    public init(
        networking: LLMNetworking,
        bundleID: String,
        ascAppID: Int64?
    ) {
        self.networking = networking
        self.bundleID = bundleID
        self.ascAppID = ascAppID
    }

    public func restoreAuth(productIDs: [String]) async throws -> String {
        listenTrasacionsUpdates(productIDs: productIDs)
        do {
            /// Asynchronously advances to the next element and returns it, or ends the sequence if there is no next element.
            /// 会一次性把所有的 transaction 都遍历完
            for await result in Transaction.currentEntitlements {
                if case .verified(let transaction) = result,
                   productIDs.contains(transaction.productID) {
                    let productID = transaction.productID
                    logger.info("Found existing entitlement for product: \(productID), originalID: \(transaction.originalID)")
                    
                    return try await restoreAuth(productID: productID, result: result)
                }
            }
            
            return try await AnonAuthProvider(networking: self.networking).anonAuth(bundleID: bundleID)
        } catch {
            logger.error("Restore auth error: \(error.localizedDescription)")
            throw error
        }
    }
    
    public func restoreAuth(groupID: String) async throws -> String {
        do {
            /// Asynchronously advances to the next element and returns it, or ends the sequence if there is no next element.
            /// 会一次性把所有的 transaction 都遍历完
            for await result in Transaction.currentEntitlements {
                if case .verified(let transaction) = result,
                   transaction.subscriptionGroupID == groupID {
                    let productID = transaction.productID
                    logger.info("Found existing entitlement for product: \(productID), originalID: \(transaction.originalID)")
                    return try await restoreAuth(
                        productID: productID,
                        result: result
                    )
                }
            }
            
            return try await AnonAuthProvider(networking: self.networking).anonAuth(bundleID: bundleID)
        } catch {
            logger.error("Restore auth error: \(error.localizedDescription)")
            throw error
        }
    }
    
    private func restoreAuth(
        productID: String,
        result: VerificationResult<Transaction>
    ) async throws -> String {
        struct RestoreResponse: Codable { let token: String }
        let req = IAPAuthRequest(
            jws: result.jwsRepresentation,
            bundleID: bundleID,
            ascAppID: ascAppID
        )
        let data: RestoreResponse = try await networking.post("/auth/iap", body: req)
        
        return data.token
    }

    public func handlePurchase(transactionJWS: String) async throws -> CreditAddResponse {
        let req = CreditAddRequest(
            transactionSignedData: transactionJWS,
            bundleID: bundleID,
            ascAppID: ascAppID
        )
        
        let data: CreditAddResponse = try await networking.post("/credits/add", body: req)
        return data
    }
    
    public func listenTrasacionsUpdates(productIDs: [String]) {
        Task.detached {
            // 2. 监听新购买/续订
//            do {
                for await update in Transaction.updates {
                    if case .verified(let transaction) = update,
                       productIDs.contains(transaction.productID) {
                        // let productID = transaction.productID
                        
                        if #available(iOS 17.0, macOS 14.0, *) {
                            logger.info("""
                        Transaction update:
                        - id: \(transaction.id)
                        - originalID: \(transaction.originalID)
                        - productID: \(transaction.productID)
                        - purchaseDate: \(transaction.purchaseDate)
                        - expirationDate: \(String(describing: transaction.expirationDate))
                        - environment: \(String(describing: transaction.environment))
                        - ownershipType: \(String(describing: transaction.ownershipType))
                        - isUpgraded: \(transaction.isUpgraded)
                        - revocationDate: \(String(describing: transaction.revocationDate))
                        - revocationReason: \(String(describing: transaction.revocationReason))
                        - appAccountToken: \(transaction.appAccountToken?.uuidString ?? "nil")
                        """)
                        }

                        // 这里你可以触发 register / add credits
//                        struct RestoreResponse: Codable {
//                            let token: String
//                        }
//                        let originalID = String(transaction.originalID)
//                        
//                        let req = IAPAuthRequest(
//                            originalTransactionID: originalID,
//                            bundleID: bundleID,
//                            ascAppID: ascAppID
//                        )
//                        let data: RestoreResponse = try await networking.post("/auth/iap", body: req)
//                        
                    }
                }
//            } catch {
//                logger.error("Restore auth error: \(error.localizedDescription)")
//            }
        }
    }
}

public struct AppStoreAuthProviderBuilder: LLMAuthProviderBuilder {
    var bundleID: String
    var ascAppID: Int64?
    
    public func callAsFunction(_ networking: LLMNetworking) -> any LLMAuthProvider {
        AppStoreAuthProvider(
            networking: networking,
            bundleID: bundleID,
            ascAppID: ascAppID
        )
    }
}

extension LLMAuthProviderBuilder where Self == AppStoreAuthProviderBuilder {
    public static func appStore(
        bundleID: String,
        ascAppID: Int64
    ) -> AppStoreAuthProviderBuilder {
        AppStoreAuthProviderBuilder(bundleID: bundleID, ascAppID: ascAppID)
    }
    
    public static func xcode(
        bundleID: String,
    ) -> AppStoreAuthProviderBuilder {
        AppStoreAuthProviderBuilder(bundleID: bundleID, ascAppID: nil)
    }
}

#endif // canImport(StoreKit)

