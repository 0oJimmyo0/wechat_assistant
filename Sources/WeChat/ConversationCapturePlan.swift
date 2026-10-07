import Foundation
import CoreGraphics

/// Normalized rectangles are always relative to the complete WeChat window.
/// Title and message pane geometry are intentionally independent.
enum VisionLayoutRegions {
    static func messagePane(leftX: CGFloat, verticalRegion: CGRect) -> CGRect {
        let paneLeft = min(0.70, max(0.01, leftX))
        let availableWidth = 1 - paneLeft
        let x = paneLeft + verticalRegion.minX * availableWidth
        let width = verticalRegion.width * availableWidth
        return CGRect(x: x, y: verticalRegion.minY, width: width, height: verticalRegion.height)
    }

    static func windowBounds(_ localBounds: CGRect, in region: CGRect) -> CGRect {
        CGRect(x: region.minX + localBounds.minX * region.width,
               y: region.minY + localBounds.minY * region.height,
               width: localBounds.width * region.width,
               height: localBounds.height * region.height)
    }

    static func geometry(leftX: CGFloat, headerBottomY: CGFloat, composerTopY: CGFloat,
                         source: ConversationPaneGeometrySource, confidence: Float) -> ConversationPaneGeometry {
        let safeLeft = min(0.70, max(0.01, leftX))
        let header = CGRect(x: safeLeft, y: headerBottomY, width: 1 - safeLeft,
                            height: 1 - headerBottomY)
        let transcript = CGRect(x: 0.01, y: composerTopY, width: 0.98,
                                height: headerBottomY - composerTopY - 0.02)
        let messages = messagePane(leftX: safeLeft, verticalRegion: transcript)
        return ConversationPaneGeometry(leftX: safeLeft, headerRegion: header,
                                        messageRegion: messages, source: source,
                                        confidence: confidence)
    }
}

enum ConversationPaneGeometrySource: String, Sendable {
    case accessibilityMessageList
    case accessibilityComposer
    case accessibilityScrollArea
    case visualDividerCandidate
    case visualDivider
    case detachedWindow
    case configuredFallback
}

struct ConversationPaneGeometry: Sendable, Equatable {
    let leftX: CGFloat
    let headerRegion: CGRect
    let messageRegion: CGRect
    let source: ConversationPaneGeometrySource
    let confidence: Float

    var isValidated: Bool {
        confidence >= 0.70 && source != .configuredFallback && source != .visualDividerCandidate
    }

    func scrollTarget(in windowFrame: CGRect) -> CGPoint {
        CGPoint(x: windowFrame.minX + windowFrame.width * messageRegion.midX,
                y: windowFrame.minY + windowFrame.height * (1 - messageRegion.midY))
    }

    func validatingVisualEvidence(titleBounds: CGRect?, messageBounds: [CGRect]) -> ConversationPaneGeometry {
        guard source == .visualDividerCandidate,
              let title = titleBounds,
              title.minX >= leftX,
              (title.midX - leftX) / max(0.01, 1 - leftX) <= 0.70,
              !messageBounds.isEmpty else { return self }
        let aligned = messageBounds.filter { bounds in
            bounds.minX >= leftX && bounds.maxX <= 1.001 &&
                bounds.minY >= messageRegion.minY && bounds.maxY <= messageRegion.maxY &&
                (bounds.minX - messageRegion.minX <= 0.24 ||
                 messageRegion.maxX - bounds.maxX <= 0.24)
        }
        guard CGFloat(aligned.count) / CGFloat(messageBounds.count) >= 0.75 else { return self }
        return VisionLayoutRegions.geometry(
            leftX: leftX, headerBottomY: headerRegion.minY,
            composerTopY: messageRegion.minY,
            source: .visualDivider, confidence: 0.78
        )
    }
}

struct ConversationCaptureTrust: Equatable, Sendable {
    let identityConfirmed: Bool
    let transcriptGeometryValidated: Bool
    let messagesTrustworthy: Bool

    var mayEnterTrustedStore: Bool {
        identityConfirmed && transcriptGeometryValidated && messagesTrustworthy
    }

    static let validated = ConversationCaptureTrust(identityConfirmed: true,
                                                    transcriptGeometryValidated: true,
                                                    messagesTrustworthy: true)
}

enum ConversationAcquisitionState: String {
    case inactive
    case identifying
    case identityConfirmed
    case messagesPending
    case geometryUnverified
    case ready
    case temporarilyUnavailable
    case conversationChanged

    static func resolve(identityConfirmed: Bool, transcriptGeometryValidated: Bool,
                        trustworthyMessages: Bool) -> ConversationAcquisitionState {
        if identityConfirmed && !transcriptGeometryValidated { return .geometryUnverified }
        let trust = ConversationCaptureTrust(identityConfirmed: identityConfirmed,
                                             transcriptGeometryValidated: transcriptGeometryValidated,
                                             messagesTrustworthy: trustworthyMessages)
        if trust.mayEnterTrustedStore { return .ready }
        if identityConfirmed { return .identityConfirmed }
        if trustworthyMessages { return .messagesPending }
        return .identifying
    }

    var permitsAutomaticAnalysis: Bool { self == .ready }
}

enum HistoricalCaptureObservation: String, Sendable {
    case notObserved = "not observed"
    case noVisualMovement = "no visual movement after scroll"
    case rowsUnrecognized = "viewport changed but message rows were unrecognized"
    case geometryUnverified = "viewport geometry is unverified"
    case noSequenceOverlap = "rows recognized but no history sequence overlap"
    case overlapWithoutOlderRows = "overlap found; no unseen older rows"
    case olderRowsAdded = "older rows added"

    static func resolve(geometryValidated: Bool, viewportChanged: Bool,
                        recognizedRowCount: Int, sequenceOverlap: Bool,
                        olderRowsAdded: Bool) -> HistoricalCaptureObservation {
        guard geometryValidated else { return .geometryUnverified }
        guard viewportChanged else { return .noVisualMovement }
        guard recognizedRowCount > 0 else { return .rowsUnrecognized }
        guard sequenceOverlap else { return .noSequenceOverlap }
        return olderRowsAdded ? .olderRowsAdded : .overlapWithoutOlderRows
    }
}

enum ConversationCaptureSource: String, Sendable {
    case accessibility = "AX"
    case vision = "Vision"
}

struct ConversationCapturePlan: Equatable, Sendable {
    let identity: ConversationCaptureSource
    let messages: ConversationCaptureSource

    static func select(
        hasAXIdentity: Bool,
        hasAXMessages: Bool,
        hasVisionIdentity: Bool = true,
        hasVisionMessages: Bool = true
    ) -> ConversationCapturePlan? {
        if hasAXIdentity && hasAXMessages {
            return ConversationCapturePlan(identity: .accessibility, messages: .accessibility)
        }
        let identity: ConversationCaptureSource
        if hasAXIdentity { identity = .accessibility }
        else if hasVisionIdentity { identity = .vision }
        else { return nil }

        let messages: ConversationCaptureSource
        if hasAXMessages { messages = .accessibility }
        else if hasVisionMessages { messages = .vision }
        else { return nil }

        return ConversationCapturePlan(identity: identity, messages: messages)
    }
}

struct VisionMessageBaseline: Equatable {
    private(set) var fingerprint: String?

    var isValid: Bool { fingerprint != nil }

    func shouldSkipOCR(frameUnchanged: Bool) -> Bool {
        isValid && frameUnchanged
    }

    mutating func record(source: ConversationCaptureSource, hasMessages: Bool,
                         fingerprint: String?, frameUnchanged: Bool,
                         geometryValidated: Bool, extractionTrustworthy: Bool) {
        guard geometryValidated, extractionTrustworthy else { return }
        guard source == .vision else {
            reset()
            return
        }
        if frameUnchanged && isValid { return }
        guard hasMessages, let fingerprint else {
            reset()
            return
        }
        self.fingerprint = fingerprint
    }

    mutating func reset() { fingerprint = nil }
}
