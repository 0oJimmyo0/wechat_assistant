import Cocoa
import ApplicationServices

enum MessageReadResult: Sendable {
    case messageListUnavailable(treeCollapsed: Bool)
    case messageListFound(messages: [ChatMessage], renderedRows: Int, bubbleRows: Int, placeholders: Int)
}

/// Read-only Accessibility access to the active WeChat conversation.
final class WeChatBridge: @unchecked Sendable {
    static let shared = WeChatBridge()

    private let officialWeChatBundleID = "com.tencent.xinWeChat"
    private let helperBundleID = "com.wechatreplycopilot.app"

    var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    private func weChatApplication() -> NSRunningApplication? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let matches = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == officialWeChatBundleID &&
            $0.processIdentifier != ownPID &&
            $0.bundleIdentifier != helperBundleID
        }
        return matches.first(where: { $0.isActive }) ?? matches.first(where: { $0.activationPolicy == .regular }) ?? matches.first
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
        AXUIElementSetMessagingTimeout(element, 1.0)
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private func string(_ element: AXUIElement, _ name: String) -> String? { value(element, name) as? String }
    private func identifier(_ element: AXUIElement) -> String { string(element, "AXIdentifier") ?? "" }
    private func bool(_ element: AXUIElement, _ name: String) -> Bool { (value(element, name) as? NSNumber)?.boolValue ?? false }
    private func children(_ element: AXUIElement) -> [AXUIElement] { (value(element, "AXChildren") as? [AXUIElement]) ?? [] }

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

    private func find(_ root: AXUIElement, depth: Int = 24, where predicate: (AXUIElement) -> Bool) -> [AXUIElement] {
        guard depth > 0 else { return predicate(root) ? [root] : [] }
        var results = predicate(root) ? [root] : []
        for child in children(root) {
            results.append(contentsOf: find(child, depth: depth - 1, where: predicate))
        }
        return results
    }

    private func windows(in appElement: AXUIElement) -> [AXUIElement] {
        (value(appElement, "AXWindows") as? [AXUIElement]) ?? []
    }

    private func windowElement(_ appElement: AXUIElement, attribute: String) -> AXUIElement? {
        guard let raw = value(appElement, attribute) else { return nil }
        guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private func windowCandidates(in appElement: AXUIElement) -> [AXUIElement] {
        var result = windows(in: appElement)
        for attribute in ["AXFocusedWindow", "AXMainWindow"] {
            guard let candidate = windowElement(appElement, attribute: attribute),
                  string(candidate, "AXRole") == "AXWindow",
                  !result.contains(where: { CFEqual($0, candidate) }) else { continue }
            result.append(candidate)
        }
        return result
    }

    private func diagnosticAttributeState(_ element: AXUIElement, attribute: String) -> String {
        AXUIElementSetMessagingTimeout(element, 1.0)
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &raw)
        guard error == .success, let raw else { return "unavailable (AXError \(error.rawValue))" }
        if let elements = raw as? [AXUIElement] { return "available (\(elements.count))" }
        if CFGetTypeID(raw) == AXUIElementGetTypeID() {
            let element = raw as! AXUIElement
            return "available (\(string(element, "AXRole") ?? "element"))"
        }
        return "available"
    }

    /// Select a visible, standard WeChat window. Focused/main windows win over
    /// other standard windows; popovers, dialogs, minimized and settings/login
    /// windows are excluded.
    private func mainWindow() -> AXUIElement? {
        guard let app = applicationElement() else { return nil }
        let allWindows = windowCandidates(in: app)
        let candidates = allWindows.filter { window in
            guard string(window, "AXRole") == "AXWindow" else { return false }
            let subrole = string(window, "AXSubrole") ?? ""
            guard subrole.isEmpty || subrole == "AXStandardWindow" else { return false }
            guard !bool(window, "AXMinimized"), !bool(window, "AXHidden") else { return false }
            let title = (string(window, "AXTitle") ?? "").lowercased()
            let excludedTerms = ["settings", "preferences", "login", "sign in", "qr code", "扫码登录", "设置"]
            return !excludedTerms.contains(where: title.contains)
        }
        guard !candidates.isEmpty else { return nil }

        if let focused = windowElement(app, attribute: "AXFocusedWindow") {
            if let match = candidates.first(where: { CFEqual($0, focused) }) { return match }
        }
        if let main = candidates.first(where: { bool($0, "AXMain") }) { return main }
        return candidates.first
    }

    func currentContact() -> String? {
        guard let window = mainWindow() else { return nil }

        // 1. WeChat 4.x's stable conversation-title node.
        let titleNodes = find(window) {
            string($0, "AXRole") == "AXStaticText" && identifier($0) == WeChatParsing.chatTitleIdentifier
        }
        for node in titleNodes {
            let raw = string(node, "AXValue") ?? string(node, "AXTitle") ?? ""
            let name = WeChatParsing.normalizeChatTitle(raw)
            if !name.isEmpty && !WeChatParsing.isGenericWindowTitle(name) { return name }
        }

        // 2. Session item identifiers are useful only when WeChat explicitly
        // exposes the row's selected state. Never guess from arbitrary text.
        let selectedSessionRows = find(window) {
            identifier($0).hasPrefix("session_item_") && bool($0, "AXSelected")
        }
        for row in selectedSessionRows {
            if let name = WeChatParsing.selectedSessionName(from: identifier(row), isSelected: true) {
                return name
            }
        }
        return visibleSnapshot(for: window)?.title
    }

    func readMessages(limit: Int = 50) -> MessageReadResult {
        guard let window = mainWindow() else { return .messageListUnavailable(treeCollapsed: false) }

        // 1. Stable WeChat 4.x message-list identifier.
        if let list = find(window, where: {
            string($0, "AXRole") == "AXList" && identifier($0) == WeChatParsing.messageListIdentifier
        }).first {
            return readRows(in: list, limit: limit)
        }

        // 2. Localized AXTitle fallback.
        if let list = find(window, where: {
            string($0, "AXRole") == "AXList" && ["Messages", "消息"].contains(string($0, "AXTitle") ?? "")
        }).first {
            return readRows(in: list, limit: limit)
        }

        // 3. Conservative older-client fallback: only inspect AXLists under a
        // large right-side scroll area when the chat composer is also present.
        guard hasConversationComposer(in: window) else {
            if let result = readVisibleMessages(in: window, limit: limit) { return result }
            return .messageListUnavailable(treeCollapsed: accessibilityTreeAppearsCollapsed(in: window))
        }
        let windowFrame = frame(window)
        let paneAreas = find(window) {
            guard string($0, "AXRole") == "AXScrollArea" else { return false }
            let bounds = frame($0)
            return bounds.minX > windowFrame.minX + windowFrame.width * 0.25 &&
                bounds.width > 220 && bounds.height > 300
        }
        for area in paneAreas {
            if let list = find(area, depth: 8, where: { string($0, "AXRole") == "AXList" }).first {
                return readRows(in: list, limit: limit)
            }
        }
        if let result = readVisibleMessages(in: window, limit: limit) { return result }
        return .messageListUnavailable(treeCollapsed: accessibilityTreeAppearsCollapsed(in: window))
    }

    private func readVisibleMessages(in window: AXUIElement, limit: Int) -> MessageReadResult? {
        guard let snapshot = visibleSnapshot(for: window) else { return nil }
        let messages = Array(snapshot.messages.suffix(limit))
        return .messageListFound(
            messages: messages,
            renderedRows: messages.count,
            bubbleRows: messages.count,
            placeholders: 0
        )
    }

    private func visibleSnapshot(for window: AXUIElement) -> VisibleWeChatSnapshot? {
        guard let app = weChatApplication() else { return nil }
        return WeChatScreenReader.shared.read(pid: app.processIdentifier, windowFrame: frame(window))
    }

    private func readRows(in list: AXUIElement, limit: Int) -> MessageReadResult {
        let rows = children(list)
        var messages: [ChatMessage] = []
        var bubbleRows = 0
        var placeholders = 0
        for row in rows {
            // Read the row's structural fields together with its preferred text.
            let rowIdentifier = identifier(row)
            let rowTitle = string(row, "AXTitle")
            let rowValue = string(row, "AXValue")
            let rowFrame = frame(row)
            _ = rowFrame

            if rowIdentifier == WeChatParsing.placeholderRowIdentifier {
                placeholders += 1
                continue
            }
            guard rowIdentifier == WeChatParsing.messageRowIdentifier else { continue }
            bubbleRows += 1

            guard let text = WeChatParsing.messageText(identifier: rowIdentifier, title: rowTitle, value: rowValue) else { continue }
            let description = string(row, "AXDescription") ?? ""
            let sender = WeChatParsing.sender(from: description)
            messages.append(ChatMessage(text: text, sender: sender))
        }
        return .messageListFound(
            messages: Array(messages.suffix(limit)),
            renderedRows: rows.count,
            bubbleRows: bubbleRows,
            placeholders: placeholders
        )
    }

    private func hasConversationComposer(in root: AXUIElement) -> Bool {
        let bounds = frame(root)
        return !find(root, depth: 16) { element in
            guard string(element, "AXRole") == "AXTextArea" else { return false }
            let rect = frame(element)
            return rect.minX > bounds.minX + bounds.width * 0.25 &&
                rect.minY > bounds.minY + bounds.height * 0.65 &&
                rect.width > 180 && rect.height > 30
        }.isEmpty
    }

    func accessibilityTreeAppearsCollapsed() -> Bool {
        guard let window = mainWindow() else { return false }
        return accessibilityTreeAppearsCollapsed(in: window)
    }

    private func accessibilityTreeAppearsCollapsed(in window: AXUIElement) -> Bool {
        let nodes = find(window, depth: 8) { element in
            ["AXTextArea", "AXList", "AXScrollArea"].contains(string(element, "AXRole") ?? "") ||
                identifier(element) == WeChatParsing.chatTitleIdentifier ||
                identifier(element) == WeChatParsing.messageListIdentifier
        }
        return nodes.isEmpty && children(window).count <= 8
    }

    /// Produces structural metadata only. This method never reads AXValue or
    /// prints to a log; the UI writes the returned report only after an explicit
    /// user action. Potentially identifying window titles and row identifiers
    /// are redacted before the report is returned.
    func diagnosticReport() -> String {
        guard let runningApp = weChatApplication() else {
            return "WeChat bundle: \(officialWeChatBundleID)\nProcess: not running\n"
        }
        let appElement = AXUIElementCreateApplication(runningApp.processIdentifier)
        let appWindows = windows(in: appElement)
        let selectedWindow = mainWindow()
        var lines = [
            "WeChat bundle: \(runningApp.bundleIdentifier ?? "<unknown>")",
            "PID: \(runningApp.processIdentifier)",
            "Helper excluded: \(runningApp.processIdentifier != ProcessInfo.processInfo.processIdentifier && runningApp.bundleIdentifier != helperBundleID)",
            "Windows: \(appWindows.count)"
        ]
        lines.append("AXWindows attribute: \(diagnosticAttributeState(appElement, attribute: "AXWindows"))")
        lines.append("AXFocusedWindow attribute: \(diagnosticAttributeState(appElement, attribute: "AXFocusedWindow"))")
        lines.append("AXMainWindow attribute: \(diagnosticAttributeState(appElement, attribute: "AXMainWindow"))")
        lines.append("AXChildren attribute: \(diagnosticAttributeState(appElement, attribute: "AXChildren"))")
        lines.append("Screen capture permission: \(WeChatScreenReader.hasScreenCapturePermission ? "granted" : "not granted")")

        for (index, window) in appWindows.enumerated() {
            let role = string(window, "AXRole") ?? "<unavailable>"
            let title = WeChatParsing.genericDiagnosticWindowTitle(string(window, "AXTitle"))
            let subrole = string(window, "AXSubrole") ?? "<unavailable>"
            lines.append("Window \(index + 1): role=\(role) subrole=\(subrole) title=\(title) minimized=\(bool(window, "AXMinimized"))")
        }

        guard let window = selectedWindow else {
            lines.append("Main conversation window: unavailable")
            return lines.joined(separator: "\n") + "\n"
        }
        let windowRole = string(window, "AXRole") ?? "<unavailable>"
        let windowIdentifier = WeChatParsing.diagnosticIdentifier(identifier(window))
        let windowFrame = frame(window)
        lines.append("Main window:")
        lines.append("  role=\(windowRole)")
        lines.append("  identifier=\(windowIdentifier)")
        lines.append("  frame=\(frameDescription(windowFrame))")

        let titleNodes = find(window) {
            string($0, "AXRole") == "AXStaticText" && identifier($0) == WeChatParsing.chatTitleIdentifier
        }
        lines.append("Current-chat title element:")
        lines.append("  found=\(!titleNodes.isEmpty)")
        lines.append("  identifier=\(titleNodes.isEmpty ? "<none>" : WeChatParsing.chatTitleIdentifier)")

        let messageLists = find(window) {
            string($0, "AXRole") == "AXList" && identifier($0) == WeChatParsing.messageListIdentifier
        }
        let localizedLists = find(window) {
            string($0, "AXRole") == "AXList" && ["Messages", "消息"].contains(string($0, "AXTitle") ?? "")
        }
        let allBubbleRows = find(window) { identifier($0) == WeChatParsing.messageRowIdentifier }.count
        let allPlaceholderRows = find(window) { identifier($0) == WeChatParsing.placeholderRowIdentifier }.count
        lines.append("Message list:")
        lines.append("  chat_message_list found=\(!messageLists.isEmpty)")
        lines.append("  localized Messages/消息 list found=\(!localizedLists.isEmpty)")
        lines.append("  message rows in window chat_bubble_item_view=\(allBubbleRows) virtual_cell=\(allPlaceholderRows)")
        if let list = messageLists.first {
            let rows = children(list)
            let bubbleCount = rows.filter { identifier($0) == WeChatParsing.messageRowIdentifier }.count
            let virtualCount = rows.filter { identifier($0) == WeChatParsing.placeholderRowIdentifier }.count
            lines.append("  role=\(string(list, "AXRole") ?? "<unavailable>")")
            lines.append("  identifier=\(WeChatParsing.messageListIdentifier)")
            lines.append("  children total=\(rows.count) chat_bubble_item_view=\(bubbleCount) virtual_cell=\(virtualCount) other=\(max(0, rows.count - bubbleCount - virtualCount))")
        }

        let nodes = structuralNodes(in: window, maximum: 500)
        lines.append("Structural nodes (text values omitted; identifiers sanitized):")
        lines.append(contentsOf: nodes)
        return lines.joined(separator: "\n") + "\n"
    }

    private func structuralNodes(in root: AXUIElement, maximum: Int) -> [String] {
        var output: [String] = []
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        while let (element, depth) = stack.popLast(), output.count < maximum {
            let role = string(element, "AXRole") ?? "<unavailable>"
            let id = WeChatParsing.diagnosticIdentifier(identifier(element))
            let childNodes = children(element)
            let bounds = frame(element)
            output.append("  \(String(repeating: " ", count: min(depth, 12)))role=\(role) identifier=\(id) children=\(childNodes.count) frame=\(frameDescription(bounds))")
            for child in childNodes.reversed() { stack.append((child, depth + 1)) }
        }
        if !stack.isEmpty { output.append("  <node output capped>") }
        return output
    }

    private func frameDescription(_ rect: CGRect) -> String {
        "\(Int(rect.origin.x)),\(Int(rect.origin.y)),\(Int(rect.width)),\(Int(rect.height))"
    }
}
