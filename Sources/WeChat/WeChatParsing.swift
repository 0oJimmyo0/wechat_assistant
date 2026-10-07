import Foundation

enum WeChatParsing {
    static let chatTitleIdentifier = "big_title_line_h_view"
    static let messageListIdentifier = "chat_message_list"
    static let messageRowIdentifier = "chat_bubble_item_view"
    static let placeholderRowIdentifier = "virtual_cell"

    static func normalizeChatTitle(_ text: String) -> String {
        var normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if let range = normalized.range(of: #"\s*\(\d+\)$"#, options: .regularExpression) {
            normalized.removeSubrange(range)
        }
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isGenericWindowTitle(_ title: String) -> Bool {
        let normalized = title.split(whereSeparator: \.isWhitespace).joined().lowercased()
        return ["wechat", "wechat(chats)", "wechat(contacts)", "wechat(discover)", "微信", "微信(聊天)", "微信(通讯录)"].contains(normalized)
    }

    static func selectedSessionName(from identifier: String, isSelected: Bool) -> String? {
        let prefix = "session_item_"
        guard isSelected, identifier.hasPrefix(prefix) else { return nil }
        let name = normalizeChatTitle(String(identifier.dropFirst(prefix.count)))
        return name.isEmpty ? nil : name
    }

    static func sender(from accessibilityDescription: String) -> MessageSender {
        let value = accessibilityDescription.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if hasPrefixMarker("sent", in: value) || accessibilityDescription.hasPrefix("发出") || accessibilityDescription.hasPrefix("我说") {
            return .me
        }
        if hasPrefixMarker("received", in: value) || accessibilityDescription.hasPrefix("收到") || accessibilityDescription.hasPrefix("对方") {
            return .other
        }
        return .unknown
    }

    static func messageText(identifier: String, title: String?, value: String?) -> String? {
        guard identifier == messageRowIdentifier else { return nil }
        for candidate in [title, value] {
            guard let candidate else { continue }
            let text = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
    }

    static func canAutomaticallyAnalyze(_ messages: [ChatMessage]) -> Bool {
        !messages.isEmpty &&
            messages.allSatisfy { $0.sender != .unknown } &&
            messages.contains { $0.sender == .other }
    }

    static func diagnosticIdentifier(_ identifier: String) -> String {
        if identifier.hasPrefix("session_item_") { return "session_item_<redacted>" }
        let safe = [chatTitleIdentifier, messageListIdentifier, messageRowIdentifier, placeholderRowIdentifier]
        return safe.contains(identifier) ? identifier : (identifier.isEmpty ? "<none>" : "<redacted>")
    }

    static func genericDiagnosticWindowTitle(_ title: String?) -> String {
        guard let title, isGenericWindowTitle(title) else { return "<redacted>" }
        return normalizeChatTitle(title)
    }

    private static func hasPrefixMarker(_ marker: String, in value: String) -> Bool {
        guard value.hasPrefix(marker) else { return false }
        guard value.count > marker.count else { return true }
        let next = value.dropFirst(marker.count).first!
        return next.isWhitespace || next == ":" || next == "：" || next == "·"
    }
}
