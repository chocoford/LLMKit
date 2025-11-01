//
//  LLMR2UploadProvider.swift
//  LLMKit
//
//  Created by Chocoford on 10/5/25.
//

import Foundation
import CryptoKit
import Logging
import LLMCore

public protocol LLMFileUploadProviderBuilder: Sendable {
    func callAsFunction(_ networking: LLMNetworking) -> LLMFileUploadProvider
}

public struct LLMR2UploadProviderBuilder: LLMFileUploadProviderBuilder {
    var endpoint: URL
    var bucket: String
    
    public func callAsFunction(_ networking: LLMNetworking) -> any LLMFileUploadProvider {
        LLMR2UploadProvider(
            endpoint: endpoint,
            bucket: bucket,
            networking: networking
        )
    }
    
}

extension LLMFileUploadProviderBuilder where Self == LLMR2UploadProviderBuilder {
    public static var `default`: LLMR2UploadProviderBuilder {
        Self.r2(
            endpoint: URL(string: "https://3d471aa1d195619b5b45f0009f0b72f9.r2.cloudflarestorage.com")!,
            bucket: "choco-llm"
        )
    }
    
    public static func r2(
        endpoint: URL,
        bucket: String,
    ) -> LLMR2UploadProviderBuilder {
        LLMR2UploadProviderBuilder(endpoint: endpoint, bucket: bucket)
    }
}

public struct LLMR2UploadProvider: LLMFileUploadProvider {
    private let logger = Logger(label: "LLMR2UploadProvider")
    
    var endpoint: URL
    var bucket: String
    var networking: LLMNetworking

    public init(endpoint: URL, bucket: String, networking: LLMNetworking) {
        self.endpoint = endpoint
        self.bucket = bucket
        self.networking = networking
    }

    public func uploadFile(
        data: Data,
        fileName: String,
        mimeType: String
    ) async throws -> URL {
        let uploadURL = endpoint.appendingPathComponent(bucket).appendingPathComponent(fileName)
        
        logger.info("Uploading file to \(uploadURL.absoluteString)")
        
        // 1️⃣ 计算 SHA256
        let sha256 = SHA256.hash(data: data)
        let sha256Hex = sha256.map { String(format: "%02x", $0) }.joined()

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.addValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.addValue(sha256Hex, forHTTPHeaderField: "x-amz-content-sha256")

        let sig: R2SignSignature = try await self.networking.post(
            "/upload/sign",
            body: SignUploadRequest(
                method: "PUT",
                url: uploadURL,
                headers: [
                    "content-type": mimeType,
                    "x-amz-content-sha256": sha256Hex,
                ],
                bodyHash: sha256Hex
            )
        )

        request.setValue(sig.authorization, forHTTPHeaderField: "Authorization")
        request.setValue(sig.amzDate, forHTTPHeaderField: "x-amz-date")
        
        // Perform request
        let (responseData, response) = try await URLSession.shared.data(for: request)
        
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "LLMUpload", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid response type"
            ])
        }
        
        guard (200..<300).contains(http.statusCode) else {
            // Try to decode AWS-style XML error
            let xml = String(data: responseData, encoding: .utf8) ?? "(empty)"
            var message = "Upload failed (\(http.statusCode))"
            
            if let code = xml.capture(between: "<Code>", and: "</Code>"),
               let msg = xml.capture(between: "<Message>", and: "</Message>") {
                message += " — \(code): \(msg)"
            }
            
            // 🪵 Log the full context
            logger.error(
                """
                ❌ Upload failed
                URL: \(uploadURL.absoluteString)
                Status: \(http.statusCode)
                Response: \(xml)
                """
            )
            
            throw NSError(domain: "LLMUpload", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }
        
        logger.info("✅ Upload successful: \(uploadURL.absoluteString)")

        let publicAccessURL = URL(string: "https://pub-69592f573e804630b2230980761f6dc7.r2.dev")!.appendingPathComponent(uploadURL.lastPathComponent, conformingTo: .url)
        
        return publicAccessURL
    }
}


// 小工具函数（轻量解析 XML）
private extension String {
    func capture(between start: String, and end: String) -> String? {
        guard let r1 = range(of: start),
              let r2 = range(of: end, range: r1.upperBound..<endIndex)
        else { return nil }
        return String(self[r1.upperBound..<r2.lowerBound])
    }
}
