import Foundation
@main enum HistoryRefinementTests {
    static func main() {
        func rows(_ range: Range<Int>) -> [ChatMessage] {
            range.map { ChatMessage(text: "Public numbered message \($0)", sender: $0 % 2 == 0 ? .me : .other,
                timeSeparatorBefore: $0 % 20 == 0 ? "Today 10:30" : nil) }
        }
        let store = ConversationStore(maximumMessages: 200)
        _ = store.merge(rows(80..<100),trust: .validated,liveEdgeState: true)
        let initial = store.messages
        for start in [60,40,20] {
            let before = store.messages
            let result = store.merge(rows(start..<(start+25)),trust: .validated,liveEdgeState: false)
            expect(result.prepended.count == 20 && result.appended.isEmpty && !result.arrivalConfirmed,"each history batch prepends twenty without arrivals")
            expect(store.messages.suffix(before.count).map(\.localID) == before.map(\.localID),"historical backfill preserves previously retained occurrence IDs")
        }
        expect(store.messages.map(\.text) == rows(20..<100).map(\.text),"20/40/60 older messages maintain verified chronological sequence")
        let beforeReturn = store.messages
        _ = store.merge(rows(80..<100),trust: .validated,liveEdgeState: true)
        expect(store.messages == beforeReturn,"return to latest keeps all loaded history and metadata")
        expect(store.messages.suffix(initial.count).map(\.localID) == initial.map(\.localID),"latest identities survive three history loads")
        for _ in 0..<3 { _ = store.merge(rows(80..<100),trust: .validated,liveEdgeState: true) }
        expect(store.messages == beforeReturn,"three Refresh operations preserve enriched time events and history")
        for start in stride(from: 95,to: 285,by: 5) { _ = store.merge(rows(start..<(start+10)),trust: .validated,liveEdgeState: true) }
        expect(store.messages.count <= 200 && store.timeSeparatorEvents.allSatisfy { event in store.messages.contains { $0.localID == event.beforeMessageID } },"memory eviction bounds messages and timestamp events together")
        store.clear()
        expect(store.messages.isEmpty && store.timeSeparatorEvents.isEmpty,"deactivation clears all message and separator data")
        print("All incremental history, cap, and lifecycle checks passed.")
    }
    static func expect(_ condition: @autoclosure () -> Bool, _ label: String) { if !condition() { fputs("FAILED: \(label)\n",stderr); exit(1) } }
}
