import Foundation

@main
enum ConversationStoreTests {
    static func main() {
        let store = ConversationStore(maximumMessages: 200)

        _ = store.merge(rows("A", "B", "C", "D"), trust: .validated)
        let live = store.merge(rows("C", "D", "E", "F"), trust: .validated)
        expect(texts(store) == ["A", "B", "C", "D", "E", "F"], "ordered tail overlap appends unseen messages")
        expect(live.appended.map(\.text) == ["E", "F"], "only appended rows are new")

        let duplicateStore = ConversationStore()
        _ = duplicateStore.merge(rows("A", "哈哈"), trust: .validated)
        let duplicate = duplicateStore.merge(rows("哈哈", "哈哈", "B"), trust: .validated)
        expect(texts(duplicateStore) == ["A", "哈哈", "哈哈", "B"], "repeated identical messages remain separate")
        expect(duplicate.appended.map(\.text) == ["哈哈", "B"], "duplicate sequence overlap preserves the extra occurrence")

        let historyStore = ConversationStore()
        _ = historyStore.merge(rows("C", "D", "E", "F"), trust: .validated)
        let historical = historyStore.merge(rows("A", "B", "C", "D"), trust: .validated)
        expect(texts(historyStore) == ["A", "B", "C", "D", "E", "F"], "historical overlap prepends older messages")
        expect(historical.prepended.map(\.text) == ["A", "B"], "historical rows are classified as prepended")
        expect(historical.appended.isEmpty, "historical rows are never incoming")

        let visionStore = ConversationStore()
        _ = visionStore.merge(visionRows("C", "D", "E", "F", "G"), trust: .validated)
        _ = visionStore.merge(visionRows("D", "E", "F", "G"), trust: .validated)
        expect(texts(visionStore) == ["C", "D", "E", "F", "G"],
               "a validated polling snapshot preserves accumulated trusted context")
        let olderVision = visionStore.merge(visionRows("A", "B", "C", "D"), trust: .validated)
        expect(texts(visionStore) == ["A", "B", "C", "D", "E", "F", "G"],
               "a historical viewport ending at a tail overlap prepends its older prefix")
        expect(olderVision.viewport == .historical && olderVision.appended.isEmpty,
               "a tail overlap preceded by older rows is never treated as incoming")

        let fuzzyStore = ConversationStore()
        _ = fuzzyStore.merge(visionRows("今天去哪儿玩", "我六点下班"), trust: .validated)
        let fuzzyHistory = fuzzyStore.merge(visionRows("先去吃饭", "今天去哪玩", "我六点下班"), trust: .validated)
        expect(texts(fuzzyStore) == ["先去吃饭", "今天去哪儿玩", "我六点下班"],
               "two adjacent Vision matches tolerate a small OCR variation and prepend history")
        expect(fuzzyHistory.viewport == .historical && fuzzyHistory.appended.isEmpty,
               "fuzzy historical overlap does not produce a live incoming trigger")

        let safeArrival = ConversationStore()
        _ = safeArrival.merge(rows("A", "B", "C"), trust: .validated)
        let stableIDs = safeArrival.messages.map(\.localID)
        let arrival = safeArrival.merge(rows("B", "C", "D"), trust: .validated, liveEdgeState: true)
        expect(arrival.arrivalConfirmed, "a unique pair of distinct ordered anchors confirms arrival")
        expect(Array(safeArrival.messages.prefix(3)).map(\.localID) == stableIDs,
               "overlapping observations preserve occurrence identities")
        expect(!duplicate.arrivalConfirmed, "a single repeated anchor cannot confirm arrival")
        expect(Set(duplicateStore.messages.map(\.id)).count == duplicateStore.messages.count,
               "identical messages have distinct occurrence IDs")

        let repeatedHistory = ConversationStore()
        _ = repeatedHistory.merge(rows("A", "OK", "B", "OK", "C", "OK"), trust: .validated)
        let oldRepeats = repeatedHistory.merge(rows("OK", "B", "OK"), trust: .validated)
        expect(oldRepeats.viewport == .historical && oldRepeats.appended.isEmpty && !oldRepeats.arrivalConfirmed,
               "a stronger historical anchor wins over repeated tail text")
        expect(texts(repeatedHistory) == ["A", "OK", "B", "OK", "C", "OK"],
               "historical repeated messages are not duplicated at the tail")

        let scrolled = ConversationStore()
        _ = scrolled.merge(rows("A", "B", "C"), trust: .validated)
        let scrolledOverlap = scrolled.merge(rows("B", "C", "possibly old"), trust: .validated, liveEdgeState: false)
        expect(scrolledOverlap.viewport == .historical && scrolledOverlap.appended.isEmpty,
               "scrollbar evidence blocks live append while reading older history")
        let uncertainArrival = scrolled.merge(rows("B", "C", "D"), trust: .validated)
        expect(!uncertainArrival.arrivalConfirmed, "missing live-edge evidence disables automatic arrival classification")

        let exactAX = ConversationStore()
        _ = exactAX.merge(rows("Hello!", "Hello"), trust: .validated)
        _ = exactAX.merge(rows("Hello", "hello"), trust: .validated)
        expect(texts(exactAX) == ["Hello!", "Hello", "hello"],
               "case and punctuation distinguish accessibility message content")

        let fullBounded = ConversationStore(maximumMessages: 20)
        _ = fullBounded.merge((10..<30).map { row("\($0)") }, trust: .validated)
        let discardedOlder = fullBounded.merge((0..<15).map { row("\($0)") }, trust: .validated)
        expect(discardedOlder.prepended.isEmpty && discardedOlder.unchanged,
               "history discarded by the memory cap is not reported as retained context")

        let beforeEmpty = texts(historyStore)
        let empty = historyStore.merge([], trust: .validated)
        expect(texts(historyStore) == beforeEmpty && empty.unchanged, "empty observations preserve stored context")

        let bounded = ConversationStore(maximumMessages: 24)
        _ = bounded.merge((0..<40).map { row("\($0)") }, trust: .validated)
        expect(bounded.messages.count == 24 && bounded.messages.first?.text == "16", "store applies its in-memory history limit")

        let gated = ConversationStore()
        let rejected = gated.merge(rows("possibly sidebar text"), trust: ConversationCaptureTrust(
            identityConfirmed: true, transcriptGeometryValidated: false, messagesTrustworthy: true
        ))
        expect(gated.messages.isEmpty && rejected.appended.isEmpty && rejected.viewport == .uncertain,
               "unvalidated geometry cannot write messages into the trusted store")
        let accepted = gated.merge(rows("verified chat bubble"), trust: .validated)
        expect(gated.messages.map(\.text) == ["verified chat bubble"] && !accepted.appended.isEmpty,
               "validated transcript capture enters the trusted store")

        print("All in-memory conversation-store checks passed.")
    }

    private static func row(_ text: String) -> ChatMessage {
        ChatMessage(text: text, sender: .other)
    }

    private static func rows(_ values: String...) -> [ChatMessage] { values.map(row) }
    private static func visionRows(_ values: String...) -> [ChatMessage] {
        values.map { ChatMessage(text: $0, sender: .other, allowsAutomaticAnalysis: false, source: .vision) }
    }
    private static func texts(_ store: ConversationStore) -> [String] { store.messages.map(\.text) }

    private static func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
        guard condition() else {
            fputs("FAILED: \(description)\n", stderr)
            exit(1)
        }
    }
}
