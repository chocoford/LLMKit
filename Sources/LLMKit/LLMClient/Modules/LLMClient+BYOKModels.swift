import Foundation
import LLMCore

extension LLMClient {
    /// Query the configured connection through LLMServer, without running inference or
    /// charging platform credits. Supply a provider when browsing a different connection.
    /// The returned list is advisory; callers may still submit any valid model ID.
    public func listBYOKModels(provider: LLMBYOKProvider? = nil) async throws -> [LLMBYOKModel] {
        let credentials = try await modelDiscoveryCredentials(provider: provider)
        return try await fetchBYOKModels(credentials: credentials)
    }

    /// Resolve the connection through the existing model-aware credential callback.
    /// An explicit platform selection throws rather than querying with the platform key.
    public func listBYOKModels(for model: SupportedModel) async throws -> [LLMBYOKModel] {
        guard let credentials = try await inferenceCredentials(for: model) else {
            throw LLMBYOKConfigurationError.providerRequired
        }
        return try await fetchBYOKModels(credentials: credentials)
    }

    func modelDiscoveryCredentials(provider: LLMBYOKProvider?) async throws -> LLMBYOKCredentials {
        if let provider { return try await provider.credentials() }
        // Without a selected model, a model-aware callback cannot choose a connection.
        guard byokModelCredentialsProvider == nil else { throw LLMBYOKConfigurationError.providerRequired }
        if let byokProvider { return try await byokProvider.credentials() }
        guard let credentials = try await byokCredentialsProvider?() else { throw LLMBYOKConfigurationError.providerRequired }
        return credentials
    }

    private func fetchBYOKModels(credentials: LLMBYOKCredentials) async throws -> [LLMBYOKModel] {
        guard credentials.configuration.modelDiscovery != nil else { throw LLMBYOKConfigurationError.modelDiscoveryUnsupported }
        let response: APIResponse<[LLMBYOKModel]> = try await networking.postInference(
            "/chat/models", body: EmptyMetadata(), credentials: credentials
        )
        if let error = response.error { throw LLMError.server(statusCode: error.code, message: error.message) }
        guard let models = response.data else { throw LLMError.decoding(underlying: LLMBYOKConfigurationError.invalidModelList) }
        return models
    }
}
