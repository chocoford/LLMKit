//
//  File.swift
//  LLMKit
//
//  Created by Chocoford on 9/5/25.
//

#if canImport(SwiftUI)
import SwiftUI
import Combine

import Logging
import ChocofordUI

private struct LLMClientKey: EnvironmentKey {
    static let defaultValue: LLMClient = .init()
}

extension EnvironmentValues {
    public var llmClient: LLMClient {
        get { self[LLMClientKey.self] }
        set { self[LLMClientKey.self] = newValue }
    }
}

struct LLMStateObjectProvider: View {
    var content: (LLMStatable) -> AnyView
    
    init<Content: View>(
        llmClient: LLMClient,
        persistenceProvider: PersistenceProvider?,
        @ViewBuilder content: @escaping (LLMStatable) -> Content
    ) {
        self._state = StateObject(
            wrappedValue: LLMStateObject(llmClient: llmClient, persistenceProvider: persistenceProvider)
        )
        self.content = {
            AnyView(content($0))
        }
    }
    @StateObject private var state: LLMStateObject
    
    var body: some View {
        content(state)
            .environmentObject(state)
    }
}

@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
struct LLMObservableStateProvider: View {
    var content: (LLMStatable) -> AnyView
    
    init<Content: View>(
        llmClient: LLMClient,
        persistenceProvider: PersistenceProvider?,
        @ViewBuilder content: @escaping (LLMStatable) -> Content
    ) {
        self._state = State(
            initialValue: LLMState(llmClient: llmClient, persistenceProvider: persistenceProvider)
        )
        self.content = {
            AnyView(content($0))
        }
    }
    @State private var state: LLMState
    
    var body: some View {
        content(state)
            .environment(state)
    }
}


struct LLMStateProvider: View {
    var llmClient: LLMClient
    var persistenceProvider: PersistenceProvider?
    var lagacy: Bool
    var content: (LLMStatable) -> AnyView

    init<Content: View>(
        llmClient: LLMClient,
        persistenceProvider: PersistenceProvider?,
        lagacy: Bool = false,
        @ViewBuilder content: @escaping (LLMStatable) -> Content
    ) {
        self.llmClient = llmClient
        self.persistenceProvider = persistenceProvider
        self.lagacy = lagacy
        self.content = {
            AnyView(content($0))
        }
    }
    
    var body: some View {
        if #available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *), !lagacy {
            LLMObservableStateProvider(llmClient: llmClient, persistenceProvider: persistenceProvider) { state in
                content(state)
                    .task {
                        await state.refreshConversations()
                    }
            }
        } else {
            LLMStateObjectProvider(llmClient: llmClient, persistenceProvider: persistenceProvider) { state in
                content(state)
                    .task {
                        await state.refreshConversations()
                    }
            }
        }
    }
}

public struct LLMClientProvider: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    
    let logger = Logger(label: "LLMClientProvider")

    let llmClient: LLMClient
    var persistenceProvider: PersistenceProvider?
    var lagacy: Bool
    
    internal init(
        llmClient: LLMClient,
        persistenceProvider: PersistenceProvider?,
        lagacy: Bool = false
    ) {
        self.llmClient = llmClient
        self.persistenceProvider = persistenceProvider
        self.lagacy = lagacy
    }
    
    public static func lagacy(
        llmClient: LLMClient,
        persistenceProvider: PersistenceProvider?
    ) -> LLMClientProvider {
        LLMClientProvider(
            llmClient: llmClient,
            persistenceProvider: persistenceProvider,
            lagacy: true
        )
    }
    
    @available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
    public static func modern(
        llmClient: LLMClient,
        persistenceProvider: PersistenceProvider?
    ) -> LLMClientProvider {
        LLMClientProvider(
            llmClient: llmClient,
            persistenceProvider: persistenceProvider,
            lagacy: false
        )
    }
    
    @State private var refreshCreditsPassthrough = PassthroughSubject<Void, Never>()

    public func body(content: Content) -> some View {
        LLMStateProvider(
            llmClient: llmClient,
            persistenceProvider: persistenceProvider,
            lagacy: lagacy
        ) { state in
            content
                .environment(\.llmClient, llmClient)
                .onReceive(llmClient.creditsUpdatePublisher) { credits in
                    logger.info("Credits updated: \(credits)")
                    state.updateCredits(credits)
                }
                .onReceive(llmClient.authStateChangedPublisher) { isAuthenticated in
                    state.isAuthenticated = isAuthenticated
                }
                .onReceive(refreshCreditsPassthrough.throttle(for: 30.0, scheduler: RunLoop.main, latest: true)) { _ in
                    Task {
                        if let credits = try? await llmClient.getCredits() {
                            state.updateCredits(credits)
                        }
                    }
                }
                .watchImmediately(of: scenePhase) { newValue in
                    if newValue == .active {
                        refreshCreditsPassthrough.send()
                    }
                }
        }
    }
}



extension View {
    @available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
    public func llmProvider(client: LLMClient, persistenceProvider: PersistenceProvider?) -> some View {
        modifier(LLMClientProvider.modern(llmClient: client, persistenceProvider: persistenceProvider))
    }
    public func llmProviderLagacy(client: LLMClient, persistenceProvider: PersistenceProvider?) -> some View {
        modifier(LLMClientProvider.lagacy(llmClient: client, persistenceProvider: persistenceProvider))
    }
}


#endif // canImport(SwiftUI)
