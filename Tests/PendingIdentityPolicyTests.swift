import Foundation
@main enum PendingIdentityPolicyTests {
    static func main() {
        let validated = [ChatMessage(text: "Public validated fixture", sender: .other)]
        let candidates = (0..<60).map { ChatMessage(text: "Public candidate \($0)", sender: .unknown) }
        for pending in [candidates, Array(candidates.reversed()), []] {
            let displayed = PendingIdentityPolicy.displayedMessages(validated: validated,
                pending: pending, hasLockedContact: true)
            expect(displayed == validated, "transient missing identity preserves validated text, ordering and occurrence IDs")
        }
        expect(PendingIdentityPolicy.displayedMessages(validated: [ChatMessage](),
            pending: candidates, hasLockedContact: true).isEmpty,
            "locked conversation without trusted rows cannot display unverified candidates")
        expect(PendingIdentityPolicy.displayedMessages(validated: [ChatMessage](),
            pending: candidates, hasLockedContact: false) == Array(candidates.suffix(50)),
            "initial pending presentation is bounded and does not change trusted storage")
        print("All pending identity history-preservation checks passed.")
    }
    static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        if !condition() { fputs("FAILED: \(label)\n",stderr); exit(1) }
    }
}
