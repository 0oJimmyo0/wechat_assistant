import Foundation

@main
enum ConversationCapturePlanTests {
    static func main() {
        expectPlan(axIdentity: true, axMessages: true, identity: .accessibility, messages: .accessibility,
                   "complete AX tree uses one atomic AX snapshot")
        expectPlan(axIdentity: false, axMessages: true, identity: .vision, messages: .accessibility,
                   "AX message list combines with Vision identity")
        expectPlan(axIdentity: false, axMessages: false, identity: .vision, messages: .vision,
                   "collapsed AX tree uses Vision for identity and messages")
        expectPlan(axIdentity: true, axMessages: false, identity: .accessibility, messages: .vision,
                   "AX identity combines with Vision messages")

        let unavailable = ConversationCapturePlan.select(hasAXIdentity: false, hasAXMessages: false,
                                                          hasVisionIdentity: false, hasVisionMessages: true)
        expect(unavailable == nil, "capture requires an identity source")

        var baseline = VisionMessageBaseline()
        baseline.record(source: .vision, hasMessages: false, fingerprint: "empty-frame", frameUnchanged: false)
        expect(!baseline.isValid && !baseline.shouldSkipOCR(frameUnchanged: true),
               "empty initial OCR cannot establish an unchanged baseline")
        baseline.record(source: .vision, hasMessages: true, fingerprint: "message-frame", frameUnchanged: false)
        expect(baseline.isValid && baseline.shouldSkipOCR(frameUnchanged: true),
               "a successful message capture enables unchanged-frame skipping")
        baseline.record(source: .vision, hasMessages: false, fingerprint: "new-empty-frame", frameUnchanged: false)
        expect(!baseline.isValid && !baseline.shouldSkipOCR(frameUnchanged: true),
               "an empty changed OCR frame invalidates the previous baseline")
        baseline.record(source: .vision, hasMessages: true, fingerprint: "message-frame", frameUnchanged: false)
        baseline.record(source: .accessibility, hasMessages: true, fingerprint: nil, frameUnchanged: false)
        expect(!baseline.isValid, "AX message capture does not reuse a Vision fingerprint")
        print("All conversation capture source-selection checks passed.")
    }

    private static func expectPlan(axIdentity: Bool, axMessages: Bool,
                                   identity: ConversationCaptureSource, messages: ConversationCaptureSource,
                                   _ description: String) {
        let plan = ConversationCapturePlan.select(hasAXIdentity: axIdentity, hasAXMessages: axMessages)
        expect(plan == ConversationCapturePlan(identity: identity, messages: messages), description)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
        guard condition() else {
            fputs("FAILED: \(description)\n", stderr)
            exit(1)
        }
    }
}
