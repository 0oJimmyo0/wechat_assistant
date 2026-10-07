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

        let mainWindowGeometry = VisionLayoutRegions.geometry(
            leftX: 0.38, headerBottomY: 0.90, composerTopY: 0.16,
            source: .accessibilityComposer, confidence: 0.90
        )
        expect(mainWindowGeometry.headerRegion.minX == 0.38 && mainWindowGeometry.messageRegion.minX >= 0.38,
               "main-window title and message ROIs exclude the conversation sidebar")
        let titleBounds = VisionLayoutRegions.windowBounds(
            CGRect(x: 0.04, y: 0.30, width: 0.20, height: 0.18), in: mainWindowGeometry.headerRegion
        )
        expect(titleBounds.minX >= 0.38, "title OCR bounds remain in full-window coordinates inside the pane")
        let detachedGeometry = VisionLayoutRegions.geometry(
            leftX: 0.01, headerBottomY: 0.90, composerTopY: 0.16,
            source: .detachedWindow, confidence: 0.95
        )
        expect(detachedGeometry.headerRegion.minX == 0.01 && detachedGeometry.messageRegion.minX >= 0.01,
               "detached chat geometry retains its nearly full-width pane")
        let configuredGeometry = VisionLayoutRegions.geometry(
            leftX: 0.28, headerBottomY: 0.90, composerTopY: 0.16,
            source: .configuredFallback, confidence: 0.40
        )
        expect(!configuredGeometry.isValidated && mainWindowGeometry.isValidated,
               "only strong AX or visual geometry is cached for a monitoring session")
        let scroll = mainWindowGeometry.scrollTarget(in: CGRect(x: 100, y: 50, width: 1000, height: 800))
        expect(abs(scroll.x - (100 + 1000 * mainWindowGeometry.messageRegion.midX)) < 0.01,
               "scroll target uses the resolved pane center")
        let messageVerticalROI = CGRect(x: 0.01, y: 0.18, width: 0.98, height: 0.70)
        let wideMessages = VisionLayoutRegions.messagePane(leftX: 0.01, verticalRegion: messageVerticalROI)
        let sidebarMessages = VisionLayoutRegions.messagePane(leftX: 0.28, verticalRegion: messageVerticalROI)
        expect(wideMessages.minX < 0.03 && wideMessages.width > 0.95,
               "wide layout selects the nearly full-width message pane")
        expect(sidebarMessages.minX >= 0.28 && sidebarMessages.width < wideMessages.width,
               "sidebar layout keeps messages to the right of the sidebar")
        let narrowPane = VisionLayoutRegions.messagePane(leftX: 0.68, verticalRegion: messageVerticalROI)
        expect(narrowPane.minX >= 0.68,
               "narrow-pane geometry never clamps leftward into the conversation list")

        expect(ConversationAcquisitionState.resolve(identityConfirmed: true, hasMessages: true) == .ready,
               "confirmed identity plus captured messages is ready")
        expect(ConversationAcquisitionState.resolve(identityConfirmed: true, hasMessages: false) == .identityConfirmed,
               "identity remains confirmed while message capture retries")
        expect(ConversationAcquisitionState.resolve(identityConfirmed: false, hasMessages: true) == .messagesPending,
               "messages remain locally available while identity retries")
        let pendingState = ConversationAcquisitionState.resolve(identityConfirmed: false, hasMessages: true)
        expect(!pendingState.permitsAutomaticAnalysis,
               "automatic analysis is disabled until identity is confirmed")
        expect(!ConversationAcquisitionState.resolve(identityConfirmed: false, hasMessages: false)
                    .permitsAutomaticAnalysis,
               "no identity or messages cannot enter automatic analysis")

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
