import LLMCore

/// Request-scoped state-layer routing. Child tasks inherit this scope; unrelated clients do not.
internal enum LLMSchemeScope {
    @TaskLocal static var provider: LLMSchemeProvider?

    static func provider(for client: LLMClient) -> LLMSchemeProvider? {
        guard let provider, provider.client === client else { return nil }
        return provider
    }
}

extension LLMClient {
    /// Route existing LLMState/LLMStateObject create/send/retry/resume operations through a Scheme.
    /// Admission and key resolution happen before the operation (including attachment uploads).
    /// The Scheme, profile, billing and credentials remain fixed across tool rounds and overflow
    /// recovery. Outside this scope the state layer retains its legacy behavior.
    /// Titles/summaries remain auxiliary requests; hosts must scope their billing explicitly.
    @MainActor
    public func withScheme<Result>(
        _ selection: LLMSchemeSelection,
        billing: LLMSchemeBilling,
        operation: @MainActor () async throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        let provider = try await LLMSchemeProvider(client: self, selection: selection, billing: billing).prepared()
        try Task.checkCancellation()
        return try await LLMSchemeScope.$provider.withValue(provider) {
            try await operation()
        }
    }
}
