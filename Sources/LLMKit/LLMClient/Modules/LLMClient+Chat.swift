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
        text: String
    ) async throws -> APIResponse<ChatResponse> {
        try await networking.post(
            "/chat",
            body: ChatRequest(
                model: model,
                messages: [
                    .init(role: .user, content: text)
                ]
            )
        )
    }
    
    public func chat(
        model: SupportedModel,
        messages: [ChatMessage]
    ) async throws -> AsyncThrowingStream<StreamChatResponse<ChatStreamResult>, Error> {
        try await networking.stream("/chat", body: ChatRequest(model: model, messages: messages))
    }

    public func nanoBanana(
        message: String
    ) async throws -> APIResponse<ChatResponse> {
        try await networking.post("/chat/banana", body: ChatRequest(
            model: .nanoBanana,
            systemPrompt: nil,
            userPrompt: message
        ))
    }
    
    public func nanoBanana(
        messages: [ChatMessage]
    ) async throws -> APIResponse<ChatResponse> {
        try await networking.post("/chat/banana", body: ChatRequest(
            model: .nanoBanana,
            messages: messages
        ))
    }
}
