//
//  File.swift
//  LLMKit
//
//  Created by Chocoford on 9/5/25.
//

import Foundation
import LLMCore
import OpenAI



extension LLMClient {
    public func chat(
        model: SupportedModel,
        system: String? = nil,
        text: String
    ) async throws -> APIResponse<ChatResponse> {
        try await networking.post(
            "/chat",
            body: ChatRequest(
                model: model,
                messages: (
                    system == nil ? [] : [
                        .init(role: .system, content: system!),
                    ]
                ) + [
                    .init(role: .user, content: text)
                ]
            )
        )
    }
    
    public func chat(
        model: SupportedModel,
        messages: [ChatMessageContent]
    ) async throws -> APIResponse<ChatResponse> {
        try await networking.post(
            "/chat",
            body: ChatRequest(model: model, messages: messages)
        )
    }
    
    public func streamChat(
        model: SupportedModel,
        system: String? = nil,
        text: String
    ) async throws -> AsyncThrowingStream<StreamChatResponse<ChatStreamResult>, Error> {
        try await networking.stream("/chat/stream", body: ChatRequest(model: model, messages: (
            system == nil ? [] : [
                .init(role: .system, content: system!),
            ]
        ) + [
            .init(role: .user, content: text)
        ]))
    }
    
    public func streamChat(
        model: SupportedModel,
        messages: [ChatMessageContent]
    ) async throws -> AsyncThrowingStream<StreamChatResponse<ChatStreamResult>, Error> {
        try await networking.stream("/chat/stream", body: ChatRequest(model: model, messages: messages))
    }
}
