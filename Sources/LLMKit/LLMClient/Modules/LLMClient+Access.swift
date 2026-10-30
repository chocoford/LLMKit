import Foundation
import LLMCore

/// An optional App-owned preflight. The server always repeats authoritative authorization.
public typealias LLMAccessPolicyProvider = @Sendable (LLMAccessRequest) async throws -> LLMAccessDecision

extension LLMClient {
    /// Check a host App requirement before showing/using a feature. Unknown requirements must
    /// be rejected by the host policy; this method does not register server permissions.
    public func authorizeAccess(_ request: LLMAccessRequest) async throws {
        guard let accessPolicy else {
            if !request.requirementIDs.isEmpty { throw LLMError.accessDenied(requirementIDs: request.requirementIDs) }
            return // Backward-compatible clients rely on the server's authoritative check.
        }
        let decision = try await accessPolicy(request)
        guard decision.allowed else {
            throw LLMError.accessDenied(requirementIDs: decision.missingRequirementIDs.isEmpty ? decision.requirementIDs : decision.missingRequirementIDs)
        }
    }

    /// Advisory UI snapshot. It is not a token and cannot authorize a subsequent request.
    /// Requires an App JWT; Direct mode explicitly rejects all LLMServer endpoints.
    public func getAccessDecision(for resource: LLMAccessResource) async throws -> LLMAccessDecision {
        try resource.validate()
        return try await networking.post("/access/evaluate", body: resource)
    }
}
