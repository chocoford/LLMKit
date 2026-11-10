import Foundation
import LLMCore

/// Non-secret routing identity. Persist with the conversation, never with a provider key.
public struct LLMSchemeConversationBinding: Codable, Equatable, Sendable {
    public let selection: LLMSchemeSelection
    public let billing: LLMSchemeBilling
    public let connectionID: String?

    public init(selection: LLMSchemeSelection, billing: LLMSchemeBilling, connectionID: String? = nil) {
        self.selection = selection
        self.billing = billing
        self.connectionID = connectionID
    }

    public func validate() throws {
        try selection.validate()
        switch billing {
        case .platform:
            guard connectionID == nil, selection.profileID != nil else { throw LLMSchemeStateError.invalidBinding }
        case .byok(let model):
            guard selection.profileID == nil, let connectionID, !connectionID.isEmpty,
                  connectionID.utf8.count <= 512,
                  connectionID.utf8.allSatisfy({ (33...126).contains($0) }),
                  !model.rawValue.isEmpty, model.rawValue.utf8.count <= 512,
                  model.rawValue.utf8.allSatisfy({ (33...126).contains($0) }) else {
                throw LLMSchemeStateError.invalidBinding
            }
        }
    }
}

/// App-owned Keychain lookup by stable connection identity, not the UI's current selection.
public typealias LLMSchemeConversationCredentialsProvider = @Sendable (
    _ connectionID: String, _ model: SupportedModel
) async throws -> LLMBYOKCredentials

public enum LLMSchemeStateError: Error, LocalizedError, Sendable {
    case invalidBinding
    case connectionMismatch
    case credentialsProviderRequired
    case conversationRequired
    case generationInProgress
    case routePersistenceRequired

    public var errorDescription: String? {
        switch self {
        case .invalidBinding: "The Scheme conversation route is invalid. BYOK requires a stable connection ID."
        case .connectionMismatch: "This conversation has a different Scheme route. Explicitly update its model, billing or connection while idle. Changing Scheme or Direct/server mode requires a new conversation."
        case .credentialsProviderRequired: "Restore this conversation's BYOK connection before continuing. No platform fallback was attempted."
        case .conversationRequired: "State-layer Scheme routing supports conversation schemes only."
        case .generationInProgress: "Wait for this conversation's generation or routing update to finish before changing its routing."
        case .routePersistenceRequired: "The conversation store must support saving Scheme routing changes before this selection can be updated."
        }
    }
}
