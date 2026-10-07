import Cocoa
import ApplicationServices

/// Read-only Accessibility access to the active WeChat conversation.
final class WeChatBridge: @unchecked Sendable {
    static let shared = WeChatBridge()

    var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    private let officialWeChatBundleID = "com.tencent.xinWeChat"

    /// Resolve the real WeChat process by bundle identifier, never by a fuzzy
    /// application-name match. The helper itself is named "WeChat Reply Copilot",
    /// so matching `localizedName.contains("WeChat")` can accidentally bind the
    /// Accessibility bridge to this app instead of WeChat.
    private func weChatApplication() -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications

        // Prefer the official WeChat bundle exactly.
        if let official = apps.first(where: { $0.bundleIdentifier == officialWeChatBundleID }) {
            return official
        }

        // Conservative fallback for locally cloned WeChat builds whose bundle ID
        // keeps Tencent's prefix. Explicitly exclude this helper's own process.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return apps.first {
            $0.processIdentifier != ownPID &&
            ($0.bundleIdentifier?.hasPrefix(officialWeChatBundleID) == true)
        }
    }

    var isWeChatRunning: Bool { weChatApplication() != nil }

    func requestAccessibilityPermission() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options)
    }

    private func applicationElement() -> AXUIElement? {
        guard let app = weChatApplication() else { return nil }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    private func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        // WeChat may take a long time to answer Accessibility requests. Never let
        // one unresponsive element hold the monitor indefinitely.
        AXUIElementSetMessagingTimeout(element, 1.0)
        var result: CFTypeRef?
        AXUIElementCopyAttributeValue(element, name as CFString, &result)
        return result
    }

    private func string(_ element: AXUIElement, _ name: String) -> String? { value(element, name) as? String }
    private func identifier(_ element: AXUIElement) -> String { string(element, "AXIdentifier") ?? "" }
    private func isSelected(_ element: AXUIElement) -> Bool { (value(element, "AXSelected") as? NSNumber)?.boolValue ?? false }

    private func frame(_ element: AXUIElement) -> CGRect {
        var origin = CGPoint.zero
        var size = CGSize.zero
        if let raw = value(element, "AXPosition") { AXValueGetValue(raw as! AXValue, .cgPoint, &origin) }
        if let raw = value(element, "AXSize") { AXValueGetValue(raw as! AXValue, .cgSize, &size) }
        return CGRect(origin: origin, size: size)
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] { (value(element, "AXChildren") as? [AXUIElement]) ?? [] }

    private func find(_ root: AXUIElement, depth: Int = 24, where predicate: (AXUIElement) -> Bool) -> [AXUIElement] {
        guard depth > 0 else { return predicate(root) ? [root] : [] }
        var results = predicate(root) ? [root] : []
        for child in children(root) { results.append(contentsOf: find(child, depth: depth - 1, where: predicate)) }
        return results
    }

    private func mainWindow() -> AXUIElement? {
        guard let app = applicationElement() else { return nil }
        if let focused = value(app, "AXFocusedWindow") { return (focused as! AXUIElement) }
        return (value(app, "AXWindows") as? [AXUIElement])?.first
    }

    func currentContact() -> String? {
        guard let window = mainWindow() else { return nil }
        if let title = string(window, "AXTitle"), !title.isEmpty, !isGenericWindowTitle(title) {
            return normalizeChatTitle(title)
        }

        // WeChat 4.x exposes the open conversation title as a stable
        // AXStaticText identifier. Prefer this over sidebar-selection state:
        // recent clients do not consistently expose AXSelected on session rows.
        let titleElements = find(window, depth: 24) {
            self.string($0, "AXRole") == "AXStaticText" &&
            self.identifier($0) == "big_title_line_h_view"
        }
        for element in titleElements {
            let raw = self.string(element, "AXValue") ?? self.string(element, "AXTitle") ?? ""
            let name = normalizeChatTitle(raw)
            if !name.isEmpty, !isGenericWindowTitle(name) { return name }
        }

        // Some WeChat builds keep the window title at "WeChat (Chats)" even
        // while a conversation is open. Prefer the selected chat row's stable
        // identifier, whose value is the display name in WeChat's sidebar.
        let selectedChatRows = find(window, depth: 16) {
            self.identifier($0).hasPrefix("session_item_") && self.isSelected($0)
        }
        for row in selectedChatRows {
            let prefix = "session_item_"
            let idName = String(identifier(row).dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !idName.isEmpty { return normalizeChatTitle(idName) }
            if let rowTitle = string(row, "AXTitle"), let firstLine = firstLine(of: rowTitle), !isGenericWindowTitle(firstLine) {
                return normalizeChatTitle(firstLine)
            }
        }

        // Older clients may not expose the session row identifier. Use a
        // selected sidebar row or a conversation header only when the window
        // also exposes a message list or the chat composer.
        let hasChatEvidence = hasRecognizedMessageList(in: window) || hasConversationComposer(in: window)
        guard hasChatEvidence else { return nil }
        let bounds = frame(window)
        let selectedRows = find(window, depth: 16) { element in
            guard ["AXRow", "AXCell", "AXOutlineRow"].contains(self.string(element, "AXRole") ?? ""), self.isSelected(element) else { return false }
            return self.frame(element).minX < bounds.minX + bounds.width * 0.45
        }
        for row in selectedRows {
            let rowText = string(row, "AXTitle") ?? string(row, "AXValue") ?? ""
            if let name = firstLine(of: rowText), !isGenericWindowTitle(name) { return normalizeChatTitle(name) }
        }

        let headerLabels = find(window, depth: 16) { element in
            guard self.string(element, "AXRole") == "AXStaticText" else { return false }
            let rect = self.frame(element)
            guard rect.minX > bounds.minX + bounds.width * 0.28,
                  rect.minY >= bounds.minY + 30,
                  rect.minY < bounds.minY + 150 else { return false }
            let text = self.string(element, "AXValue") ?? self.string(element, "AXTitle") ?? ""
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !self.isGenericWindowTitle(text)
        }.sorted { frame($0).minY < frame($1).minY }
        for label in headerLabels {
            let text = string(label, "AXValue") ?? string(label, "AXTitle") ?? ""
            if let name = firstLine(of: text), !isGenericWindowTitle(name) { return normalizeChatTitle(name) }
        }
        return nil
    }

    private func isGenericWindowTitle(_ title: String) -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        return ["wechat", "wechat(chats)", "wechat(contacts)", "wechat(discover)", "微信", "微信(聊天)", "微信(通讯录)"].contains(normalized)
    }

    private func firstLine(of text: String) -> String? {
        text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeChatTitle(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Group chats can be rendered as "Group Name(23)" where the suffix is
        // the member count. Strip only a trailing numeric parenthesized suffix.
        if let range = value.range(of: #"\(\d+\)$"#, options: .regularExpression) {
            value.removeSubrange(range)
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    private func hasRecognizedMessageList(in root: AXUIElement) -> Bool {
        !find(root) {
            self.string($0, "AXRole") == "AXList" &&
            (["Messages", "消息"].contains(self.string($0, "AXTitle") ?? "") || self.identifier($0) == "chat_message_list")
        }.isEmpty
    }

    private func hasConversationComposer(in root: AXUIElement) -> Bool {
        let bounds = frame(root)
        return !find(root, depth: 16) { element in
            guard self.string(element, "AXRole") == "AXTextArea" else { return false }
            let rect = self.frame(element)
            return rect.minX > bounds.minX + bounds.width * 0.25 &&
                rect.minY > bounds.minY + bounds.height * 0.65 &&
                rect.width > 180 && rect.height > 30
        }.isEmpty
    }

    func recentMessages(limit: Int = 20) -> [ChatMessage] {
        guard let window = mainWindow() else { return [] }
        let lists = find(window) {
            self.string($0, "AXRole") == "AXList" &&
            (["Messages", "消息"].contains(self.string($0, "AXTitle") ?? "") || self.identifier($0) == "chat_message_list")
        }
        if let list = lists.first { return Array(parse(list).suffix(limit)) }

        let windowFrame = frame(window)
        let areas = find(window) {
            guard self.string($0, "AXRole") == "AXScrollArea" else { return false }
            let bounds = self.frame($0)
            return bounds.minX > windowFrame.minX + 200 && bounds.height > 300
        }
        for area in areas {
            if let list = find(area, depth: 6, where: { self.string($0, "AXRole") == "AXList" }).first {
                let messages = parse(list)
                if !messages.isEmpty { return Array(messages.suffix(limit)) }
            }
        }
        // Do not treat arbitrary visible text as chat content: WeChat's contact
        // details and notes can appear in the same part of the window.
        return []
    }

    private func parse(_ list: AXUIElement) -> [ChatMessage] {
        children(list).compactMap { row in
            let texts = find(row, depth: 8) { ["AXStaticText", "AXTextArea"].contains(self.string($0, "AXRole") ?? "") }
            let text = texts.compactMap { self.string($0, "AXValue") ?? self.string($0, "AXTitle") }.max { $0.count < $1.count }
                ?? self.string(row, "AXValue") ?? self.string(row, "AXTitle") ?? ""
            guard text.count >= 1 else { return nil }
            let description = self.string(row, "AXDescription") ?? ""
            let normalized = description.lowercased()
            let mine = normalized.hasPrefix("sent") || description.hasPrefix("发出") || description.hasPrefix("我说")
            let received = normalized.hasPrefix("received") || description.hasPrefix("收到") || description.hasPrefix("对方")
            return ChatMessage(text: text, isFromMe: mine, senderIdentified: mine || received)
        }
    }
}
