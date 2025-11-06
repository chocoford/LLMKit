//
//  AnonAuthProvider.swift
//  LLMKit
//
//  Created by Chocoford on 11/4/25.
//

import Foundation
import LLMCore
import Logging

struct AnonAuthProvider {
    public var networking: LLMNetworking
    private let logger = Logger(label: "AnonAuthProvider")
    
    func anonAuth(bundleID: String) async throws -> String {
        let token = try await requestDeviceToken()
  
        let anonID = AnonIdentityManager.loadOrCreateAnonID(for: bundleID)

        let body = AnonAuthRequest(
            platform: .apple,
            bundleID: bundleID,
            anonID: anonID,
            deviceToken: token.base64EncodedString()
        )
        
        let response: AuthResponse = try await networking.post(
            "/auth/anon",
            body: body
        )
        
        return response.token
    }
}


struct AnonIdentityManager {
    static func loadOrCreateAnonID(for bundleID: String) -> String {
        let keychainService = "com.chocoford.llmkit.\(bundleID)"
        let anonKey = "anon.uuid"

        // Try to read existing
        if let existing = readKeychain(service: keychainService, key: anonKey) {
            return existing
        } else {
            let newID = UUID().uuidString
            saveKeychain(value: newID, service: keychainService, key: anonKey)
            return newID
        }
    }

    private static func readKeychain(service: String, key: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func saveKeychain(value: String, service: String, key: String) {
        let data = value.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        SecItemAdd(query as CFDictionary, nil)
    }
}
