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
