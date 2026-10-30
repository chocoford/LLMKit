import Foundation
import Testing
import LLMCore
@testable import LLMKit

@Suite("SDK access policy boundaries")
struct LLMAccessTests {
    @Test("Old clients can rely on the server; explicit local requirements fail closed")
    func optionalPolicy() async throws {
        let client = LLMClient(authProvider: NoAuthProvider())
        try await client.authorizeAccess(.init(resource: .init(kind: "local", id: "drawing")))
        do {
            try await client.authorizeAccess(.init(resource: .init(kind: "local", id: "drawing"), requirementIDs: ["custom-entitlement"]))
            Issue.record("A missing host policy cannot grant an explicit local requirement")
        } catch LLMError.accessDenied(let ids) { #expect(ids == ["custom-entitlement"]) }
    }

    @Test("Preflight stops all BYOK inference methods before any network call", arguments: ["chat", "stream", "ask"])
    func deniedBYOK(operation: String) async throws {
        let client = LLMClient(authProvider: NoAuthProvider(), byokProvider: .init(configuration: .openAI) { "synthetic-key" }, accessPolicy: { request in
            #expect(request.resource.billingSource == .byok)
            #expect(request.model == .other("future-model"))
            return .init(allowed: false, requirementIDs: ["enhanced-ai"], missingRequirementIDs: ["enhanced-ai"], denial: .subscriptionRequired)
        })
        do {
            switch operation {
            case "stream": _ = try await client.streamChat(model: .other("future-model"), text: "hello")
            case "ask": _ = try await client.ask(prompt: "hello", model: .other("future-model"))
            default: _ = try await client.chat(model: .other("future-model"), text: "hello")
            }
            Issue.record("A denied request must never reach networking or fall back to platform")
        } catch LLMError.accessDenied(let ids) { #expect(ids == ["enhanced-ai"]) }
    }

    @Test("Global Allow cannot override an agent preflight denial")
    func agentPreflight() async throws {
        let client = LLMClient(authProvider: NoAuthProvider(), accessPolicy: { request in
            #expect(request.resource.billingSource == .platform)
            return .init(allowed: request.resource.kind != "agent", requirementIDs: request.resource.kind == "agent" ? ["drawing"] : [])
        })
        do {
            _ = try await client.inferenceCredentials(for: .gpt4o, agentID: "canvas")
            Issue.record("Agent policy denial must propagate")
        } catch LLMError.accessDenied(let ids) { #expect(ids == ["drawing"]) }
    }

    @Test("Auth, access, credits and configuration failures stay distinct")
    func errorMapping() throws {
        let body = Data(#"{"error":{"code":403,"message":"Access denied","access":{"allowed":false,"requirementIDs":["max","drawing"],"missingRequirementIDs":["drawing"],"denial":"subscriptionRequired"}}}"#.utf8)
        guard case .accessDenied(let ids) = LLMError.fromHTTP(statusCode: 403, body: body) else { Issue.record("Expected structured access denial"); return }
        #expect(ids == ["drawing"])
        guard case .unauthorized = LLMError.fromHTTP(statusCode: 401, body: body) else { Issue.record("Expected login failure"); return }
        guard case .insufficientCredits = LLMError.fromHTTP(statusCode: 402, body: body) else { Issue.record("Expected credit failure"); return }
        guard case .forbidden = LLMError.fromHTTP(statusCode: 403, body: Data(#"{"error":{"code":403,"message":"Model not allowed"}}"#.utf8)) else { Issue.record("Expected legacy model denial"); return }
        guard case .server(let code, _) = LLMError.fromHTTP(statusCode: 503, body: body) else { Issue.record("Expected operator configuration failure"); return }
        #expect(code == 503)
    }

    @Test("Advisory credential selection never invokes inference entitlement policy")
    func catalogRemainsIndependent() async throws {
        let client = LLMClient(authProvider: NoAuthProvider(), byokModelCredentialsProvider: { _ in
            .init(configuration: .openAI, apiKey: "catalog-key")
        }, accessPolicy: { _ in
            Issue.record("Catalog credential resolution must not require paid inference access")
            return .denied(.explicitDeny)
        })
        #expect(try await client.modelCredentials(for: .other("future-model"))?.configuration == .openAI)
    }
}
