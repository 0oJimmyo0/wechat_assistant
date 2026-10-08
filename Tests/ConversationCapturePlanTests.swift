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

        let visionCached = ConversationCapturePlan(identity: .vision, messages: .vision)
        let recoveredIdentity = ConversationCapturePlan.recover(
            cached: visionCached, hasAXIdentity: true, hasAXMessages: false)
        expect(recoveredIdentity.identity == .accessibility && recoveredIdentity.messages == .vision,
               "AX identity can recover from an earlier Vision-only cached plan")
        let stillPending = ConversationCapturePlan.recover(
            cached: visionCached, hasAXIdentity: false, hasAXMessages: false)
        expect(stillPending == visionCached, "unavailable AX title remains a Vision candidate, not a guessed contact")
        let lostAX = ConversationCapturePlan.recover(
            cached: ConversationCapturePlan(identity: .accessibility, messages: .accessibility),
            hasAXIdentity: false, hasAXMessages: false)
        expect(lostAX.identity == .vision && lostAX.messages == .vision,
               "lost cached AX evidence safely returns to Vision rather than trusting stale identity")

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
        let dividerCandidate = VisionLayoutRegions.geometry(
            leftX: 0.30, headerBottomY: 0.90, composerTopY: 0.18,
            source: .visualDividerCandidate, confidence: 0.55
        )
        let acceptedTitle = CGRect(x: 0.34, y: 0.93, width: 0.16, height: 0.025)
        let incomingBubble = CGRect(x: 0.32, y: 0.54, width: 0.22, height: 0.035)
        let outgoingBubble = CGRect(x: 0.72, y: 0.38, width: 0.20, height: 0.035)
        expect(!dividerCandidate.validatingVisualEvidence(titleBounds: nil,
                                                          messageBounds: [incomingBubble, outgoingBubble]).isValidated,
               "a strong-looking vertical line alone does not validate pane geometry")
        expect(!dividerCandidate.validatingVisualEvidence(titleBounds: acceptedTitle,
                                                          messageBounds: [CGRect(x: 0.56, y: 0.45, width: 0.10, height: 0.03)]).isValidated,
               "pane validation rejects text that does not align like a bubble")
        expect(!dividerCandidate.validatingVisualEvidence(titleBounds: acceptedTitle,
            messageBounds: [incomingBubble, outgoingBubble]).isValidated,
            "title and aligned bubbles alone cannot prove the composer's exclusion boundary")
        var failedAttempt = CaptureAttemptDiagnostics()
        failedAttempt.hasRun = true
        failedAttempt.durationMilliseconds = 72
        failedAttempt.source = .vision
        failedAttempt.rejectionReason = "transcript geometry unverified"
        expect(!failedAttempt.summary.contains("not run") && failedAttempt.summary.contains("72 ms"),
               "failed and unverified attempts still report source, duration, and rejection")

        let validatedDivider = dividerCandidate.validatingVisualEvidence(
            titleBounds: acceptedTitle, messageBounds: [incomingBubble, outgoingBubble],
            composerBounds: CGRect(x: 0.30, y: 0, width: 0.70, height: 0.17)
        )
        expect(validatedDivider.isValidated && validatedDivider.source == .visualDivider,
               "visual pane validation requires both an in-pane title and aligned transcript bubbles")
        let measuredWindow = CGRect(x: 127, y: 73, width: 1269, height: 788)
        let measuredViewport = CGRect(x: 447, y: 164, width: 950, height: 486)
        // Actual AX frames can exceed the outer frame by one point through rounding.
        let measuredComposer = CGRect(x: 453, y: 726, width: 938, height: 129)
        let exactGeometry = VisionLayoutRegions.accessibilityTranscript(viewport: measuredViewport,
            composer: measuredComposer, window: measuredWindow, source: .accessibilityScrollArea)
        expect(exactGeometry?.isValidated == true, "measured transcript plus aligned composer validates geometry")
        expect(abs((exactGeometry?.messageRegion.minY ?? 0) - (1 - 577.0 / 788)) < 0.001,
               "AX top-left viewport maps to Vision bottom-left exactly")
        expect(abs((exactGeometry?.headerRegion.minY ?? 0) - (1 - 91.0 / 788)) < 0.001,
               "header boundary comes from the transcript frame rather than calibration")
        expect(VisionLayoutRegions.accessibilityTranscript(viewport: CGRect(x: 187, y: 133, width: 261, height: 728),
            composer: measuredComposer, window: measuredWindow, source: .accessibilityScrollArea) == nil,
               "sidebar scroll area cannot become transcript geometry")
        expect(VisionLayoutRegions.accessibilityTranscript(viewport: measuredViewport,
            composer: nil, window: measuredWindow, source: .accessibilityScrollArea) == nil,
               "unidentified scroll area needs independent composer evidence")

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

        expect(ConversationAcquisitionState.resolve(identityConfirmed: true, transcriptGeometryValidated: true,
                                                   trustworthyMessages: true) == .ready,
               "ready requires identity, validated geometry, and trustworthy messages")
        let unverifiedGeometryState = ConversationAcquisitionState.resolve(
            identityConfirmed: true, transcriptGeometryValidated: false, trustworthyMessages: true
        )
        expect(unverifiedGeometryState == .geometryUnverified && !unverifiedGeometryState.permitsAutomaticAnalysis,
               "identity-confirmed messages with unvalidated pane geometry cannot become ready")
        expect(HistoricalCaptureObservation.resolve(geometryValidated: true, viewportChanged: false,
                                                    recognizedRowCount: 0, sequenceOverlap: false,
                                                    olderRowsAdded: false) == .noVisualMovement,
               "history loader distinguishes a scroll that did not move the viewport")
        expect(HistoricalCaptureObservation.resolve(geometryValidated: true, viewportChanged: true,
                                                    recognizedRowCount: 0, sequenceOverlap: false,
                                                    olderRowsAdded: false) == .rowsUnrecognized,
               "history loader distinguishes movement with unreadable rows")
        expect(HistoricalCaptureObservation.resolve(geometryValidated: true, viewportChanged: true,
                                                    recognizedRowCount: 4, sequenceOverlap: false,
                                                    olderRowsAdded: false) == .noSequenceOverlap,
               "history loader distinguishes recognized rows without an overlap anchor")
        expect(ConversationAcquisitionState.resolve(identityConfirmed: true, transcriptGeometryValidated: true,
                                                   trustworthyMessages: false) == .identityConfirmed,
               "identity remains confirmed while message capture retries")
        expect(ConversationAcquisitionState.resolve(identityConfirmed: false, transcriptGeometryValidated: true,
                                                   trustworthyMessages: true) == .messagesPending,
               "messages remain locally available while identity retries")
        let pendingState = ConversationAcquisitionState.resolve(identityConfirmed: false,
                                                                  transcriptGeometryValidated: true,
                                                                  trustworthyMessages: true)
        expect(!pendingState.permitsAutomaticAnalysis,
               "automatic analysis is disabled until identity is confirmed")
        expect(!ConversationAcquisitionState.resolve(identityConfirmed: false, transcriptGeometryValidated: false,
                                                      trustworthyMessages: false)
                    .permitsAutomaticAnalysis,
               "no identity or messages cannot enter automatic analysis")

        var baseline = VisionMessageBaseline()
        baseline.record(source: .vision, hasMessages: false, fingerprint: "empty-frame", frameUnchanged: false,
                        geometryValidated: true, extractionTrustworthy: false)
        expect(!baseline.isValid && !baseline.shouldSkipOCR(frameUnchanged: true),
               "empty initial OCR cannot establish an unchanged baseline")
        baseline.record(source: .vision, hasMessages: true, fingerprint: "message-frame", frameUnchanged: false,
                        geometryValidated: true, extractionTrustworthy: true)
        expect(baseline.isValid && baseline.shouldSkipOCR(frameUnchanged: true),
               "a successful message capture enables unchanged-frame skipping")
        baseline.record(source: .vision, hasMessages: true, fingerprint: "unverified-frame", frameUnchanged: false,
                        geometryValidated: false, extractionTrustworthy: true)
        expect(baseline.fingerprint == "message-frame" && baseline.shouldSkipOCR(frameUnchanged: true),
               "invalid geometry cannot replace a trusted message fingerprint")
        baseline.record(source: .vision, hasMessages: false, fingerprint: "new-empty-frame", frameUnchanged: false,
                        geometryValidated: true, extractionTrustworthy: false)
        expect(baseline.fingerprint == "message-frame",
               "unrecognized message rows do not replace the trusted fingerprint")
        baseline.record(source: .accessibility, hasMessages: true, fingerprint: nil, frameUnchanged: false,
                        geometryValidated: true, extractionTrustworthy: true)
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
