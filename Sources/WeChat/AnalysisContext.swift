import Foundation

enum AnalysisContextError: LocalizedError {
    case unavailableSelection, tooManyMessages, staleContext
    var errorDescription: String? {
        switch self {
        case .unavailableSelection: return "Select a retained message range first."
        case .tooManyMessages: return "Select at most 20 messages for one analysis."
        case .staleContext: return "The conversation or selected context changed. Preview it again before analyzing."
        }
    }
}

struct AnalysisContextSelection {
    private(set) var start: UUID?
    private(set) var end: UUID?
    mutating func select(_ id: UUID) {
        if start == nil || end != nil { start = id; end = nil }
        else { end = id }
    }
    func messages(in retained: [ChatMessage]) throws -> [ChatMessage] {
        guard let start, let first = retained.firstIndex(where: { $0.localID == start }),
              let last = retained.firstIndex(where: { $0.localID == (end ?? start) }) else { throw AnalysisContextError.unavailableSelection }
        let range = min(first,last)...max(first,last)
        guard range.count <= 20 else { throw AnalysisContextError.tooManyMessages }
        return Array(retained[range])
    }
    func selectedIDs(in retained: [ChatMessage]) -> Set<UUID> {
        guard let start, let first = retained.firstIndex(where: { $0.localID == start }),
              let last = retained.firstIndex(where: { $0.localID == (end ?? start) }) else { return [] }
        return Set(retained[min(first,last)...max(first,last)].map(\.localID))
    }
}

enum AnalysisContext {
    static let limit = 20
    static func latest(in retained: [ChatMessage]) -> [ChatMessage] { Array(retained.suffix(limit)) }
    static func isCurrent(_ frozen: [ChatMessage], session: UUID, currentSession: UUID, retained: [ChatMessage]) -> Bool {
        guard session == currentSession, !frozen.isEmpty, frozen.count <= limit else { return false }
        guard let first = retained.firstIndex(where: { $0.localID == frozen[0].localID }),
              first + frozen.count <= retained.count else { return false }
        return Array(retained[first..<(first + frozen.count)]) == frozen
    }
    static func modelText(_ messages: [ChatMessage]) throws -> String {
        guard messages.count <= limit else { throw AnalysisContextError.tooManyMessages }
        return messages.map { message in
            let speaker = message.sender == .me ? "我" : (message.sender == .other ? "对方" : "说话方不确定")
            let divider = message.timeSeparatorBefore.map { "[观察到的微信时间分隔：\($0)]\n" } ?? ""
            return divider + "\(speaker)：\(message.text)"
        }.joined(separator: "\n")
    }
}
