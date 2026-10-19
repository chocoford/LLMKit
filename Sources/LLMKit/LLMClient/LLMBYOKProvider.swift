import Foundation

/// One backend-mediated BYOK provider, driven entirely by a non-secret configuration.
/// The App owns the credential source (normally Keychain); this value never encodes a key.
public struct LLMBYOKProvider: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let configuration: LLMBYOKConfiguration
    private let apiKeyProvider: @Sendable () async throws -> String

    public init(
        configuration: LLMBYOKConfiguration,
        apiKeyProvider: @escaping @Sendable () async throws -> String
    ) {
        self.configuration = configuration
        self.apiKeyProvider = apiKeyProvider
    }

    func credentials() async throws -> LLMBYOKCredentials {
        try configuration.validate()
        return LLMBYOKCredentials(configuration: configuration, apiKey: try await apiKeyProvider())
    }

    public var description: String { "LLMBYOKProvider(configuration: \(configuration.preset?.rawValue ?? "custom"), apiKey: <redacted>)" }
    public var debugDescription: String { description }
}
