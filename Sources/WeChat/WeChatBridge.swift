import Cocoa
import ApplicationServices

/// Read-only Accessibility access to the active WeChat conversation.
final class WeChatBridge {
    static let shared = WeChatBridge()

    var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }
    var isWeChatRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.localizedName?.contains("WeChat") == true }
    }

    func requestAccessibilityPermission() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options)
    }

    private func applicationElement() -> AXUIElement? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName?.contains("WeChat") == true }) else { return nil }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    private func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        AXUIElementCopyAttributeValue(element, name as CFString, &result)
        return result
    }

    private func string(_ element: AXUIElement, _ name: String) -> String? { value(element, name) as? String }

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
        if let title = string(window, "AXTitle"), !title.isEmpty, title != "WeChat" { return title }
        let fields = find(window) {
            guard self.string($0, "AXRole") == "AXTextArea" else { return false }
            let title = self.string($0, "AXTitle") ?? ""
            return title != "Search" && title != "搜索"
        }
        let input = fields.max { a, b in
            let first = frame(a), second = frame(b)
            return first.width * first.height < second.width * second.height
        }
        return input.flatMap { string($0, "AXTitle") }.flatMap { $0.isEmpty ? nil : $0 }
    }

    func recentMessages(limit: Int = 20) -> [ChatMessage] {
        guard let window = mainWindow() else { return [] }
        let lists = find(window) { self.string($0, "AXRole") == "AXList" && ["Messages", "消息"].contains(self.string($0, "AXTitle") ?? "") }
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
        // Manual analysis may use visible text when WeChat exposes no message list,
        // but sender identity is unknown and the monitor must never auto-analyze it.
        let panelLeft = windowFrame.minX + 250
        let visibleText = find(window, depth: 30) {
            guard self.string($0, "AXRole") == "AXStaticText" else { return false }
            let bounds = self.frame($0)
            return bounds.minX > panelLeft && bounds.width > 30 && bounds.height > 10
        }
        let fallback = visibleText.compactMap { element -> ChatMessage? in
            let text = self.string(element, "AXValue") ?? self.string(element, "AXTitle") ?? ""
            guard text.count >= 2 else { return nil }
            return ChatMessage(text: text, isFromMe: false, senderIdentified: false)
        }
        return Array(fallback.suffix(limit))
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
