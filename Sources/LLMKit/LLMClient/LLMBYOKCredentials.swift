import Foundation
import LLMCore

public typealias LLMBYOKConfiguration = LLMCore.LLMBYOKConfiguration
public typealias LLMBYOKPreset = LLMCore.LLMBYOKPreset

/// Request-only credentials. This type deliberately does not conform to Codable.
///
/// The host app owns persistence (for example, Keychain). LLMKit sends these credentials
/// only to LLMServer's chat/model-discovery endpoints; it never saves them in conversations or metadata.
public struct LLMBYOKCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let configuration: LLMBYOKConfiguration
    private let apiKey: String

    public init(configuration: LLMBYOKConfiguration, apiKey: String) {
        self.configuration = configuration
        self.apiKey = apiKey
    }

    @available(*, deprecated, message: "Use init(configuration:apiKey:); providers are connection presets now.")
    public init(provider: LLMBYOKPreset, apiKey: String) {
        self.init(configuration: provider.configuration, apiKey: apiKey)
    }

    @available(*, deprecated, message: "Use configuration; a custom connection need not have a preset.")
    public var provider: LLMBYOKPreset? { configuration.preset }

    public var description: String { "LLMBYOKCredentials(configuration: \(configuration.preset?.rawValue ?? "custom"), apiKey: <redacted>)" }
    public var debugDescription: String { description }

    func apply(to request: inout URLRequest) throws {
        guard let url = request.url,
              request.httpMethod == "POST",
              ["/chat/byok", "/chat/byok/stream", "/chat/byok/ask", "/chat/byok/models"].contains(url.path) else {
            throw LLMBYOKConfigurationError.unsupportedEndpoint
        }
        let isLoopback = ["localhost", "127.0.0.1", "[::1]", "::1"].contains(url.host?.lowercased() ?? "")
        guard url.scheme?.lowercased() == "https"
                || (url.scheme?.lowercased() == "http" && isLoopback) else {
            throw LLMBYOKConfigurationError.insecureConnection
        }
        try configuration.validate()

        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty,
              key.utf8.count <= 4096,
              key.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw LLMBYOKConfigurationError.invalidAPIKey
        }
        let data = try JSONEncoder().encode(configuration)
        request.setValue(data.base64EncodedString(), forHTTPHeaderField: "X-LLM-BYOK-Configuration")
        request.setValue(nil, forHTTPHeaderField: "X-LLM-BYOK-Provider")
        request.setValue(key, forHTTPHeaderField: "X-LLM-BYOK-Key")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
    }
}

/// Called for each model request, including Agent rounds, title generation and compaction.
/// Return nil only when platform billing was explicitly selected. If BYOK is selected but
/// its key is unavailable, throw instead: returning nil would select the platform key.
public typealias LLMBYOKCredentialsProvider = @Sendable () async throws -> LLMBYOKCredentials?

public enum LLMBYOKConfigurationError: Error, LocalizedError, Sendable {
    case invalidAPIKey
    case insecureConnection
    case unsupportedEndpoint
    case providerRequired
    case modelDiscoveryUnsupported
    case invalidModelList

    public var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return "The BYOK API key is missing or invalid."
        case .insecureConnection:
            return "BYOK requires HTTPS, except for a local loopback development server."
        case .unsupportedEndpoint:
            return "BYOK credentials can only be sent to LLMServer chat or model-discovery endpoints."
        case .providerRequired:
            return "Select a BYOK provider or model before listing models."
        case .modelDiscoveryUnsupported:
            return "Model discovery is disabled for this BYOK connection. You can still enter a model ID manually."
        case .invalidModelList:
            return "The server returned an invalid BYOK model list."
        }
    }
}
