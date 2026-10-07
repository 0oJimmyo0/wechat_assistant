import Foundation

@main
enum ConversationStoreTests {
    static func main() {
        let store = ConversationStore(maximumMessages: 200)

        _ = store.merge(rows("A", "B", "C", "D"))
        let live = store.merge(rows("C", "D", "E", "F"))
        expect(texts(store) == ["A", "B", "C", "D", "E", "F"], "ordered tail overlap appends unseen messages")
        expect(live.appended.map(\.text) == ["E", "F"], "only appended rows are new")

        let duplicateStore = ConversationStore()
        _ = duplicateStore.merge(rows("A", "哈哈"))
        let duplicate = duplicateStore.merge(rows("哈哈", "哈哈", "B"))
        expect(texts(duplicateStore) == ["A", "哈哈", "哈哈", "B"], "repeated identical messages remain separate")
        expect(duplicate.appended.map(\.text) == ["哈哈", "B"], "duplicate sequence overlap preserves the extra occurrence")

        let historyStore = ConversationStore()
        _ = historyStore.merge(rows("C", "D", "E", "F"))
        let historical = historyStore.merge(rows("A", "B", "C", "D"))
        expect(texts(historyStore) == ["A", "B", "C", "D", "E", "F"], "historical overlap prepends older messages")
        expect(historical.prepended.map(\.text) == ["A", "B"], "historical rows are classified as prepended")
        expect(historical.appended.isEmpty, "historical rows are never incoming")

        let visionStore = ConversationStore()
        _ = visionStore.merge(visionRows("C", "D", "E", "F", "G"))
        let olderVision = visionStore.merge(visionRows("A", "B", "C", "D"))
        expect(texts(visionStore) == ["A", "B", "C", "D", "E", "F", "G"],
               "a historical viewport ending at a tail overlap prepends its older prefix")
        expect(olderVision.viewport == .historical && olderVision.appended.isEmpty,
               "a tail overlap preceded by older rows is never treated as incoming")

        let fuzzyStore = ConversationStore()
        _ = fuzzyStore.merge(visionRows("今天去哪儿玩", "我六点下班"))
        let fuzzyHistory = fuzzyStore.merge(visionRows("先去吃饭", "今天去哪玩", "我六点下班"))
        expect(texts(fuzzyStore) == ["先去吃饭", "今天去哪儿玩", "我六点下班"],
               "two adjacent Vision matches tolerate a small OCR variation and prepend history")
        expect(fuzzyHistory.viewport == .historical && fuzzyHistory.appended.isEmpty,
               "fuzzy historical overlap does not produce a live incoming trigger")

        let beforeEmpty = texts(historyStore)
        let empty = historyStore.merge([])
        expect(texts(historyStore) == beforeEmpty && empty.unchanged, "empty observations preserve stored context")

        let bounded = ConversationStore(maximumMessages: 24)
        _ = bounded.merge((0..<40).map { row("\($0)") })
        expect(bounded.messages.count == 24 && bounded.messages.first?.text == "16", "store applies its in-memory history limit")

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
