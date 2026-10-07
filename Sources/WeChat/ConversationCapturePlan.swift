import Foundation

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
