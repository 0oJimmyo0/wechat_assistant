import Foundation

struct ChatMessage: Identifiable, Equatable {
    let id: String
    let text: String
    let isFromMe: Bool

    init(text: String, isFromMe: Bool) {
        self.text = text
        self.isFromMe = isFromMe
        self.id = "\(isFromMe ? "me" : "them"):\(text)"
    }
}
