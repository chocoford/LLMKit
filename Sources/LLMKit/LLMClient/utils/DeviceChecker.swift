//
//  DeviceChecker.swift
//  LLMKit
//
//  Created by Chocoford on 11/4/25.
//

import Foundation
#if canImport(DeviceCheck)
import DeviceCheck

func requestDeviceToken() async throws -> Data {
    let dc = DCDevice.current
    guard dc.isSupported else {
        throw NSError(domain: "LLMAuth", code: 400, userInfo: [NSLocalizedDescriptionKey: "DeviceCheck not supported"])
    }

    return try await withCheckedThrowingContinuation { continuation in
        dc.generateToken { data, error in
            if let data = data {
                continuation.resume(returning: data)
            } else {
                continuation.resume(
                    throwing: error ?? NSError(
                        domain: "LLMAuth",
                        code: 401
                    )
                )
            }
        }
    }
}
#endif // canImport(DeviceCheck)
