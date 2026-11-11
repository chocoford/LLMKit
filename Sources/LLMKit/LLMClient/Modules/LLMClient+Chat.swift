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
        let credentials = isDirectBYOK ? nil : try await inferenceCredentials(for: model, agentID: agentID)
        let preparedMessages = try await prepareUploadFiles(for: (
            system == nil ? [] : [
                .init(role: .system, content: system!),
            ]
        ) + [
            .init(role: .user, content: text)
        ])

        if let directClient { return try await directClient.chat(model: model, messages: preparedMessages, agentID: agentID, tools: tools) }
        let response: APIResponse<ChatMessageContent> = try await networking.postInference(
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
        return response.classifyingUsage(purpose: "chat", model: model, billingSource: credentials == nil ? .platform : .byok)
    }

    public func chat<Metadata: Codable & Equatable & Sendable>(
        model: SupportedModel,
        messages: [ChatMessageContent],
        metadata: Metadata? = EmptyMetadata(),
        agentID: String? = nil,
        tools: [ToolSchema]? = nil
    ) async throws -> APIResponse<ChatMessageContent> {
        let credentials = isDirectBYOK ? nil : try await inferenceCredentials(for: model, agentID: agentID)
        let preparedMessages = try await prepareUploadFiles(for: messages)

        if let directClient { return try await directClient.chat(model: model, messages: preparedMessages, agentID: agentID, tools: tools) }
        let response: APIResponse<ChatMessageContent> = try await networking.postInference(
            "/chat",
            body: ChatRequest(model: model, messages: preparedMessages, metadata: metadata, agentID: agentID, tools: tools),
            credentials: credentials
        )
        return response.classifyingUsage(purpose: "chat", model: model, billingSource: credentials == nil ? .platform : .byok)
    }

    public func streamChat<Metadata: Codable & Equatable & Sendable>(
        model: SupportedModel,
        system: String? = nil,
        text: String,
        metadata: Metadata? = EmptyMetadata(),
        agentID: String? = nil,
        tools: [ToolSchema]? = nil
    ) async throws -> AsyncThrowingStream<StreamChatResponse, Error> {
        let credentials = isDirectBYOK ? nil : try await inferenceCredentials(for: model, agentID: agentID)
        let preparedMessages = try await prepareUploadFiles(for: (
            system == nil ? [] : [
                .init(role: .system, content: system!),
            ]
        ) + [
            .init(role: .user, content: text)
        ])

        if let directClient { return try await directClient.streamChat(model: model, messages: preparedMessages, agentID: agentID, tools: tools) }
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
        let credentials = isDirectBYOK ? nil : try await inferenceCredentials(for: model, agentID: agentID)
        let preparedMessages = try await prepareUploadFiles(for: messages)

        if let directClient { return try await directClient.streamChat(model: model, messages: preparedMessages, agentID: agentID, tools: tools) }
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
        text: String,
        purpose: String = "title"
    ) async throws -> APIResponse<ChatMessageContent> {
        if let directClient {
            let result = try await directClient.chat(
                model: directClient.auxiliaryModel(fallback: preferredModel),
                messages: [.init(role: .system, content: system), .init(role: .user, content: text)],
                agentID: nil, tools: nil, includeBasePrompt: false
            )
            return result.classifyingUsage(purpose: purpose, model: preferredModel, billingSource: .byok)
        }
        let scoped = LLMSchemeScope.provider(for: self)
        let preferredModel = scoped?.auxiliaryModel(fallback: preferredModel) ?? preferredModel
        let credentials = try await inferenceCredentials(for: preferredModel)
        let model = credentials.map { credentials in
            credentials.configuration.options.auxiliaryModel.map(SupportedModel.init(rawValue:)) ?? preferredModel
        } ?? platformModel
        let messages = [ChatMessageContent(role: .system, content: system), .init(role: .user, content: text)]
        let result: APIResponse<ChatMessageContent> = try await networking.postInference(
            "/chat", body: ChatRequest<EmptyMetadata>(model: model, messages: messages), credentials: try credentials?.withoutHostedSearch()
        )
        return result.classifyingUsage(purpose: purpose, model: model, billingSource: credentials == nil ? .platform : .byok)
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

extension APIResponse where T == ChatMessageContent {
    func classifyingUsage(purpose: String, model: SupportedModel, billingSource: LLMAccessBillingSource) -> Self {
        var response = self
        guard var message = response.data else { return response }
        var records = message.inferenceUsage ?? []
        if records.isEmpty {
            records = [.init(responseID: message.id, modelID: model.rawValue,
                billingSource: billingSource, tokens: usage, isComplete: true)]
        }
        for index in records.indices {
            records[index].purpose = purpose
            records[index].billingSource = records[index].billingSource ?? billingSource
            if records[index].tokens == nil { records[index].tokens = usage }
            records[index].isComplete = true
        }
        message.inferenceUsage = records
        response.data = message
        return response
    }
}
