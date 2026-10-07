import Cocoa
import ApplicationServices

/// One read of the active WeChat window. Empty messages never imply an empty chat.
struct WeChatSnapshot {
    let contact: String?
    let messages: [ChatMessage]
    let messageListFound: Bool
    let bubbleRowsFound: Int
}

/// Read-only reader for the currently selected WeChat conversation.
final class WeChatBridge: @unchecked Sendable {
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
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName?.contains("WeChat") == true })
        else { return nil }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    private func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        // Bound an unresponsive client rather than indefinitely blocking the serial monitor queue.
        AXUIElementSetMessagingTimeout(element, 0.5)
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private func string(_ element: AXUIElement, _ name: String) -> String? {
        value(element, name) as? String
    }

    /// One cross-process call for the two attributes needed during discovery.
    private func roleAndIdentifier(_ element: AXUIElement) -> (role: String, identifier: String) {
        AXUIElementSetMessagingTimeout(element, 0.5)
        var values: CFArray?
        let attrs = ["AXRole", "AXIdentifier"] as CFArray
        if AXUIElementCopyMultipleAttributeValues(element, attrs, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
           let array = values, let entries = array as? [Any], entries.count == 2 {
            return (entries[0] as? String ?? "", entries[1] as? String ?? "")
        }
        return (string(element, "AXRole") ?? "", string(element, "AXIdentifier") ?? "")
    }

    private func children(_ element: AXUIElement, preferVisible: Bool = false) -> [AXUIElement] {
        if preferVisible, let visible = value(element, "AXVisibleChildren") as? [AXUIElement], !visible.isEmpty {
            return visible
        }
        return (value(element, "AXChildren") as? [AXUIElement]) ?? []
    }

    private func frame(_ element: AXUIElement) -> CGRect {
        var origin = CGPoint.zero
        var size = CGSize.zero
        if let raw = value(element, "AXPosition"), CFGetTypeID(raw) == AXValueGetTypeID() {
            AXValueGetValue(raw as! AXValue, .cgPoint, &origin)
        }
        if let raw = value(element, "AXSize"), CFGetTypeID(raw) == AXValueGetTypeID() {
            AXValueGetValue(raw as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: origin, size: size)
    }

    private func mainWindow() -> AXUIElement? {
        guard let app = applicationElement() else { return nil }
        if let focused = value(app, "AXFocusedWindow"), CFGetTypeID(focused) == AXUIElementGetTypeID() {
            return (focused as! AXUIElement)
        }
        return (value(app, "AXWindows") as? [AXUIElement])?.first
    }

    /// Locate the selected sidebar session and the chat pane in ONE bounded tree walk.
    /// Never scan arbitrary window labels and send them as conversation text.
    func capture(limit: Int = 20) -> WeChatSnapshot {
        let unavailable = WeChatSnapshot(contact: nil, messages: [], messageListFound: false, bubbleRowsFound: 0)
        guard let window = mainWindow() else { return unavailable }

        let windowTitle = string(window, "AXTitle") ?? ""
        var contact: String? = isGenericWindowTitle(windowTitle) ? nil : firstLine(windowTitle)
        var messageList: AXUIElement?
        var fallbackList: AXUIElement?
        let windowBounds = frame(window)
        var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var index = 0
        var visited = 0

        // Child enumeration and metadata are remote IPC calls. Stop at a bounded node
        // count and depth instead of recursively searching the entire application.
        while index < queue.count && visited < 650 {
            let node = queue[index]
            index += 1
            visited += 1
            let (role, identifier) = roleAndIdentifier(node.element)

            if identifier.hasPrefix("session_item_"),
               (value(node.element, "AXSelected") as? NSNumber)?.boolValue == true {
                let suffix = String(identifier.dropFirst("session_item_".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !suffix.isEmpty { contact = firstLine(suffix) }
                else if let title = string(node.element, "AXTitle") { contact = firstLine(title) }
            }

            if identifier == "chat_message_list" {
                messageList = node.element
            } else if fallbackList == nil && (role == "AXList" || role == "AXTable"),
                      ["Messages", "消息"].contains(string(node.element, "AXTitle") ?? "") {
                let bounds = frame(node.element)
                if bounds.width > 180 &&
                   bounds.minX > windowBounds.minX + windowBounds.width * 0.25 {
                    fallbackList = node.element
                }
            }

            if messageList != nil && contact != nil { break }
            if node.depth < 18 && role != "AXStaticText" && role != "AXTextArea" {
                for child in children(node.element) {
                    queue.append((child, node.depth + 1))
                }
            }
        }

        guard let list = messageList ?? fallbackList else {
            return WeChatSnapshot(contact: contact, messages: [], messageListFound: false, bubbleRowsFound: 0)
        }
        let (messages, count) = parseBubbleRows(list, limit: max(1, limit))
        return WeChatSnapshot(contact: contact, messages: messages, messageListFound: true, bubbleRowsFound: count)
    }

    func currentContact() -> String? { capture(limit: 1).contact }
    func recentMessages(limit: Int = 20) -> [ChatMessage] { capture(limit: limit).messages }

    private func parseBubbleRows(_ list: AXUIElement, limit: Int) -> ([ChatMessage], Int) {
        var entries: [(y: CGFloat, index: Int, message: ChatMessage)] = []
        var bubbleCount = 0

        // In WeChat 4.x the list contains chat_bubble_item_view and virtual_cell
        // entries. Only actual bubble rows are messages; other rows include dates,
        // system notices and recycled virtual placeholders.
        func consume(_ row: AXUIElement, index: Int) {
            bubbleCount += 1
            guard let text = bubbleText(row) else { return }
            let description = (string(row, "AXDescription") ?? "").lowercased()
            let sent = description.hasPrefix("sent") || description.hasPrefix("发出") || description.hasPrefix("我说")
            let received = description.hasPrefix("received") || description.hasPrefix("收到") || description.hasPrefix("对方")
            let message = ChatMessage(text: text, isFromMe: sent, senderIdentified: sent || received)
            entries.append((frame(row).minY, index, message))
        }

        func read(_ rows: [AXUIElement]) {
            for (index, row) in rows.suffix(150).enumerated() {
                let identifier = string(row, "AXIdentifier") ?? ""
                if identifier == "chat_bubble_item_view" {
                    consume(row, index: index)
                } else if identifier != "virtual_cell" {
                    // Some client builds wrap a bubble in a row/cell. Limit this
                    // fallback to direct children of a real message-list row.
                    for child in children(row).prefix(8) where string(child, "AXIdentifier") == "chat_bubble_item_view" {
                        consume(child, index: index)
                    }
                }
            }
        }

        let visible = value(list, "AXVisibleChildren") as? [AXUIElement] ?? []
        if !visible.isEmpty { read(visible) }
        // An empty visible-child response can occur with custom/virtualized lists.
        if bubbleCount == 0 { read(children(list)) }

        entries.sort {
            if $0.y != $1.y { return $0.y < $1.y }
            return $0.index < $1.index
        }
        return (Array(entries.suffix(limit).map(\.message)), bubbleCount)
    }

    private func bubbleText(_ row: AXUIElement) -> String? {
        // WeChat 4.x exposes message content directly as AXTitle on the bubble.
        for attribute in ["AXTitle", "AXValue"] {
            if let text = string(row, attribute)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return text
            }
        }
        // Compatibility fallback stays entirely inside a recognized bubble row.
        var queue: [(AXUIElement, Int)] = children(row).map { ($0, 1) }
        var index = 0
        while index < queue.count && index < 24 {
            let (element, depth) = queue[index]
            index += 1
            let role = string(element, "AXRole") ?? ""
            if role == "AXStaticText" || role == "AXTextArea" {
                if let text = (string(element, "AXValue") ?? string(element, "AXTitle"))?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    return text
                }
            }
            if depth < 3 { queue.append(contentsOf: children(element).map { ($0, depth + 1) }) }
        }
        return nil
    }

    private func isGenericWindowTitle(_ title: String) -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        return ["wechat", "wechat(chats)", "wechat(contacts)", "wechat(discover)",
                "微信", "微信(聊天)", "微信(通讯录)", ""].contains(normalized)
    }

    private func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
