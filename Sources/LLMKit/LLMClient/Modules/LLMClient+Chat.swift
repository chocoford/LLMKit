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
    public func chat<Metadata: Codable & Equatable & Sendable>(
        model: SupportedModel,
        system: String? = nil,
        text: String,
        metadata: Metadata? = EmptyMetadata(),
        agentID: String? = nil,
        tools: [ToolSchema]? = nil
    ) async throws -> APIResponse<ChatMessageContent> {
        let preparedMessages = try await prepareUploadFiles(for: (
            system == nil ? [] : [
                .init(role: .system, content: system!),
            ]
        ) + [
            .init(role: .user, content: text)
        ])

        let credentials = try await inferenceCredentials(for: model)
        return try await networking.postInference(
            "/chat",
            body: ChatRequest(
                model: model,
                messages: preparedMessages,
                metadata: metadata,
                agentID: agentID,
                tools: tools
            ),
            credentials: credentials
        )
    }

    public func chat<Metadata: Codable & Equatable & Sendable>(
        model: SupportedModel,
        messages: [ChatMessageContent],
        metadata: Metadata? = EmptyMetadata(),
        agentID: String? = nil,
        tools: [ToolSchema]? = nil
    ) async throws -> APIResponse<ChatMessageContent> {
        let preparedMessages = try await prepareUploadFiles(for: messages)

        let credentials = try await inferenceCredentials(for: model)
        return try await networking.postInference(
            "/chat",
            body: ChatRequest(model: model, messages: preparedMessages, metadata: metadata, agentID: agentID, tools: tools),
            credentials: credentials
        )
    }

    public func streamChat<Metadata: Codable & Equatable & Sendable>(
        model: SupportedModel,
        system: String? = nil,
        text: String,
        metadata: Metadata? = EmptyMetadata(),
        agentID: String? = nil,
        tools: [ToolSchema]? = nil
    ) async throws -> AsyncThrowingStream<StreamChatResponse, Error> {
        let preparedMessages = try await prepareUploadFiles(for: (
            system == nil ? [] : [
                .init(role: .system, content: system!),
            ]
        ) + [
            .init(role: .user, content: text)
        ])

        let credentials = try await inferenceCredentials(for: model)
        return try await networking.streamInference("/chat/stream", body: ChatRequest(
            model: model,
            messages: preparedMessages,
            metadata: metadata,
            agentID: agentID,
            tools: tools
        ), credentials: credentials)
    }

    public func streamChat<Metadata: Codable & Equatable & Sendable>(
        model: SupportedModel,
        messages: [ChatMessageContent],
        metadata: Metadata? = EmptyMetadata(),
        agentID: String? = nil,
        tools: [ToolSchema]? = nil
    ) async throws -> AsyncThrowingStream<StreamChatResponse, Error> {
        let preparedMessages = try await prepareUploadFiles(for: messages)

        let credentials = try await inferenceCredentials(for: model)
        return try await networking.streamInference(
            "/chat/stream",
            body: ChatRequest(model: model, messages: preparedMessages, metadata: metadata, agentID: agentID, tools: tools),
            credentials: credentials
        )
    }
    
    /// Titles use the conversation's model in BYOK mode, not a hard-coded OpenAI model.
    func auxiliaryChat(
        preferredModel: SupportedModel,
        platformModel: SupportedModel,
        system: String,
        text: String
    ) async throws -> APIResponse<ChatMessageContent> {
        let credentials = try await inferenceCredentials(for: preferredModel)
        let model = credentials.map { credentials in
            credentials.configuration.options.auxiliaryModel.map(SupportedModel.init(rawValue:)) ?? preferredModel
        } ?? platformModel
        let messages = [ChatMessageContent(role: .system, content: system), .init(role: .user, content: text)]
        return try await networking.postInference(
            "/chat", body: ChatRequest<EmptyMetadata>(model: model, messages: messages), credentials: credentials
        )
    }

//    public func streamChat(
//        model: SupportedModel,
//        messages: [ChatMessageContent],
//        onUpdateMessage: (@escaping (ChatMessageContent) -> Void),
//        onSettlement: (@escaping (ChatResponse) -> Void
//    ) async throws {
//        for try await result: StreamChatResponse<ChatStreamResult> in try await networking.stream("/chat/stream", body: ChatRequest(model: model, messages: messages)) {
//            switch result {
//                case .message(let message):
//                    
//                case .settlement(let settlement):
//                    
//            }
//        }
//    }
}
