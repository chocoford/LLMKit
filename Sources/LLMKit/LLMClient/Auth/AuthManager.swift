//
//  AuthManager.swift
//  LLMKit
//
//  Created by Chocoford on 9/12/25.
//

import Foundation

public actor LLMAuthManager {
    private let provider: LLMAuthProvider

    private(set) var onAuthStateChanged: (Bool) -> Void

    var isAuthenticated: Bool {
        get async {
            await provider.networking.token != nil
        }
    }
    
    public init(provider: LLMAuthProvider, onAuthStateChanged: @escaping (Bool) -> Void) {
        self.provider = provider
        self.onAuthStateChanged = onAuthStateChanged
    }

    public func restore(productIDs: [String]) async {
        do {
            let token = try await provider.restoreAuth(productIDs: productIDs)
            await self.provider.networking.setToken(token)
            self.onAuthStateChanged(true)
        } catch {
            await self.provider.networking.setToken(nil)
            self.onAuthStateChanged(false)
        }
    }
    
    public func restore(groupID: String) async {
        do {
            let token = try await provider.restoreAuth(groupID: groupID)
            await self.provider.networking.setToken(token)
            self.onAuthStateChanged(true)
        } catch {
            await self.provider.networking.setToken(nil)
            self.onAuthStateChanged(false)
        }
    }
    
    /// Return the current balance after purchase
    public func purchaseCompleted(jws: String) async throws -> Double {
        let response = try await provider.handlePurchase(transactionJWS: jws)
        // self.token = response.token
        return response.balance
    }
}
