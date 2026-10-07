import Foundation

enum MessageSender: Equatable, Sendable {
    case me
    case other
    case unknown
}

struct ChatMessage: Identifiable, Equatable, Sendable {
    let id: String
    let text: String
    let sender: MessageSender

    var isFromMe: Bool { sender == .me }
    var senderIdentified: Bool { sender != .unknown }

    init(text: String, sender: MessageSender) {
        self.text = text
        self.sender = sender
        let senderKey: String
        switch sender {
        case .me: senderKey = "me"
        case .other: senderKey = "other"
        case .unknown: senderKey = "unknown"
        }
        self.id = "\(senderKey):\(text)"
    }

    init(text: String, isFromMe: Bool, senderIdentified: Bool = true) {
        self.init(text: text, sender: senderIdentified ? (isFromMe ? .me : .other) : .unknown)
    }
}
