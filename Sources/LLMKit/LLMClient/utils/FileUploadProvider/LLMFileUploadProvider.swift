//
//  LLMImageUploader.swift
//  LLMKit
//
//  Created by Chocoford on 10/4/25.
//

import SwiftUI

public protocol LLMFileUploadProvider: Sendable {
    /// 上传任意文件，返回可访问的 URL
    func uploadFile(
        data: Data,
        fileName: String,
        mimeType: String
    ) async throws -> URL
}

