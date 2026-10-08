import Foundation

struct ConversationMergeResult: Sendable {
    let appended: [ChatMessage]
    let prepended: [ChatMessage]
    let unchanged: Bool
    let viewport: ChatViewportState
    let arrivalConfirmed: Bool

    init(appended: [ChatMessage], prepended: [ChatMessage], unchanged: Bool,
         viewport: ChatViewportState, arrivalConfirmed: Bool = false) {
        self.appended = appended
        self.prepended = prepended
        self.unchanged = unchanged
        self.viewport = viewport
        self.arrivalConfirmed = arrivalConfirmed
    }
}

/// The in-memory conversation timeline. AX snapshots are observations; only this
/// store owns the accumulated message list shown to the UI and supplied to analysis.
final class ConversationStore {
    private(set) var messages: [ChatMessage] = []
    var timeSeparatorEvents: [ConversationTimeSeparatorEvent] {
        messages.compactMap { message in
            message.observedTimeSeparator.map { ConversationTimeSeparatorEvent(beforeMessageID: message.localID, observation: $0) }
        }
    }
    private let maximumMessages: Int

    init(maximumMessages: Int = 200) {
        self.maximumMessages = max(20, maximumMessages)
    }

    func clear() {
        messages.removeAll(keepingCapacity: true)
    }

    func merge(_ snapshot: [ChatMessage], trust: ConversationCaptureTrust, liveEdgeState: Bool? = nil) -> ConversationMergeResult {
        guard trust.mayEnterTrustedStore else {
            return ConversationMergeResult(appended: [], prepended: [], unchanged: true, viewport: .uncertain)
        }
        guard !snapshot.isEmpty else {
            return ConversationMergeResult(appended: [], prepended: [], unchanged: true, viewport: .uncertain)
        }
        guard !messages.isEmpty else {
            messages = Array(snapshot.suffix(maximumMessages))
            return ConversationMergeResult(appended: messages, prepended: [], unchanged: false, viewport: liveEdgeState == false ? .historical : .liveTail)
        }

        // Prefer a complete historical match over a shorter repeated tail
        // match. Scrolling to an earlier "OK" must not append old rows.
        let historical = Self.historicalOverlap(existing: messages, observed: snapshot)
        let tail = Self.tailOverlap(existing: messages, observed: snapshot)
        let preferHistorical = historical.map { history in
            history.existingStart + history.length < messages.count &&
                history.length >= (tail?.length ?? 0)
        } ?? false

        // A matching suffix of stored history anchors the visible sequence at
        // the known tail. Only rows after that anchor are new live messages.
        if !preferHistorical, let overlap = tail {
            let appended = Array(snapshot.dropFirst(overlap.observedStart + overlap.length))
            if liveEdgeState == false && !appended.isEmpty {
                return ConversationMergeResult(appended: [], prepended: [], unchanged: true, viewport: .historical)
            }
            let anchor = Array(snapshot[overlap.observedStart..<(overlap.observedStart + overlap.length)])
            // Multiple distinct ordered anchors are necessary to establish
            // arrival. A single/repeated text match cannot establish direction.
            let anchorKeys = Set(anchor.map(ChatHistoryMerger.key(for:)))
            let anchorOccurrences = (0...(messages.count - overlap.length)).filter {
                ChatHistoryMerger.sequencesMatch(messages, lhsStart: $0,
                    snapshot, rhsStart: overlap.observedStart, length: overlap.length)
            }.count
            let observedOccurrences = (0...(snapshot.count - overlap.length)).filter {
                ChatHistoryMerger.sequencesMatch(messages, lhsStart: messages.count - overlap.length,
                    snapshot, rhsStart: $0, length: overlap.length)
            }.count
            let reliableOverlap = overlap.length >= 2 && anchorKeys.count >= 2 &&
                anchorOccurrences == 1 && observedOccurrences == 1
            if !appended.isEmpty && !reliableOverlap {
                return ConversationMergeResult(appended: [], prepended: [], unchanged: true, viewport: .uncertain)
            }
            let arrivalConfirmed = reliableOverlap
            // Keep existing occurrence IDs while enriching a matching row with
            // a separator that only became visible on a later capture.
            let existingStart = messages.count - overlap.length
            for offset in 0..<overlap.length where anchorOccurrences == 1 && observedOccurrences == 1 {
                let index = existingStart + offset
                if messages[index].timeSeparatorBefore == nil,
                   let observation = snapshot[overlap.observedStart + offset].observedTimeSeparator {
                    messages[index] = messages[index].withTimeSeparator(observation)
                }
            }
            let merged = messages + appended
            messages = Array(merged.suffix(maximumMessages))
            return ConversationMergeResult(appended: appended, prepended: [],
                                           unchanged: appended.isEmpty, viewport: liveEdgeState == false ? .historical : .liveTail, arrivalConfirmed: arrivalConfirmed && liveEdgeState == true)
        }

        // A suffix of the observed rows matching an internal stored sequence
        // identifies a historical viewport. Only its unanchored older prefix
        // is inserted; rows after an internal match never count as live.
        if let overlap = historical {
            let prefix = Array(snapshot.prefix(overlap.observedStart))
            // An ambiguous sequence cannot prepend rows or enrich timestamps.
            let matches = (0...(messages.count - overlap.length)).filter {
                ChatHistoryMerger.sequencesMatch(messages, lhsStart: $0,
                    snapshot, rhsStart: overlap.observedStart, length: overlap.length)
            }.count
            guard matches == 1, prefix.isEmpty || (overlap.existingStart == 0 && overlap.length >= 2 &&
                Set(snapshot.suffix(overlap.length).map(ChatHistoryMerger.key(for:))).count >= 2) else {
                return ConversationMergeResult(appended: [], prepended: [], unchanged: true, viewport: .uncertain)
            }
            for offset in 0..<overlap.length {
                let index = overlap.existingStart + offset
                if messages[index].timeSeparatorBefore == nil,
                   let observation = snapshot[overlap.observedStart + offset].observedTimeSeparator {
                    messages[index] = messages[index].withTimeSeparator(observation)
                }
            }
            let merged = prefix + messages
            let previousIDs = Set(messages.map(\.localID))
            messages = Array(merged.suffix(maximumMessages))
            let prepended = messages.filter { !previousIDs.contains($0.localID) }
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
