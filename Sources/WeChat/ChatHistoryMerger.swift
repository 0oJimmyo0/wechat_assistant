import Foundation

enum ChatViewportState: String, Equatable, Sendable {
    case liveTail
    case historical
    case uncertain
}

struct ChatViewportClassification: Sendable {
    let state: ChatViewportState
    let tailOverlap: Int
    let historicalOverlap: Int
}

enum ChatHistoryMerger {
    static func messagesCompatible(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
        if key(for: lhs) == key(for: rhs) { return true }
        guard lhs.source == .vision, rhs.source == .vision else { return false }
        let senderCompatible: Bool
        switch (lhs.sender, rhs.sender) {
        case (.me, .other), (.other, .me): senderCompatible = false
        case (.unknown, _), (_, .unknown): senderCompatible = true
        default: senderCompatible = lhs.sender == rhs.sender
        }
        guard senderCompatible else { return false }
        let left = normalizedText(lhs.text)
        let right = normalizedText(rhs.text)
        if left == right { return true }
        guard min(left.count, right.count) >= 5 else { return false }
        return editDistanceAtMostOne(Array(left), Array(right))
    }

    static func key(for message: ChatMessage) -> String {
        // AX text is exact: punctuation, spacing, and case can distinguish
        // real occurrences. OCR alone uses tolerant comparison.
        let normalized = message.source == .accessibility ? message.text : normalizedText(message.text)
        let sender: String
        switch message.sender {
        case .me: sender = "me"
        case .other: sender = "other"
        case .unknown: sender = "unknown"
        }
        // Identity is resolved by ordered overlap, never by this key alone.
        // Repeated messages remain distinct array entries at distinct positions.
        return "\(sender):\(normalized)"
    }

    private static func normalizedText(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let scalars = folded.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) &&
                !CharacterSet.punctuationCharacters.contains($0)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func editDistanceAtMostOne(_ lhs: [Character], _ rhs: [Character]) -> Bool {
        guard abs(lhs.count - rhs.count) <= 1 else { return false }
        var left = 0
        var right = 0
        var edits = 0
        while left < lhs.count && right < rhs.count {
            if lhs[left] == rhs[right] { left += 1; right += 1; continue }
            edits += 1
            guard edits <= 1 else { return false }
            if lhs.count > rhs.count { left += 1 }
            else if rhs.count > lhs.count { right += 1 }
            else { left += 1; right += 1 }
        }
        if left < lhs.count || right < rhs.count { edits += 1 }
        return edits <= 1
    }

    static func sequencesMatch(_ lhs: [ChatMessage], lhsStart: Int,
                               _ rhs: [ChatMessage], rhsStart: Int, length: Int) -> Bool {
        guard length > 0, lhsStart >= 0, rhsStart >= 0,
              lhsStart + length <= lhs.count, rhsStart + length <= rhs.count else { return false }
        for offset in 0..<length where !messagesCompatible(lhs[lhsStart + offset], rhs[rhsStart + offset]) {
            return false
        }
        return true
    }

    static func merge(existing: [ChatMessage], visible: [ChatMessage], limit: Int) -> [ChatMessage] {
        guard !existing.isEmpty else { return Array(visible.suffix(limit)) }

        let historyIDs = existing.map(key(for:))
        let visibleIDs = visible.map(key(for:))
        var refreshedHistory = existing

        // New live messages appear after an overlap with the accumulated tail.
        for length in stride(from: min(historyIDs.count, visibleIDs.count), through: 1, by: -1) {
            let historySuffix = Array(historyIDs.suffix(length))
            for start in (0...(visibleIDs.count - length)).reversed() {
                guard Array(visibleIDs[start..<(start + length)]) == historySuffix else { continue }
                let historyStart = existing.count - length
                for offset in 0..<length {
                    refreshedHistory[historyStart + offset] = visible[start + offset]
                }
                let tail = Array(visible.dropFirst(start + length))
                if !tail.isEmpty {
                    return Array((refreshedHistory + tail).suffix(limit))
                }
                break
            }
        }

        // If the user scrolls to older rows, prepend unseen rows before an
        // overlapping part of the captured timeline.
        for length in stride(from: min(historyIDs.count, visibleIDs.count), through: 1, by: -1) {
            for historyStart in 0...(historyIDs.count - length) {
                let historySegment = Array(historyIDs[historyStart..<(historyStart + length)])
                for visibleStart in 0...(visibleIDs.count - length) {
                    guard Array(visibleIDs[visibleStart..<(visibleStart + length)]) == historySegment else { continue }
                    for offset in 0..<length {
                        refreshedHistory[historyStart + offset] = visible[visibleStart + offset]
                    }
                    if visibleStart > 0 {
                        return Array((Array(visible.prefix(visibleStart)) + refreshedHistory).suffix(limit))
                    }
                    return refreshedHistory
                }
            }
        }
        return refreshedHistory
    }

    static func classify(existing: [ChatMessage], visible: [ChatMessage]) -> ChatViewportClassification {
        guard !existing.isEmpty, !visible.isEmpty else {
            return ChatViewportClassification(state: .uncertain, tailOverlap: 0, historicalOverlap: 0)
        }
        let historyKeys = existing.map(key(for:))
        let visibleKeys = visible.map(key(for:))
        let maxOverlap = min(historyKeys.count, visibleKeys.count)
        for length in stride(from: maxOverlap, through: 1, by: -1) {
            let historyTail = Array(historyKeys.suffix(length))
            for visibleStart in 0...(visibleKeys.count - length) {
                if Array(visibleKeys[visibleStart..<(visibleStart + length)]) == historyTail {
                    return ChatViewportClassification(state: .liveTail, tailOverlap: length, historicalOverlap: 0)
                }
            }
        }
        var bestHistoricalOverlap = 0
        for length in stride(from: maxOverlap, through: 1, by: -1) {
            for historyStart in 0...(historyKeys.count - length) {
                guard historyStart + length < historyKeys.count else { continue }
                let segment = Array(historyKeys[historyStart..<(historyStart + length)])
                for visibleStart in 0...(visibleKeys.count - length) {
                    if Array(visibleKeys[visibleStart..<(visibleStart + length)]) == segment {
                        bestHistoricalOverlap = max(bestHistoricalOverlap, length)
                    }
                }
            }
            if bestHistoricalOverlap > 0 { break }
        }
        return ChatViewportClassification(
            state: bestHistoricalOverlap > 0 ? .historical : .uncertain,
            tailOverlap: 0,
            historicalOverlap: bestHistoricalOverlap
        )
    }

    static func appended(previous: [ChatMessage], merged: [ChatMessage]) -> [ChatMessage] {
        guard !previous.isEmpty else { return [] }
        let previousKeys = previous.map(key(for:))
        let mergedKeys = merged.map(key(for:))
        for length in stride(from: min(previousKeys.count, mergedKeys.count), through: 1, by: -1) {
            let previousSuffix = Array(previousKeys.suffix(length))
            if Array(mergedKeys.prefix(length)) == previousSuffix {
                return Array(merged.dropFirst(length))
            }
        }
        return []
    }
}
