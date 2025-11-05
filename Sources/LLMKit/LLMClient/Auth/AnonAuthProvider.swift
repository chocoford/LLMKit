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
    
    func anonAuth() async throws -> String {
        let token = try await requestDeviceToken()

        let body = [
            "deviceToken": token.base64EncodedString()
        ]

        let response: AuthResponse = try await networking.post(
            "/auth/anon",
            body: body
        )
        
        return response.token
    }
}
