import Foundation
import CoreGraphics

enum WeChatParsing {
    static let chatTitleIdentifier = "big_title_line_h_view"
    static let messageListIdentifier = "chat_message_list"
    static let messageRowIdentifier = "chat_bubble_item_view"
    static let placeholderRowIdentifier = "virtual_cell"

    /// Only literal stand-alone time/date labels qualify. Never infer a message
    /// send time from the moment the assistant read it.
    private static let timeLabelPattern: NSRegularExpression = {
        let clock = #"(?:(?:上午|下午|早上|晚上)\s*)?(?:[01]?\d|2[0-3]):[0-5]\d(?:\s*(?:AM|PM|上午|下午))?"#
        let day = #"(?:今天|昨天|前天|Today|Yesterday|星期[一二三四五六日天]|周[一二三四五六日天]|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday|Mon|Tue|Wed|Thu|Fri|Sat|Sun)"#
        let date = #"(?:\d{4}[-/年](?:0?[1-9]|1[0-2])[-/月](?:0?[1-9]|[12]\d|3[01])日?|(?:0?[1-9]|1[0-2])月(?:0?[1-9]|[12]\d|3[01])日|(?:0?[1-9]|1[0-2])/(?:0?[1-9]|[12]\d|3[01])(?:/\d{4})?|(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\.?\s+(?:0?[1-9]|[12]\d|3[01])(?:,?\s*\d{4})?)"#
        return try! NSRegularExpression(pattern: "^(?:" + clock + "|(?:" + day + "|" + date + ")(?:[ ,，]+" + clock + ")?)$", options: [.caseInsensitive])
    }()

    static func timeSeparatorLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 48, !label.contains("\n"),
              timeLabelPattern.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)) != nil else { return nil }
        // Preserve the literal label. A relative date is never converted into
        // an invented per-message send time or the local observation time.
        return label
    }

    static func messageSide(_ bounds: CGRect, in region: CGRect) -> MessageSender {
        guard region.width > 0, bounds.minX >= region.minX, bounds.maxX <= region.maxX else { return .unknown }
        let leftMargin = bounds.minX - region.minX
        let rightMargin = region.maxX - bounds.maxX
        let centerOffset = (bounds.midX - region.midX) / region.width
        if rightMargin <= 0.07 && centerOffset >= 0.10 { return .me }
        if leftMargin <= 0.07 && centerOffset <= -0.10 { return .other }
        return .unknown
    }

    static func isInterfaceMessageText(_ text: String) -> Bool {
        let normalized = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter { !$0.isWhitespace && !$0.isPunctuation }
        let controls: Set<String> = [
            "wechat", "weixin", "微信", "search", "qsearch", "搜索", "chats", "聊天",
            "contacts", "通讯录", "discover", "发现", "moments", "朋友圈", "settings", "设置",
            "voicecall", "videocall", "语音通话", "视频通话", "按住说话", "发送", "表情", "文件",
            "截图", "聊天记录", "输入消息", "更多", "转账", "红包"
        ]
        if controls.contains(normalized) { return true }
        return ["typeamessage", "entermessage", "sendamessage", "holdtospeak"].contains(normalized)
    }

    static func isPlausibleMessageBubble(_ bounds: CGRect, in region: CGRect) -> Bool {
        guard region.width > 0, bounds.minX >= region.minX, bounds.maxX <= region.maxX,
              bounds.minY >= region.minY, bounds.maxY <= region.maxY,
              bounds.width >= 0.008, bounds.width <= 0.72,
              bounds.height >= 0.006, bounds.height <= 0.10 else { return false }
        let leftMargin = bounds.minX - region.minX
        let rightMargin = region.maxX - bounds.maxX
        let leftBubble = leftMargin <= 0.24 && bounds.midX <= region.midX + 0.06
        let rightBubble = rightMargin <= 0.24 && bounds.midX >= region.midX - 0.06
        return leftBubble || rightBubble
    }

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

    static func containsChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3400...0x9FFF).contains(Int($0.value)) }
    }

    static func isReliableOCRText(_ text: String, confidence: Float) -> Bool {
        guard confidence >= 0.70, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !text.unicodeScalars.contains(where: { $0.value == 0xFFFD || (CharacterSet.controlCharacters.contains($0) && ![9, 10, 13].contains($0.value)) }) else { return false }
        return isPlausibleChatText(text, confidence: confidence) ||
            (confidence >= 0.90 && text.count <= 12 && text.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) })
    }

    static func needsAccurateOCR(_ candidates: [(text: String, confidence: Float)], acceptedCount: Int) -> Bool {
        acceptedCount == 0 || candidates.contains {
            containsChinese($0.text) || $0.confidence < 0.90 || !isReliableOCRText($0.text, confidence: $0.confidence)
        }
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

    static func descendantMessageText(role: String, identifier: String, title: String?, value: String?) -> String? {
        guard ["AXStaticText", "AXTextArea"].contains(role),
              identifier.isEmpty || ["chat_bubble_text", "chat_message_text"].contains(identifier),
              let text = messageText(identifier: messageRowIdentifier, title: title, value: value) else { return nil }
        let label = text.lowercased()
        guard !["today", "yesterday", "今天", "昨天", "message recalled", "你撤回了一条消息"].contains(label),
              !label.hasSuffix("撤回了一条消息") else { return nil }
        // Standalone time/date labels are metadata when found via fallback.
        let timestamp = #"^(?:\d{1,4}[-/年]\d{1,2}[-/月]\d{1,2}日?|(?:Today|Yesterday|今天|昨天|星期[一二三四五六日天])?(?:\s*)(?:AM|PM|上午|下午)?\s*\d{1,2}:\d{2}(?:\s*(?:AM|PM))?)$"#
        guard text.range(of: timestamp, options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
        return text
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
