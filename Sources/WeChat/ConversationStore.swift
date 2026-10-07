import Foundation

struct ConversationMergeResult: Sendable {
    let appended: [ChatMessage]
    let prepended: [ChatMessage]
    let unchanged: Bool
    let viewport: ChatViewportState
}

/// The in-memory conversation timeline. AX snapshots are observations; only this
/// store owns the accumulated message list shown to the UI and supplied to analysis.
final class ConversationStore {
    private(set) var messages: [ChatMessage] = []
    private let maximumMessages: Int

    init(maximumMessages: Int = 200) {
        self.maximumMessages = max(20, maximumMessages)
    }

    func clear() {
        messages.removeAll(keepingCapacity: true)
    }

    func merge(_ snapshot: [ChatMessage], trust: ConversationCaptureTrust) -> ConversationMergeResult {
        guard trust.mayEnterTrustedStore else {
            return ConversationMergeResult(appended: [], prepended: [], unchanged: true, viewport: .uncertain)
        }
        guard !snapshot.isEmpty else {
            return ConversationMergeResult(appended: [], prepended: [], unchanged: true, viewport: .uncertain)
        }
        guard !messages.isEmpty else {
            messages = Array(snapshot.suffix(maximumMessages))
            return ConversationMergeResult(appended: messages, prepended: [], unchanged: false, viewport: .liveTail)
        }

        // A matching suffix of stored history anchors the visible sequence at
        // the known tail. Only rows after that anchor are new live messages.
        if let overlap = Self.tailOverlap(existing: messages, observed: snapshot) {
            let appended = Array(snapshot.dropFirst(overlap.observedStart + overlap.length))
            let merged = messages + appended
            messages = Array(merged.suffix(maximumMessages))
            return ConversationMergeResult(appended: appended, prepended: [],
                                           unchanged: appended.isEmpty, viewport: .liveTail)
        }

        // A suffix of the observed rows matching an internal stored sequence
        // identifies a historical viewport. Only its unanchored older prefix
        // is inserted; rows after an internal match never count as live.
        if let overlap = Self.historicalOverlap(existing: messages, observed: snapshot) {
            let prefix = Array(snapshot.prefix(overlap.observedStart))
            let merged: [ChatMessage]
            if prefix.isEmpty {
                merged = messages
            } else if overlap.existingStart == 0 {
                merged = prefix + messages
            } else {
                let insertionIndex = overlap.existingStart
                merged = Array(messages.prefix(insertionIndex)) + prefix + Array(messages.dropFirst(insertionIndex))
            }
            let prependedCount = max(0, merged.count - messages.count)
            messages = Array(merged.suffix(maximumMessages))
            let prepended = prependedCount > 0 ? Array(messages.prefix(prependedCount)) : []
            return ConversationMergeResult(appended: [], prepended: prepended,
                                           unchanged: prepended.isEmpty, viewport: .historical)
        }

        return ConversationMergeResult(appended: [], prepended: [], unchanged: true, viewport: .uncertain)
    }

    private static func tailOverlap(existing: [ChatMessage], observed: [ChatMessage]) -> (length: Int, observedStart: Int)? {
        let maxLength = min(existing.count, observed.count)
        guard maxLength > 0 else { return nil }
        for length in stride(from: maxLength, through: 1, by: -1) {
            for start in 0...(observed.count - length) {
                if ChatHistoryMerger.sequencesMatch(existing, lhsStart: existing.count - length,
                                                    observed, rhsStart: start, length: length) {
                    if length == 1 && ChatHistoryMerger.key(for: existing[existing.count - 1]) !=
                        ChatHistoryMerger.key(for: observed[start]) { continue }
                    // A match after an unanchored prefix and with no rows after
                    // it describes a historical viewport, not the live tail.
                    if start > 0 && start + length == observed.count { continue }
                    return (length, start)
                }
            }
        }
        return nil
    }

    private static func historicalOverlap(existing: [ChatMessage], observed: [ChatMessage]) -> (length: Int, observedStart: Int, existingStart: Int)? {
        let maxLength = min(existing.count, observed.count)
        guard maxLength > 0 else { return nil }
        let minimumLength = maxLength >= 2 ? 2 : 1
        for length in stride(from: maxLength, through: minimumLength, by: -1) {
            // Requiring the match to end at the observed viewport's end makes
            // this a backward/history anchor rather than a live append.
            let observedStart = observed.count - length
            for historyStart in 0...(existing.count - length) {
                if ChatHistoryMerger.sequencesMatch(existing, lhsStart: historyStart,
                                                    observed, rhsStart: observedStart, length: length) {
                    return (length, observedStart, historyStart)
                }
            }
        }
        return nil
    }

}
