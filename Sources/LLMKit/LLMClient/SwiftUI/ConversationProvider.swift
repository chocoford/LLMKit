//
//  SwiftUIView.swift
//  LLMKit
//
//  Created by Chocoford on 9/29/25.
//

#if canImport(SwiftUI)
import SwiftUI
import LLMCore

@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
public struct ConversationProvider: View {
    
    @Environment(LLMState.self) private var llmState
    
    var conversationID: String
    var content: (_ conversation: Conversation?) -> AnyView
    
    public init<Content: View>(
        conversationID: String,
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
    let config = Config()
    
    var conversation: Conversation? {
        llmState.conversations.value?.first { $0.id == conversationID }
    }
    
    public var body: some View {
        content(conversation)
    }
    
    
    class Config {
        
    }
    
    public func onConversationPhaseChange(
        _ action: (_ oldPhase: ConversationPhase, _ newPhase: ConversationPhase) -> Void
    ) -> Self {
        
        return self
    }
}


#endif // canImport(SwiftUI)
