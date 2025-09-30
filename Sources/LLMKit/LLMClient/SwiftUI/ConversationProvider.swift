//
//  SwiftUIView.swift
//  LLMKit
//
//  Created by Chocoford on 9/29/25.
//

#if canImport(SwiftUI)
import SwiftUI
import LLMCore

public struct ConversationProvider: View {
    
    @EnvironmentObject private var llmState: LLMStateObject
    
    var conversationID: UUID
    var content: (_ conversation: Conversation?) -> AnyView
    
    public init<Content: View>(
        conversationID: UUID,
        @ViewBuilder content: @escaping (_: Conversation?) -> Content
    ) {
        self.conversationID = conversationID
        self.content = {
            AnyView(content($0))
        }
    }
    
    @MainActor
    public class Proxy {
        public internal(set) var messages: [ChatMessage] = []
    }
    
    let proxy = Proxy()
    
    var conversation: Conversation? {
        llmState.conversations.first { $0.id == conversationID }
    }
    
    public var body: some View {
        content(conversation)
//            .onChange(of: conversation) { newValue in
//                proxy.messages = newValue?.messages ?? []
//            }
//            .onAppear {
//                proxy.messages = conversation?.messages ?? []
//            }
    }
}


#endif // canImport(SwiftUI)
