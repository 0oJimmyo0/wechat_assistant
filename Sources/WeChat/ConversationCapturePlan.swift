import Foundation
import CoreGraphics

/// Normalized rectangles are always relative to the complete WeChat window.
/// Title and message pane geometry are intentionally independent.
enum VisionLayoutRegions {
    static func titleSearch(bottomY: CGFloat) -> CGRect {
        CGRect(x: 0.005, y: bottomY, width: 0.99, height: 1 - bottomY)
    }

    static func messagePane(leftX: CGFloat, verticalRegion: CGRect) -> CGRect {
        let paneLeft = min(0.60, max(0.01, leftX))
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
