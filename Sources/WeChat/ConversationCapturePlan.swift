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
        confidence >= 0.70 && source != .configuredFallback
    }

    func scrollTarget(in windowFrame: CGRect) -> CGPoint {
        CGPoint(x: windowFrame.minX + windowFrame.width * messageRegion.midX,
                y: windowFrame.minY + windowFrame.height * (1 - messageRegion.midY))
    }
}

enum ConversationAcquisitionState: String {
    case inactive
    case identifying
    case identityConfirmed
    case messagesPending
    case ready
    case temporarilyUnavailable
    case conversationChanged

    static func resolve(identityConfirmed: Bool, hasMessages: Bool) -> ConversationAcquisitionState {
        if identityConfirmed && hasMessages { return .ready }
        if identityConfirmed { return .identityConfirmed }
        if hasMessages { return .messagesPending }
        return .identifying
    }

    var permitsAutomaticAnalysis: Bool { self == .ready }
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
                         fingerprint: String?, frameUnchanged: Bool) {
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
