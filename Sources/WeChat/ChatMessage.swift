import Foundation

enum MessageSender: Equatable, Sendable {
    case me
    case other
    case unknown
}

enum MessageSource: String, Codable, Sendable {
    case accessibility
    case vision
}

struct ChatMessage: Identifiable, Equatable, Sendable {
    let localID: UUID
    let id: String
    let text: String
    let sender: MessageSender
    let allowsAutomaticAnalysis: Bool
    let firstSeenAt: Date
    let source: MessageSource
    let confidence: Float

    var isFromMe: Bool { sender == .me }
    var senderIdentified: Bool { sender != .unknown }

    init(text: String, sender: MessageSender, allowsAutomaticAnalysis: Bool = true, id: String? = nil,
         localID: UUID = UUID(), firstSeenAt: Date = Date(), source: MessageSource = .accessibility,
         confidence: Float = 1) {
        self.localID = localID
        self.id = id ?? localID.uuidString
        self.text = text
        self.sender = sender
        self.allowsAutomaticAnalysis = allowsAutomaticAnalysis
        self.firstSeenAt = firstSeenAt
        self.source = source
        self.confidence = confidence
    }

    init(text: String, isFromMe: Bool, senderIdentified: Bool = true, allowsAutomaticAnalysis: Bool = true) {
        self.init(
            text: text,
            sender: senderIdentified ? (isFromMe ? .me : .other) : .unknown,
            allowsAutomaticAnalysis: allowsAutomaticAnalysis
        )
    }
}
