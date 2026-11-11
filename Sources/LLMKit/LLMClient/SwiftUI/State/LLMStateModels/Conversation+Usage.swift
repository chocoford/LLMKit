import LLMCore

extension Conversation {
    /// Actual request usage, including compacted history and separately classified auxiliaries.
    /// Old assistant messages remain explicitly unreported instead of appearing free.
    public var usageSummary: LLMUsageSummary {
        .init(messages.contentMessages.flatMap { message in
            if let records = message.inferenceUsage, !records.isEmpty { return records }
            guard message.role == .assistant else { return [] }
            return [.init(id: "legacy:\(message.id)", responseID: message.id, isComplete: true)]
        })
    }

    /// All model/tool rounds belonging to the generation that produced this message.
    /// Does not silently include title/summary requests in the displayed chat total.
    public func usageSummary(forMessageID messageID: ChatMessage.ID) -> LLMUsageSummary {
        guard let message = messages.first(where: { $0.id == messageID }) else { return .init([]) }
        let records = message.inferenceUsage ?? []
        if records.isEmpty, message.role == .assistant {
            return .init([.init(id: "legacy:\(message.id)", responseID: message.id, isComplete: true)])
        }
        let generations = Set(records.filter { $0.purpose == "chat" }.compactMap(\.generationID))
        guard !generations.isEmpty else { return .init(records) }
        return .init(usageSummary.requests.filter {
            $0.purpose == "chat" && $0.generationID.map(generations.contains) == true
        })
    }
}
