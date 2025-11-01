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
        guard let uploader = uploader,
              let policy = uploadPolicy,
              policy.autoUploadBase64 else {
            return message
        }
        
        let updateFlags: [(Int, ChatMessageContent.File)] = try await withThrowingTaskGroup { taskGroup in
            for (i, file) in (message.files ?? []).enumerated() {
                guard case .base64EncodedImage(let string) = file else {
                    continue
                }
                let base64Content = string.components(separatedBy: ",").last ?? string
                let mimeType = string.components(separatedBy: ";").first?.components(separatedBy: ":").last ?? "image/png"
                guard let data = Data(base64Encoded: base64Content) else { continue }
                
                taskGroup.addTask {
                    let fileName = UUID().uuidString + ".png"
                    
                    let url = try await uploader.uploadFile(
                        data: data,
                        fileName: fileName,
                        mimeType: mimeType
                    )
                    let result: (Int, ChatMessageContent.File) = (i, .image(url))
                    return result
                }
            }
            
            var results: [(Int, ChatMessageContent.File)] = []
            for try await result in taskGroup {
                results.append(result)
            }
            return results
        }
        
        for (index, file) in updateFlags {
            message.files?[index] = file
        }
        
        return message
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
}
