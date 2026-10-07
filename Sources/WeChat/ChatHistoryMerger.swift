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
    static func key(for message: ChatMessage) -> String {
        let folded = message.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let scalars = folded.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) &&
                !CharacterSet.punctuationCharacters.contains($0)
        }
        let normalized = String(String.UnicodeScalarView(scalars))
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
