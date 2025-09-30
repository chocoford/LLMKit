//
//  File.swift
//  LLMKit
//
//  Created by Chocoford on 9/5/25.
//

#if canImport(SwiftUI)
import SwiftUI
import Logging

private struct LLMClientKey: EnvironmentKey {
    static let defaultValue: LLMClient = .init()
}

extension EnvironmentValues {
    public var llmClient: LLMClient {
        get { self[LLMClientKey.self] }
        set { self[LLMClientKey.self] = newValue }
    }
}

public struct LLMClientProvider: ViewModifier {
    let logger = Logger(label: "LLMClientProvider")

    let llmClient: LLMClient
    
    public init(llmClient: LLMClient) {
        self.llmClient = llmClient
        self._state = StateObject(wrappedValue: LLMStateObject(llmClient: llmClient))
    }
    
    @StateObject private var state: LLMStateObject
    

    public func body(content: Content) -> some View {
        content
            .environment(\.llmClient, llmClient)
            .onReceive(llmClient.creditsUpdatePublisher) { credits in
                logger.info("Credits updated: \(credits)")
                state.updateCredits(credits)
            }
            .onReceive(llmClient.authStateChangedPublisher) { isAuthenticated in
                state.isAuthenticated = isAuthenticated
            }
            .environmentObject(state)
    }
}



#endif // canImport(SwiftUI)
