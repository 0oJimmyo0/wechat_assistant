import Cocoa
import ApplicationServices

enum MessageReadResult: Sendable {
    case messageListUnavailable(treeCollapsed: Bool, visionState: VisionCaptureState?)
    case messageListFound(messages: [ChatMessage], renderedRows: Int, bubbleRows: Int, placeholders: Int, isVision: Bool, fingerprint: String?)
    case messageListUnchanged(fingerprint: String)
}

typealias ObservedMessage = ChatMessage

struct WeChatSnapshot: Sendable {
    let contact: String
    let messages: [ObservedMessage]
    let capturedAt: Date
    let messageRowCount: Int
}

enum OlderContextScrollResult: Sendable {
    case scrolled
    case conversationChanged
    case identityUncertain
    case windowUnavailable
    case scrollUnavailable
    case cancelled
}

enum OlderContextReadResult: Sendable {
    case messages(MessageReadResult)
    case conversationChanged
    case identityUncertain
    case captureUnavailable
    case cancelled
}

private enum OlderContextIdentityCheck {
    case matches
    case changed
    case uncertain
}

private enum ChatScrollDirection: Equatable {
    case older
    case newer
}

struct WeChatConversationDetection: Sendable {
    let contact: String?
    let windowFound: Bool
    let treeCollapsed: Bool
    let visionSnapshot: VisibleWeChatSnapshot?
    let backend: WeChatReaderBackend
    let mainWindowLookupMilliseconds: Int
    let capabilityProbeMilliseconds: Int
}

enum WeChatReaderBackend: String, Sendable {
    case unknown
    case accessibility
    case vision
}

/// Read-only Accessibility access to the active WeChat conversation.
final class WeChatBridge: @unchecked Sendable {
    static let shared = WeChatBridge()

    private let officialWeChatBundleID = "com.tencent.xinWeChat"
    private let helperBundleID = "com.wechatreplycopilot.app"
    private let accessibilityTimeout: Float = 0.15
    private let backendLock = NSCondition()
    private var backendPID: pid_t?
    private var readerBackend: WeChatReaderBackend = .unknown
    private var backendProbeMilliseconds = 0
    private var backendProbeResult = "not yet run"
    private var backendProbeNodes = 0
    private var backendProbeInProgress = false
    private var semanticTitleAvailable = false
    private var cachedAXWindow: AXUIElement?
    private var cachedAXWindowPID: pid_t?

    private struct AXCapabilityProbe {
        let title: String?
        let selectedSession: String?
        let hasMessageList: Bool
        let visitedNodes: Int
        let timedOut: Bool
        var supportsAccessibility: Bool { title != nil || selectedSession != nil || hasMessageList }
    }

    var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    private func weChatApplication() -> NSRunningApplication? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let matches = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == officialWeChatBundleID &&
            $0.processIdentifier != ownPID &&
            $0.bundleIdentifier != helperBundleID
        }
        let selected = matches.first(where: { $0.isActive }) ?? matches.first(where: { $0.activationPolicy == .regular }) ?? matches.first
        if selected == nil {
            backendLock.lock()
            backendPID = nil
            readerBackend = .unknown
            backendProbeMilliseconds = 0
            backendProbeResult = "not yet run"
            backendProbeNodes = 0
            backendProbeInProgress = false
            semanticTitleAvailable = false
            cachedAXWindow = nil
            cachedAXWindowPID = nil
            backendLock.broadcast()
            backendLock.unlock()
        }
        return selected
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

    private func value(_ element: AXUIElement, _ name: String, timeout: Float? = nil) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, timeout ?? accessibilityTimeout)
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private func string(_ element: AXUIElement, _ name: String, timeout: Float? = nil) -> String? { value(element, name, timeout: timeout) as? String }
    private func identifier(_ element: AXUIElement, timeout: Float? = nil) -> String { string(element, "AXIdentifier", timeout: timeout) ?? "" }
    private func bool(_ element: AXUIElement, _ name: String) -> Bool { (value(element, name) as? NSNumber)?.boolValue ?? false }
    private func bool(_ element: AXUIElement, _ name: String, timeout: Float) -> Bool {
        (value(element, name, timeout: timeout) as? NSNumber)?.boolValue ?? false
    }
    private func children(_ element: AXUIElement, timeout: Float? = nil) -> [AXUIElement] { (value(element, "AXChildren", timeout: timeout) as? [AXUIElement]) ?? [] }

    private func frame(_ element: AXUIElement, timeout: Float? = nil) -> CGRect {
        var origin = CGPoint.zero
        var size = CGSize.zero
        if let raw = value(element, "AXPosition", timeout: timeout), CFGetTypeID(raw) == AXValueGetTypeID() {
            AXValueGetValue(raw as! AXValue, .cgPoint, &origin)
        }
        if let raw = value(element, "AXSize", timeout: timeout), CFGetTypeID(raw) == AXValueGetTypeID() {
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

    private func firstMatch(_ root: AXUIElement, depth: Int = 24, where predicate: (AXUIElement) -> Bool) -> AXUIElement? {
        guard depth > 0 else { return predicate(root) ? root : nil }
        if predicate(root) { return root }
        for child in children(root) {
            if let match = firstMatch(child, depth: depth - 1, where: predicate) { return match }
        }
        return nil
    }

    private func windows(in appElement: AXUIElement) -> [AXUIElement] {
        (value(appElement, "AXWindows") as? [AXUIElement]) ?? []
    }

    private func windowElement(_ appElement: AXUIElement, attribute: String, timeout: Float? = nil) -> AXUIElement? {
        guard let raw = value(appElement, attribute, timeout: timeout) else { return nil }
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
        guard let runningApp = weChatApplication() else { return nil }
        let pid = runningApp.processIdentifier
        let app = AXUIElementCreateApplication(pid)

        backendLock.lock()
        let cached = cachedAXWindowPID == pid ? cachedAXWindow : nil
        backendLock.unlock()
        if let focused = windowElement(app, attribute: "AXFocusedWindow", timeout: 0.08) {
            guard isUsableConversationWindow(focused) else { return nil }
            cacheMainWindow(focused, pid: pid)
            return focused
        }
        if let cached, isUsableConversationWindow(cached) { return cached }

        // Focused/main window attributes are cheaper than materializing and
        // filtering the full AXWindows tree on every Vision poll.
        for attribute in ["AXMainWindow"] {
            guard let candidate = windowElement(app, attribute: attribute, timeout: 0.08),
                  isUsableConversationWindow(candidate) else { continue }
            cacheMainWindow(candidate, pid: pid)
            return candidate
        }

        let candidates = windows(in: app).filter(isUsableConversationWindow)
        guard let selected = candidates.first else { return nil }
        cacheMainWindow(selected, pid: pid)
        return selected
    }

    private func isUsableConversationWindow(_ window: AXUIElement) -> Bool {
        let shortTimeout: Float = 0.08
        guard string(window, "AXRole", timeout: shortTimeout) == "AXWindow" else { return false }
        let subrole = string(window, "AXSubrole", timeout: shortTimeout) ?? ""
        guard subrole.isEmpty || subrole == "AXStandardWindow" else { return false }
        guard !bool(window, "AXMinimized", timeout: shortTimeout), !bool(window, "AXHidden", timeout: shortTimeout) else { return false }
        let title = (string(window, "AXTitle", timeout: shortTimeout) ?? "").lowercased()
        let excludedTerms = ["settings", "preferences", "login", "sign in", "qr code", "扫码登录", "设置"]
        return !excludedTerms.contains(where: title.contains)
    }

    private func cacheMainWindow(_ window: AXUIElement, pid: pid_t) {
        backendLock.lock()
        cachedAXWindow = window
        cachedAXWindowPID = pid
        backendLock.unlock()
    }

    private func backendState(for pid: pid_t, window: AXUIElement) -> (backend: WeChatReaderBackend, probeMilliseconds: Int, initialProbe: AXCapabilityProbe?) {
        backendLock.lock()
        while backendPID == pid && backendProbeInProgress { backendLock.wait() }
        if backendPID == pid, readerBackend != .unknown {
            let value = (readerBackend, backendProbeMilliseconds, Optional<AXCapabilityProbe>.none)
            backendLock.unlock()
            return value
        }
        backendPID = pid
        readerBackend = .unknown
        backendProbeMilliseconds = 0
        backendProbeResult = "probing"
        backendProbeNodes = 0
        semanticTitleAvailable = false
        backendProbeInProgress = true
        backendLock.broadcast()
        backendLock.unlock()

        let started = Date()
        let result = CapabilityProbeResult()
        let cancellation = ProbeCancellation()
        let semaphore = DispatchSemaphore(value: 0)
        let probeWork = DispatchWorkItem { [weak self] in
            guard let self else { semaphore.signal(); return }
            result.set(self.probeAXCapabilities(in: window, cancellation: cancellation))
            semaphore.signal()
        }
        DispatchQueue.global(qos: .utility).async(execute: probeWork)
        let completed = semaphore.wait(timeout: .now() + 0.40) == .success
        if !completed { cancellation.cancel(); probeWork.cancel() }
        let probe = completed ? result.get() : nil
        let selected: WeChatReaderBackend = probe?.supportsAccessibility == true ? .accessibility : .vision
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        backendLock.lock()
        // A PID change during the asynchronous probe invalidates its result.
        if backendPID == pid {
            readerBackend = selected
            backendProbeMilliseconds = elapsed
            backendProbeNodes = probe?.visitedNodes ?? 0
            backendProbeResult = probe == nil ? "deadline exceeded; selected Vision" :
                (probe?.supportsAccessibility == true ? "semantic chat nodes found" : "no semantic chat nodes found; selected Vision")
            semanticTitleAvailable = probe?.title != nil || probe?.selectedSession != nil
            backendProbeInProgress = false
            backendLock.broadcast()
        }
        let current = backendPID == pid
            ? (readerBackend, backendProbeMilliseconds, probe)
            : (readerBackend, backendProbeMilliseconds, Optional<AXCapabilityProbe>.none)
        backendLock.unlock()
        return current
    }

    private func probeAXCapabilities(in window: AXUIElement, cancellation: ProbeCancellation) -> AXCapabilityProbe {
        let deadline = Date().addingTimeInterval(0.34)
        var stack: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        var title: String?
        var selectedSession: String?
        var hasMessageList = false
        let shortTimeout: Float = 0.02
        while let (element, depth) = stack.popLast(), visited < 96 {
            if cancellation.isCancelled || Date() >= deadline { break }
            visited += 1
            let id = identifier(element, timeout: shortTimeout)
            if id == WeChatParsing.chatTitleIdentifier {
                let raw = string(element, "AXValue", timeout: shortTimeout) ?? string(element, "AXTitle", timeout: shortTimeout) ?? ""
                let normalized = WeChatParsing.normalizeChatTitle(raw)
                if !normalized.isEmpty && !WeChatParsing.isGenericWindowTitle(normalized) { title = normalized }
            } else if id.hasPrefix("session_item_"), bool(element, "AXSelected", timeout: shortTimeout) {
                selectedSession = WeChatParsing.selectedSessionName(from: id, isSelected: true)
            } else if id == WeChatParsing.messageListIdentifier {
                hasMessageList = true
            }
            if depth < 8, Date() < deadline {
                stack.append(contentsOf: children(element, timeout: shortTimeout).reversed().map { ($0, depth + 1) })
            }
            if title != nil || selectedSession != nil || hasMessageList { break }
        }
        return AXCapabilityProbe(title: title, selectedSession: selectedSession,
                                 hasMessageList: hasMessageList, visitedNodes: visited,
                                 timedOut: Date() >= deadline || visited >= 96)
    }

    var readerBackendDiagnostic: String {
        backendLock.lock()
        defer { backendLock.unlock() }
        return "Backend: \(readerBackend.rawValue)\nAX capability probe: \(backendProbeMilliseconds) ms\nAX probe result: \(backendProbeResult)\nAX probe nodes visited: \(backendProbeNodes)"
    }

    func resetReaderBackend() {
        backendLock.lock()
        backendPID = nil
        readerBackend = .unknown
        backendProbeMilliseconds = 0
        backendProbeResult = "not yet run"
        backendProbeNodes = 0
        backendProbeInProgress = false
        semanticTitleAvailable = false
        backendLock.broadcast()
        backendLock.unlock()
    }

    func currentContact() -> String? {
        detectCurrentConversation().contact
    }

    /// Captures the title and the message rows from the same selected WeChat
    /// window and message-list AX element. A present snapshot with zero rows is
    /// distinct from a failed/unavailable AX read (`nil`).
    func captureSnapshot(limit: Int? = nil) -> WeChatSnapshot? {
        guard let window = mainWindow(), let app = weChatApplication() else { return nil }
        var windowPID: pid_t = 0
        guard AXUIElementGetPid(window, &windowPID) == .success,
              windowPID == app.processIdentifier,
              let contact = accessibilityContact(in: window, app: app),
              let list = messageListElement(in: window) else { return nil }
        let allRows = children(list)
        let messages = readAccessibilityMessages(from: allRows, limit: limit)
        return WeChatSnapshot(contact: contact, messages: messages, capturedAt: Date(), messageRowCount: allRows.count)
    }

    func accessibilityObservationTargets() -> (pid: pid_t, elements: [AXUIElement])? {
        guard let window = mainWindow(), let app = weChatApplication(),
              let list = messageListElement(in: window) else { return nil }
        var windowPID: pid_t = 0
        guard AXUIElementGetPid(window, &windowPID) == .success, windowPID == app.processIdentifier else { return nil }
        return (app.processIdentifier, [AXUIElementCreateApplication(app.processIdentifier), window, list])
    }

    private func accessibilityContact(in window: AXUIElement, app: NSRunningApplication) -> String? {
        let info = backendState(for: app.processIdentifier, window: window)
        guard info.backend == .accessibility else { return nil }
        if let probe = info.initialProbe {
            if let title = probe.title { return title }
            if let selected = probe.selectedSession { return selected }
        }
        if let titleNode = firstMatch(window, where: {
            string($0, "AXRole") == "AXStaticText" && identifier($0) == WeChatParsing.chatTitleIdentifier
        }) {
            let title = WeChatParsing.normalizeChatTitle(string(titleNode, "AXValue") ?? string(titleNode, "AXTitle") ?? "")
            if !title.isEmpty && !WeChatParsing.isGenericWindowTitle(title) { return title }
        }
        if let selectedRow = firstMatch(window, where: {
            identifier($0).hasPrefix("session_item_") && bool($0, "AXSelected")
        }) {
            return WeChatParsing.selectedSessionName(from: identifier(selectedRow), isSelected: true)
        }
        return nil
    }

    private func messageListElement(in window: AXUIElement) -> AXUIElement? {
        if let list = firstMatch(window, where: {
            string($0, "AXRole") == "AXList" && identifier($0) == WeChatParsing.messageListIdentifier
        }) { return list }
        if let list = firstMatch(window, where: {
            string($0, "AXRole") == "AXList" && ["Messages", "消息"].contains(string($0, "AXTitle") ?? "")
        }) { return list }
        guard hasConversationComposer(in: window) else { return nil }
        let windowFrame = frame(window)
        let paneAreas = find(window) {
            guard string($0, "AXRole") == "AXScrollArea" else { return false }
            let bounds = frame($0)
            return bounds.minX > windowFrame.minX + windowFrame.width * 0.25 &&
                bounds.width > 220 && bounds.height > 300
        }
        for area in paneAreas {
            if let list = firstMatch(area, depth: 8, where: { string($0, "AXRole") == "AXList" }) {
                return list
            }
        }
        return nil
    }

    private func readAccessibilityMessages(from rows: [AXUIElement], limit: Int?) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        for row in rows {
            let rowID = identifier(row)
            guard rowID == WeChatParsing.messageRowIdentifier,
                  let text = WeChatParsing.messageText(
                    identifier: rowID,
                    title: string(row, "AXTitle"),
                    value: string(row, "AXValue")
                  ) else { continue }
            let sender = WeChatParsing.sender(from: string(row, "AXDescription") ?? "")
            messages.append(ChatMessage(text: text, sender: sender, source: .accessibility))
        }
        return limit.map { Array(messages.suffix(max(0, $0))) } ?? messages
    }

    func detectCurrentConversation(forceFreshVision: Bool = false,
                                  onStage: ((String) -> Void)? = nil) -> WeChatConversationDetection {
        onStage?("Finding WeChat window…")
        let windowStarted = Date()
        guard let window = mainWindow() else {
            return WeChatConversationDetection(contact: nil, windowFound: false, treeCollapsed: false,
                                              visionSnapshot: nil, backend: .unknown,
                                              mainWindowLookupMilliseconds: Int(Date().timeIntervalSince(windowStarted) * 1000),
                                              capabilityProbeMilliseconds: 0)
        }
        let windowLookupMilliseconds = Int(Date().timeIntervalSince(windowStarted) * 1000)
        guard let app = weChatApplication() else {
            return WeChatConversationDetection(contact: nil, windowFound: false, treeCollapsed: false,
                                              visionSnapshot: nil, backend: .unknown,
                                              mainWindowLookupMilliseconds: windowLookupMilliseconds,
                                              capabilityProbeMilliseconds: 0)
        }
        let backendInfo = backendState(for: app.processIdentifier, window: window)
        let backend = backendInfo.backend
        let titleAXAvailable: Bool
        backendLock.lock()
        titleAXAvailable = semanticTitleAvailable
        backendLock.unlock()
        onStage?("Reading conversation title…")

        if backend == .vision || (backend == .accessibility && !titleAXAvailable) {
            let snapshot = visibleTitleIdentity(for: window, forceFresh: forceFreshVision)
            return WeChatConversationDetection(
                contact: snapshot?.title,
                windowFound: true,
                treeCollapsed: true,
                visionSnapshot: snapshot,
                backend: backend,
                mainWindowLookupMilliseconds: windowLookupMilliseconds,
                capabilityProbeMilliseconds: backendInfo.probeMilliseconds
            )
        }

        if let probe = backendInfo.initialProbe, backend == .accessibility {
            if let title = probe.title {
                return WeChatConversationDetection(contact: title, windowFound: true, treeCollapsed: false,
                                                  visionSnapshot: nil, backend: backend,
                                                  mainWindowLookupMilliseconds: windowLookupMilliseconds,
                                                  capabilityProbeMilliseconds: backendInfo.probeMilliseconds)
            }
            if let name = probe.selectedSession {
                return WeChatConversationDetection(contact: name, windowFound: true, treeCollapsed: false,
                                                  visionSnapshot: nil, backend: backend,
                                                  mainWindowLookupMilliseconds: windowLookupMilliseconds,
                                                  capabilityProbeMilliseconds: backendInfo.probeMilliseconds)
            }
        }

        // 1. WeChat 4.x's stable conversation-title node.
        if let titleNode = firstMatch(window, where: {
            string($0, "AXRole") == "AXStaticText" && identifier($0) == WeChatParsing.chatTitleIdentifier
        }) {
            let raw = string(titleNode, "AXValue") ?? string(titleNode, "AXTitle") ?? ""
            let name = WeChatParsing.normalizeChatTitle(raw)
            if !name.isEmpty && !WeChatParsing.isGenericWindowTitle(name) {
                return WeChatConversationDetection(contact: name, windowFound: true, treeCollapsed: false,
                                                  visionSnapshot: nil, backend: backend,
                                                  mainWindowLookupMilliseconds: windowLookupMilliseconds,
                                                  capabilityProbeMilliseconds: backendInfo.probeMilliseconds)
            }
        }

        // 2. Session item identifiers are useful only when WeChat explicitly
        // exposes the row's selected state. Never guess from arbitrary text.
        if let selectedSessionRow = firstMatch(window, where: {
            identifier($0).hasPrefix("session_item_") && bool($0, "AXSelected")
        }), let name = WeChatParsing.selectedSessionName(from: identifier(selectedSessionRow), isSelected: true) {
            return WeChatConversationDetection(contact: name, windowFound: true, treeCollapsed: false,
                                              visionSnapshot: nil, backend: backend,
                                              mainWindowLookupMilliseconds: windowLookupMilliseconds,
                                              capabilityProbeMilliseconds: backendInfo.probeMilliseconds)
        }
        // A semantic backend that exposes messages but no dependable title
        // still uses Vision for identity, without repeating recursive AX scans.
        if backend == .accessibility && !titleAXAvailable {
            let snapshot = visibleTitleIdentity(for: window, forceFresh: forceFreshVision)
            return WeChatConversationDetection(contact: snapshot?.title, windowFound: true,
                                              treeCollapsed: false, visionSnapshot: snapshot,
                                              backend: backend,
                                              mainWindowLookupMilliseconds: windowLookupMilliseconds,
                                              capabilityProbeMilliseconds: backendInfo.probeMilliseconds)
        }
        let snapshot = visibleTitleIdentity(for: window, forceFresh: forceFreshVision)
        return WeChatConversationDetection(
            contact: snapshot?.title,
            windowFound: true,
            treeCollapsed: backend == .vision,
            visionSnapshot: snapshot,
            backend: backend,
            mainWindowLookupMilliseconds: windowLookupMilliseconds,
            capabilityProbeMilliseconds: backendInfo.probeMilliseconds
        )
    }

    func readMessages(limit: Int = 50, accurateVision: Bool = false, forceFresh: Bool = true,
                      previousFingerprint: String? = nil) -> MessageReadResult {
        guard let window = mainWindow() else { return .messageListUnavailable(treeCollapsed: false, visionState: nil) }
        guard let app = weChatApplication() else { return .messageListUnavailable(treeCollapsed: false, visionState: nil) }
        let backend = backendState(for: app.processIdentifier, window: window).backend
        if backend == .vision {
            return readVisibleMessages(in: window, limit: limit, accurate: accurateVision, treeCollapsed: true,
                                       forceFresh: forceFresh, previousFingerprint: previousFingerprint) ??
                .messageListUnavailable(treeCollapsed: true, visionState: nil)
        }

        // 1. Stable WeChat 4.x message-list identifier.
        if let list = firstMatch(window, where: {
            string($0, "AXRole") == "AXList" && identifier($0) == WeChatParsing.messageListIdentifier
        }) {
            return readRows(in: list, limit: limit)
        }

        // 2. Localized AXTitle fallback.
        if let list = firstMatch(window, where: {
            string($0, "AXRole") == "AXList" && ["Messages", "消息"].contains(string($0, "AXTitle") ?? "")
        }) {
            return readRows(in: list, limit: limit)
        }

        // 3. Conservative older-client fallback: only inspect AXLists under a
        // large right-side scroll area when the chat composer is also present.
        guard hasConversationComposer(in: window) else {
            if let result = readVisibleMessages(in: window, limit: limit, accurate: accurateVision, treeCollapsed: false,
                                                forceFresh: forceFresh, previousFingerprint: previousFingerprint) { return result }
            return .messageListUnavailable(treeCollapsed: false, visionState: nil)
        }
        let windowFrame = frame(window)
        let paneAreas = find(window) {
            guard string($0, "AXRole") == "AXScrollArea" else { return false }
            let bounds = frame($0)
            return bounds.minX > windowFrame.minX + windowFrame.width * 0.25 &&
                bounds.width > 220 && bounds.height > 300
        }
        for area in paneAreas {
            if let list = firstMatch(area, depth: 8, where: { string($0, "AXRole") == "AXList" }) {
                return readRows(in: list, limit: limit)
            }
        }
        if let result = readVisibleMessages(in: window, limit: limit, accurate: accurateVision, treeCollapsed: false,
                                            forceFresh: forceFresh, previousFingerprint: previousFingerprint) { return result }
        return .messageListUnavailable(treeCollapsed: false, visionState: nil)
    }

    func scrollMessagePaneUpwardIfConversationMatches(
        contact: String,
        identity: VisionConversationIdentity?,
        fraction: CGFloat,
        cancellation: MonitorWorkCancellation?
    ) -> OlderContextScrollResult {
        scrollMessagePaneIfConversationMatches(contact: contact, identity: identity, fraction: fraction,
                                               cancellation: cancellation, direction: .older)
    }

    func scrollMessagePaneUpOnePageIfConversationMatches(contact: String) -> OlderContextScrollResult {
        scrollAccessibilityMessagePane(contact: contact, direction: .older)
    }

    func scrollMessagePaneDownOnePageIfConversationMatches(contact: String) -> OlderContextScrollResult {
        scrollAccessibilityMessagePane(contact: contact, direction: .newer)
    }

    private func scrollAccessibilityMessagePane(contact: String, direction: ChatScrollDirection) -> OlderContextScrollResult {
        guard let app = weChatApplication(), let window = mainWindow() else { return .windowUnavailable }
        guard accessibilityContact(in: window, app: app).map(WeChatParsing.conversationIdentityKey) ==
                WeChatParsing.conversationIdentityKey(contact) else { return .identityUncertain }
        guard let list = messageListElement(in: window) else { return .scrollUnavailable }

        let areas = find(window) {
            guard string($0, "AXRole") == "AXScrollArea" else { return false }
            let bounds = frame($0)
            let outer = frame(window)
            return bounds.minX > outer.minX + outer.width * 0.25 && bounds.width > 220 && bounds.height > 300
        }
        let candidates = areas + [list]
        let action = direction == .older ? "AXScrollUpByPage" : "AXScrollDownByPage"
        for candidate in candidates {
            var rawActions: CFArray?
            guard AXUIElementCopyActionNames(candidate, &rawActions) == .success,
                  let actions = rawActions as? [String], actions.contains(action) else { continue }
            if AXUIElementPerformAction(candidate, action as CFString) == .success { return .scrolled }
        }

        // Fallback to a targeted scroll event after verifying the same AX chat.
        let windowFrame = frame(window, timeout: 0.08)
        let calibration = VisionLayoutCalibration.current
        let yRatioFromTop = 1 - ((calibration.composerTopY + calibration.headerBottomY) * 0.5)
        let location = CGPoint(
            x: windowFrame.minX + windowFrame.width * (calibration.conversationLeftX + (1 - calibration.conversationLeftX) * 0.5),
            y: windowFrame.minY + windowFrame.height * yRatioFromTop
        )
        guard windowFrame.insetBy(dx: 8, dy: 8).contains(location) else { return .scrollUnavailable }
        let amount = Int32(min(500, max(120, windowFrame.height * 0.45)))
        let signedAmount = direction == .older ? amount : -amount
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: signedAmount, wheel2: 0, wheel3: 0) else { return .scrollUnavailable }
        event.location = location
        event.postToPid(app.processIdentifier)
        return .scrolled
    }

    func scrollMessagePaneDownwardIfConversationMatches(
        contact: String,
        identity: VisionConversationIdentity?,
        fraction: CGFloat,
        cancellation: MonitorWorkCancellation?
    ) -> OlderContextScrollResult {
        scrollMessagePaneIfConversationMatches(contact: contact, identity: identity, fraction: fraction,
                                               cancellation: cancellation, direction: .newer)
    }

    private func scrollMessagePaneIfConversationMatches(
        contact: String,
        identity: VisionConversationIdentity?,
        fraction: CGFloat,
        cancellation: MonitorWorkCancellation?,
        direction: ChatScrollDirection
    ) -> OlderContextScrollResult {
        guard cancellation?.isCancelled != true else { return .cancelled }
        let detection = detectCurrentConversation(forceFreshVision: true)
        switch olderContextIdentityCheck(detection, contact: contact, identity: identity) {
        case .changed: return .conversationChanged
        case .uncertain: return .identityUncertain
        case .matches: break
        }
        guard let app = weChatApplication(), let window = mainWindow() else { return .windowUnavailable }
        guard cancellation?.isCancelled != true else { return .cancelled }
        let windowFrame = frame(window, timeout: 0.08)
        guard windowFrame.width >= 400, windowFrame.height >= 300 else { return .windowUnavailable }
        let calibration = VisionLayoutCalibration.current
        let canvasHeight = calibration.headerBottomY - calibration.composerTopY
        guard canvasHeight > 0.1 else { return .scrollUnavailable }
        let xRatio = calibration.conversationLeftX + (1 - calibration.conversationLeftX) * 0.5
        let yRatioFromTop = 1 - ((calibration.composerTopY + calibration.headerBottomY) * 0.5)
        let location = CGPoint(
            x: windowFrame.minX + windowFrame.width * xRatio,
            y: windowFrame.minY + windowFrame.height * yRatioFromTop
        )
        guard windowFrame.insetBy(dx: 8, dy: 8).contains(location) else { return .scrollUnavailable }
        let amount = Int32(min(500, max(120, windowFrame.height * canvasHeight * min(0.60, max(0.40, fraction)))))
        // Positive vertical wheel delta scrolls toward older transcript rows;
        // negative delta returns toward the newest rows. Posting to the WeChat
        // PID targets its window without clicking or changing the selection.
        let signedAmount = direction == .older ? amount : -amount
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: signedAmount, wheel2: 0, wheel3: 0) else { return .scrollUnavailable }
        event.location = location
        event.postToPid(app.processIdentifier)
        return .scrolled
    }

    func readMessagesIfConversationMatches(
        contact: String,
        identity: VisionConversationIdentity?,
        accurate: Bool,
        forceFresh: Bool = true,
        cancellation: MonitorWorkCancellation?
    ) -> OlderContextReadResult {
        guard cancellation?.isCancelled != true else { return .cancelled }
        let detection = detectCurrentConversation(forceFreshVision: true)
        switch olderContextIdentityCheck(detection, contact: contact, identity: identity) {
        case .changed: return .conversationChanged
        case .uncertain: return .identityUncertain
        case .matches:
            guard cancellation?.isCancelled != true else { return .cancelled }
            let result = readMessages(limit: 50, accurateVision: accurate, forceFresh: forceFresh,
                                      previousFingerprint: nil)
            guard cancellation?.isCancelled != true else { return .cancelled }
            let confirmation = detectCurrentConversation(forceFreshVision: true)
            switch olderContextIdentityCheck(confirmation, contact: contact, identity: identity) {
            case .changed: return .conversationChanged
            case .uncertain: return .identityUncertain
            case .matches: return .messages(result)
            }
        }
    }

    private func olderContextIdentityCheck(
        _ detection: WeChatConversationDetection,
        contact: String,
        identity: VisionConversationIdentity?
    ) -> OlderContextIdentityCheck {
        guard let detectedContact = detection.contact, !detectedContact.isEmpty else { return .uncertain }
        guard WeChatParsing.conversationIdentityKey(detectedContact) == WeChatParsing.conversationIdentityKey(contact) else {
            return .changed
        }
        guard let identity else { return .matches }
        guard let detectedIdentity = detection.visionSnapshot?.titleIdentity else { return .uncertain }
        return identity.isSpatiallyConsistent(with: detectedIdentity) ? .matches : .uncertain
    }

    private func readVisibleMessages(in window: AXUIElement, limit: Int, accurate: Bool,
                                     treeCollapsed: Bool, forceFresh: Bool = true,
                                     previousFingerprint: String? = nil) -> MessageReadResult? {
        guard let app = weChatApplication() else { return nil }
        let snapshot = WeChatScreenReader.shared.readMessages(
            pid: app.processIdentifier, windowFrame: frame(window, timeout: 0.08),
            forceFresh: forceFresh, accurate: accurate, previousFingerprint: previousFingerprint
        )
        guard snapshot.captureSucceeded else {
            return .messageListUnavailable(
                treeCollapsed: treeCollapsed,
                visionState: snapshot.captureState
            )
        }
        if snapshot.messageFrameUnchanged, let fingerprint = snapshot.messageFingerprint {
            return .messageListUnchanged(fingerprint: fingerprint)
        }
        let messages = Array(snapshot.messages.suffix(limit))
        return .messageListFound(
            messages: messages,
            renderedRows: snapshot.ocrObservationCount,
            bubbleRows: messages.count,
            placeholders: 0,
            isVision: true,
            fingerprint: snapshot.messageFingerprint
        )
    }

    private func visibleSnapshot(for window: AXUIElement, forceFresh: Bool = false) -> VisibleWeChatSnapshot? {
        guard let app = weChatApplication() else { return nil }
        return WeChatScreenReader.shared.read(pid: app.processIdentifier, windowFrame: frame(window, timeout: 0.08), forceFresh: forceFresh)
    }

    private func visibleTitleIdentity(for window: AXUIElement, forceFresh: Bool = false) -> VisibleWeChatSnapshot? {
        guard let app = weChatApplication() else { return nil }
        return WeChatScreenReader.shared.readTitleIdentity(
            pid: app.processIdentifier, windowFrame: frame(window, timeout: 0.08), forceFresh: forceFresh
        )
    }

    func visionDiagnosticReport() -> String {
        guard let app = weChatApplication() else {
            return "Screen Recording permission: \(WeChatScreenReader.hasScreenCapturePermission ? "granted" : "not granted")\nTarget WeChat PID: unavailable\nWindow capture: WeChat window not found\n"
        }
        guard let window = mainWindow() else {
            return "Screen Recording permission: \(WeChatScreenReader.hasScreenCapturePermission ? "granted" : "not granted")\nTarget WeChat PID: \(app.processIdentifier)\nWindow capture: WeChat window not found\n"
        }
        return "\(readerBackendDiagnostic)\n\(WeChatScreenReader.shared.diagnosticReport(pid: app.processIdentifier, windowFrame: frame(window)))"
    }

    func annotatedVisionPreview() -> NSImage? {
        guard let app = weChatApplication(), let window = mainWindow() else { return nil }
        return WeChatScreenReader.shared.annotatedPreview(pid: app.processIdentifier, windowFrame: frame(window))
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
            placeholders: placeholders,
            isVision: false,
            fingerprint: nil
        )
    }

    private func hasConversationComposer(in root: AXUIElement) -> Bool {
        let bounds = frame(root)
        return firstMatch(root, depth: 16) { element in
            guard string(element, "AXRole") == "AXTextArea" else { return false }
            let rect = frame(element)
            return rect.minX > bounds.minX + bounds.width * 0.25 &&
                rect.minY > bounds.minY + bounds.height * 0.65 &&
                rect.width > 180 && rect.height > 30
        } != nil
    }

    func accessibilityTreeAppearsCollapsed() -> Bool {
        guard let window = mainWindow(), let app = weChatApplication() else { return false }
        return backendState(for: app.processIdentifier, window: window).backend == .vision
    }

    private func accessibilityTreeAppearsCollapsed(in window: AXUIElement) -> Bool {
        guard let app = weChatApplication() else { return false }
        return backendState(for: app.processIdentifier, window: window).backend == .vision
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

    private final class CapabilityProbeResult: @unchecked Sendable {
        private let lock = NSLock()
        private var result: AXCapabilityProbe?
        func set(_ result: AXCapabilityProbe) { lock.lock(); self.result = result; lock.unlock() }
        func get() -> AXCapabilityProbe? { lock.lock(); defer { lock.unlock() }; return result }
    }

    private final class ProbeCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func cancel() { lock.lock(); value = true; lock.unlock() }
    }
}
