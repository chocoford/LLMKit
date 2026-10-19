import Foundation

/// A provider whose API key can be used by LLMServer for a model request.
public enum LLMBYOKProvider: String, Sendable {
    case openRouter = "openrouter"
}

/// Request-only credentials. This type deliberately does not conform to Codable.
///
/// The host app owns persistence (for example, Keychain). LLMKit sends these credentials
/// only to LLMServer's chat endpoints; it never saves them in conversations or metadata.
public struct LLMBYOKCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let provider: LLMBYOKProvider
    private let apiKey: String

    public init(provider: LLMBYOKProvider, apiKey: String) {
        self.provider = provider
        self.apiKey = apiKey
    }

    public var description: String { "LLMBYOKCredentials(provider: \(provider.rawValue), apiKey: <redacted>)" }
    public var debugDescription: String { description }

    func apply(to request: inout URLRequest) throws {
        guard let url = request.url,
              request.httpMethod == "POST",
              ["/chat/byok", "/chat/byok/stream", "/chat/byok/ask"].contains(url.path) else {
            throw LLMBYOKConfigurationError.unsupportedEndpoint
        }
        let isLoopback = ["localhost", "127.0.0.1", "[::1]", "::1"].contains(url.host?.lowercased() ?? "")
        guard url.scheme?.lowercased() == "https"
                || (url.scheme?.lowercased() == "http" && isLoopback) else {
            throw LLMBYOKConfigurationError.insecureConnection
        }

        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty,
              key.utf8.count <= 4096,
              key.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw LLMBYOKConfigurationError.invalidAPIKey
        }
        request.setValue(provider.rawValue, forHTTPHeaderField: "X-LLM-BYOK-Provider")
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

    public var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return "The BYOK API key is missing or invalid."
        case .insecureConnection:
            return "BYOK requires HTTPS, except for a local loopback development server."
        case .unsupportedEndpoint:
            return "BYOK credentials can only be sent to LLMServer chat endpoints."
        }
    }
}
