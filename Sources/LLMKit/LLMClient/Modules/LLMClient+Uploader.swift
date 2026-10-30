//
//  File.swift
//  LLMKit
//
//  Created by Chocoford on 10/5/25.
//

import Foundation
import LLMCore

extension LLMClient {
    func prepareUploadFiles(for message: ChatMessageContent) async throws -> ChatMessageContent {
        var message = message
        guard let files = message.files, !files.isEmpty else { return message }

        // 决定走"上传"还是走"inline base64"。两条路径是互斥的:
        // - 有 uploader + autoUploadBase64 policy → 一律转远程 URL (节省 token, 持久化)
        // - 没配 → 本地内容必须 inline 成 base64 走 vision 通道 (file URL 上游拿不到, 必须本地化)
        let canUpload = !isDirectBYOK && uploader != nil && uploadPolicy?.autoUploadBase64 == true

        // 第 1 遍: 把每个 file 归一成 (bytes, mime, index) — 不论它来自 file:// URL 还是 base64。
        // 远程 https URL 跳过, 它本来就能直接发给上游。
        struct Pending: Sendable {
            let index: Int
            let data: Data
            let mime: String
        }
        var pending: [Pending] = []

        // 同时收集 inline fallback (没 uploader 时, file:// 直接转 data URI, 不进 TaskGroup)
        var inlineUpdates: [(Int, ChatMessageContent.File)] = []

        for (i, file) in files.enumerated() {
            switch file {
            case .image(let url) where url.isFileURL:
                guard let data = try? Data(contentsOf: url) else {
                    throw NSError(
                        domain: "LLMKit.FileUpload",
                        code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey: "Local file is not readable: \(url.path)"
                        ]
                    )
                }
                let mime = Self.inferMimeType(from: url)
                if canUpload {
                    pending.append(Pending(index: i, data: data, mime: mime))
                } else {
                    let dataURI = "data:\(mime);base64,\(data.base64EncodedString())"
                    inlineUpdates.append((i, .base64EncodedImage(dataURI)))
                }
            case .base64EncodedImage(let string):
                guard canUpload else { continue }  // 没 uploader 时 base64 保持不变
                let base64Content = string.components(separatedBy: ",").last ?? string
                let mime = string.components(separatedBy: ";").first?.components(separatedBy: ":").last ?? "image/png"
                guard let data = Data(base64Encoded: base64Content) else { continue }
                pending.append(Pending(index: i, data: data, mime: mime))
            case .image:
                // 远程 URL — 上游能直接拉, 不动
                continue
            }
        }

        // 第 2 遍: 应用 inline fallback (同步)
        var newFiles = files
        for (i, f) in inlineUpdates {
            newFiles[i] = f
        }

        // 第 3 遍: 并发上传 pending 的 bytes, 替换为远程 .image(URL)
        if let uploader = uploader, !pending.isEmpty {
            let uploaded: [(Int, ChatMessageContent.File)] = try await withThrowingTaskGroup { taskGroup in
                for p in pending {
                    taskGroup.addTask {
                        let fileName = UUID().uuidString + Self.fileExtension(for: p.mime)
                        let url = try await uploader.uploadFile(
                            data: p.data,
                            fileName: fileName,
                            mimeType: p.mime
                        )
                        let result: (Int, ChatMessageContent.File) = (p.index, .image(url))
                        return result
                    }
                }
                var results: [(Int, ChatMessageContent.File)] = []
                for try await result in taskGroup {
                    results.append(result)
                }
                return results
            }
            for (i, f) in uploaded {
                newFiles[i] = f
            }
        }

        message.files = newFiles
        return message
    }

    func prepareUploadFiles(for messages: [ChatMessageContent]) async throws -> [ChatMessageContent] {
        var messages = messages
        for index in messages.indices {
            messages[index] = try await prepareUploadFiles(for: messages[index])
        }
        return messages
    }
    
    func prepareUploadFiles(for message: ChatMessage) async throws -> ChatMessage {
        switch message {
            case .content(let content):
                return .content(try await prepareUploadFiles(for: content))
            default:
                return message
        }
    }
    
    func prepareUploadFiles(for conversation: Conversation) async throws -> Conversation {
        var conversation = conversation
        for i in conversation.messages.contentMessages.indices {
            let message = try await prepareUploadFiles(
                for: conversation.messages.contentMessages[i]
            )
            conversation.messages.contentMessages[i] = message
        }
        return conversation
    }

    func prepareUploadFilesForActiveContext(for conversation: Conversation) async throws -> Conversation {
        var conversation = conversation
        let preparedContextMessages = try await prepareUploadFiles(for: conversation.messages.contextMessages)
        var contextIndex = preparedContextMessages.startIndex

        for messageIndex in conversation.messages.indices {
            guard contextIndex < preparedContextMessages.endIndex else { break }
            guard case .content(let content) = conversation.messages[messageIndex],
                  !content.isCompactedOut else {
                continue
            }

            conversation.messages[messageIndex] = .content(preparedContextMessages[contextIndex])
            contextIndex = preparedContextMessages.index(after: contextIndex)
        }

        return conversation
    }

    /// 按文件后缀推 mime type, 不识别的兜底成 image/png (跟现有 base64 解析的兜底一致)。
    private static func inferMimeType(from url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png":          return "image/png"
        case "jpg", "jpeg":  return "image/jpeg"
        case "webp":         return "image/webp"
        case "gif":          return "image/gif"
        case "heic":         return "image/heic"
        default:             return "image/png"
        }
    }

    /// 上传时的 fileName 后缀; mime 不识别就兜底 .png, 跟 inferMimeType 的兜底逻辑对齐。
    private static func fileExtension(for mime: String) -> String {
        switch mime.lowercased() {
        case "image/png":   return ".png"
        case "image/jpeg":  return ".jpg"
        case "image/webp":  return ".webp"
        case "image/gif":   return ".gif"
        case "image/heic":  return ".heic"
        default:            return ".png"
        }
    }
}
