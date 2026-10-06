import Foundation

struct ChatMessage: Identifiable, Equatable {
    let id: String
    let text: String
    let isFromMe: Bool
    let senderIdentified: Bool

    init(text: String, isFromMe: Bool, senderIdentified: Bool = true) {
        self.text = text
        self.isFromMe = isFromMe
        self.senderIdentified = senderIdentified
        let sender = senderIdentified ? (isFromMe ? "me" : "them") : "unknown"
        self.id = "\(sender):\(text)"
    }
}
