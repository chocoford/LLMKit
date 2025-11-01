//
//  LLMUploadPolicy.swift
//  LLMKit
//
//  Created by Chocoford on 10/5/25.
//

import Foundation

public struct LLMUploadPolicy: Sendable {
    public var autoUploadBase64: Bool
    public var maxFileSizeMB: Double
    public var allowedMimeTypes: [String]

    public init(
        autoUploadBase64: Bool = true,
        maxFileSizeMB: Double = 10,
        allowedMimeTypes: [String] = ["image/png", "image/jpeg", "image/webp"]
    ) {
        self.autoUploadBase64 = autoUploadBase64
        self.maxFileSizeMB = maxFileSizeMB
        self.allowedMimeTypes = allowedMimeTypes
    }
    
    
    public static var automatic: LLMUploadPolicy {
        LLMUploadPolicy(
            autoUploadBase64: true,
            maxFileSizeMB: 10,
            allowedMimeTypes: [
                "image/png",
                "image/jpeg",
                "image/webp"
            ]
        )
    }
}
