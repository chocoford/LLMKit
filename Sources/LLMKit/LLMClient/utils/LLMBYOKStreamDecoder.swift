import Foundation

/// Strict decoder for LLMServer's BYOK SSE contract. A transport EOF is not completion.
/// Keep framing separate from URLSession so truncated frames can be tested byte by byte.
struct LLMBYOKStreamDecoder<Element: Decodable> {
    private var lineBytes: [UInt8] = []
    private var dataLines: [String] = []
    private var eventName: String?
    private var previousWasCR = false
    private(set) var isComplete = false

    mutating func append(_ byte: UInt8) throws -> Element? {
        guard !isComplete else { throw invalidFrame() }
        if previousWasCR {
            previousWasCR = false
            if byte == 10 { return nil }
        }
        if byte == 13 || byte == 10 {
            previousWasCR = byte == 13
            return try consumeLine()
        }
        lineBytes.append(byte)
        return nil
    }

    func validateEnd() throws {
        guard isComplete else {
            throw LLMError.network(underlying: LLMBYOKStreamFailure.interruptedStream)
        }
    }

    private mutating func consumeLine() throws -> Element? {
        guard let line = String(bytes: lineBytes, encoding: .utf8) else { throw invalidFrame() }
        lineBytes.removeAll(keepingCapacity: true)

        if line.isEmpty {
            guard !dataLines.isEmpty else {
                guard eventName == nil else { throw invalidFrame() }
                return nil
            }
            let payload = dataLines.joined(separator: "\n")
            let event = eventName
            dataLines.removeAll(keepingCapacity: true)
            eventName = nil

            guard event == nil || event == "message" || event == "error" else { throw invalidFrame() }
            if payload == "[DONE]" {
                guard event != "error" else { throw invalidFrame() }
                isComplete = true
                return nil
            }

            let data = Data(payload.utf8)
            if let failure = try? JSONDecoder().decode(LLMStreamErrorEnvelope.self, from: data) {
                throw LLMError.fromHTTP(statusCode: failure.error.code, body: data)
            }
            guard event != "error" else { throw invalidFrame() }
            do {
                return try JSONDecoder().decode(Element.self, from: data)
            } catch {
                // Never include raw frame contents (or decoding debug context) in this error.
                throw invalidFrame()
            }
        }

        if line.hasPrefix(":") { return nil } // SSE heartbeat / comment.
        let fields = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        var value = fields.count == 2 ? String(fields[1]) : ""
        if value.first == " " { value.removeFirst() }
        switch fields[0] {
        case "data": dataLines.append(value)
        case "event": eventName = value
        case "id", "retry": break
        default: throw invalidFrame()
        }
        return nil
    }

    private func invalidFrame() -> LLMError {
        .decoding(underlying: LLMBYOKStreamFailure.invalidFrame)
    }
}

enum LLMBYOKStreamFailure: LocalizedError, Equatable, Sendable {
    case invalidFrame
    case interruptedStream

    var errorDescription: String? {
        switch self {
        case .invalidFrame:
            return "LLMServer returned an invalid BYOK stream frame."
        case .interruptedStream:
            return "The BYOK stream ended before its completion marker. Please retry."
        }
    }
}

struct LLMStreamErrorEnvelope: Decodable {
    struct Failure: Decodable {
        let code: Int
        let message: String
    }
    let error: Failure
}
