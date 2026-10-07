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

    static func conversationIdentityKey(_ text: String) -> String {
        normalizeChatTitle(text)
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    static func isPlausibleChatText(_ text: String, confidence: Float) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, confidence >= 0.45 else { return false }
        let scalars = Array(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        guard !scalars.isEmpty else { return false }
        let isCJK: (Unicode.Scalar) -> Bool = { scalar in
            (0x3400...0x9FFF).contains(Int(scalar.value)) ||
                (0xF900...0xFAFF).contains(Int(scalar.value)) ||
                (0x20000...0x3134F).contains(Int(scalar.value))
        }
        if scalars.contains(where: isCJK) { return true }

        let meaningfulCount = scalars.filter { CharacterSet.alphanumerics.contains($0) }.count
        let emojiCount = scalars.filter { $0.value >= 0x1F000 && $0.value <= 0x1FAFF }.count
        if meaningfulCount == 0 { return emojiCount > 0 }
        let contentRatio = Double(meaningfulCount + emojiCount) / Double(scalars.count)
        return contentRatio >= 0.72 && (confidence >= 0.60 || contentRatio >= 0.85)
    }

    static func titleMatchesMessage(_ title: String, message: String) -> Bool {
        let normalizedTitle = normalizedComparableText(title)
        let normalizedMessage = normalizedComparableText(message)
        guard !normalizedTitle.isEmpty, !normalizedMessage.isEmpty else { return false }
        if normalizedTitle == normalizedMessage { return true }
        if normalizedTitle.count >= 3 && normalizedMessage.contains(normalizedTitle) { return true }
        return min(normalizedTitle.count, normalizedMessage.count) >= 4 &&
            editDistance(normalizedTitle, normalizedMessage) <= 1
    }

    private static func normalizedComparableText(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) &&
                !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.symbols.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs), right = Array(rhs)
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = Array(repeating: 0, count: right.count + 1)
            current[0] = leftIndex + 1
            for (rightIndex, rightCharacter) in right.enumerated() {
                current[rightIndex + 1] = min(
                    previous[rightIndex + 1] + 1,
                    current[rightIndex] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[right.count]
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
            messages.allSatisfy { $0.sender != .unknown && $0.allowsAutomaticAnalysis } &&
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
