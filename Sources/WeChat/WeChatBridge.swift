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
    let identitySource: ConversationCaptureSource
    let messageSource: ConversationCaptureSource
    let messageExtractionTrustworthy: Bool
    let visionIdentity: VisionConversationIdentity?
    let paneGeometry: ConversationPaneGeometry
    let messageFingerprint: String?
    let headerFingerprint: String?
    let messagePaneLeftX: CGFloat?
    let messagesUnchanged: Bool
    let headerUnchanged: Bool
    let captureTimingDiagnostic: String
    let liveEdgeState: Bool?

    var hasTrustworthyTranscript: Bool {
        paneGeometry.isValidated && messageExtractionTrustworthy && !messages.isEmpty &&
            messages.allSatisfy { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// A local observation that can be retained while conversation identity is
/// still being resolved. Callers must not send it to automatic analysis.
struct PendingConversationObservation: Sendable {
    let messages: [ObservedMessage]
    let messageRowCount: Int
    let messageSource: ConversationCaptureSource
    let visionIdentity: VisionConversationIdentity?
    let headerFingerprint: String?
    let paneGeometry: ConversationPaneGeometry
}

enum ConversationCaptureFailure: Sendable {
    case screenRecordingPermissionRequired
    case windowUnavailable
    case identityUnavailable
    case messagesUnavailable
    case visionCaptureFailed
    case axProbeUncertain
    case accessibilityExtractionFailed(stage: String)

    var userMessage: String {
        switch self {
        case .screenRecordingPermissionRequired:
            return "Allow WeChat Reply Copilot in System Settings → Privacy & Security → Screen Recording, then reopen the app."
        case .windowUnavailable:
            return "WeChat conversation window is unavailable. Open a chat window and try again."
        case .identityUnavailable:
            return "WeChat window found, but the conversation title could not be identified."
        case .messagesUnavailable:
            return "Conversation identified, but the message area could not be read."
        case .visionCaptureFailed:
            return "WeChat is open, but its window could not be captured. Check Screen Recording permission and try again."
        case .accessibilityExtractionFailed(let stage):
            return "Accessibility extraction failed: \(stage). Refresh after opening the conversation."
        case .axProbeUncertain:
            return "WeChat accessibility data is incomplete and no usable capture source was found."
        }
    }
}

enum ConversationCaptureResult: Sendable {
    case success(WeChatSnapshot)
    case identityPending(PendingConversationObservation)
    case failure(ConversationCaptureFailure)
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
    case snapshot(WeChatSnapshot)
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
    private let accessibilityTimeout: Float = 0.03
    private let backendLock = NSCondition()
    private var backendPID: pid_t?
    private var readerBackend: WeChatReaderBackend = .unknown
    private var backendProbeMilliseconds = 0
    private var backendProbeResult = "not yet run"
    private var backendProbeNodes = 0
    private var backendProbeInProgress = false
    private var semanticTitleAvailable = false
    private let captureDiagnosticLock = NSLock()
    private var lastCapturePlan: ConversationCapturePlan?
    private var lastAXIdentityAvailable = false
    private var lastAXTitleAvailable = false
    private var lastAXMessageListAvailable = false
    private var lastCaptureFailure = "not captured yet"
    private var lastCaptureTimingDiagnostic = "Capture timings: unavailable"
    private var cachedAXWindow: AXUIElement?
    private var cachedAXWindowPID: pid_t?
    private var capabilityProbeWindow: AXUIElement?
    private var cachedCapabilityProbe: AXCapabilityProbe?
    private var activeCapturePlan: ConversationCapturePlan?
    private var activePlanPID: pid_t?
    private var activePlanWindow: AXUIElement?
    private var activePlanWindowFrame: CGRect?
    private var visionTitleTracker = VisionTitleTracker()

    private var geometryWindow: AXUIElement?
    private var geometryViewport: AXUIElement?
    private var geometryComposer: AXUIElement?
    private var geometrySource: ConversationPaneGeometrySource?
    private var lastAttempt = CaptureAttemptDiagnostics()

    private func discoveryChildren(_ element: AXUIElement) -> [AXUIElement] {
        let role = string(element, "AXRole", timeout: 0.01)
        if role == "AXTable" || role == "AXList" {
            // Virtualized tables can contain hundreds of off-screen sidebar
            // rows. Only their visible rows are relevant to discovery.
            return boundedChildren(element, attribute: "AXVisibleChildren", maximum: 24) ?? []
        }
        return boundedChildren(element, maximum: 40) ?? []
    }

    private var captureLatencies: [(milliseconds: Int, validated: Bool)] = []
    private var lastAXReadDiagnostic = "AX rows: not read"

    /// One IPC request for independent row attributes; unavailable fields stay nil.
    private func attributes(_ element: AXUIElement, _ names: [String]) -> [String: Any] {
        AXUIElementSetMessagingTimeout(element, 0.02)
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &raw) == .success,
              let values = raw as? [Any], values.count == names.count else { return [:] }
        return Dictionary(uniqueKeysWithValues: zip(names, values).map { ($0, $1) })
    }

    private func boundedChildren(_ element: AXUIElement, attribute: String = "AXChildren", maximum: Int = 200) -> [AXUIElement]? {
        AXUIElementSetMessagingTimeout(element, 0.02)
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(element, attribute as CFString, &count) == .success else { return nil }
        if count == 0 { return [] }
        var raw: CFArray?
        let amount = min(count, maximum)
        guard AXUIElementCopyAttributeValues(element, attribute as CFString, max(0, count - amount), amount, &raw) == .success else { return nil }
        return raw as? [AXUIElement]
    }

    var captureAttemptDiagnostics: CaptureAttemptDiagnostics {
        captureDiagnosticLock.lock()
        defer { captureDiagnosticLock.unlock() }
        return lastAttempt
    }

    var capturePerformanceSummary: String {
        captureDiagnosticLock.lock()
        defer { captureDiagnosticLock.unlock() }
        guard let latest = captureLatencies.last else { return "Capture latency: no completed samples" }
        let sorted = captureLatencies.filter(\.validated).map(\.milliseconds).sorted()
        guard !sorted.isEmpty else { return "Last capture: \(latest.milliseconds) ms · no validated latency samples (\(captureLatencies.count) attempts)" }
        func percentile(_ fraction: Double) -> Int { sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)] }
        return "Last capture: \(latest.milliseconds) ms · validated P50 \(percentile(0.5)) / P95 \(percentile(0.95)) ms · \(sorted.count)/\(captureLatencies.count) samples"
    }

    private struct AXSessionElement {
        let identifier: String
        let element: AXUIElement
    }

    private struct AXCapabilityProbe {
        let title: String?
        let selectedSession: String?
        let hasMessageList: Bool
        let titleElement: AXUIElement?
        let sessionElements: [AXSessionElement]
        let messageListElement: AXUIElement?
        let visitedNodes: Int
        let timedOut: Bool
        var hasAXIdentity: Bool { title != nil || selectedSession != nil }
        var hasAXMessageList: Bool { hasMessageList }
        var supportsFullAccessibility: Bool { hasAXIdentity && hasAXMessageList }
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
            capabilityProbeWindow = nil
            cachedCapabilityProbe = nil
            activeCapturePlan = nil
            activePlanPID = nil
            activePlanWindow = nil
            activePlanWindowFrame = nil
            visionTitleTracker.reset()
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
        boundedSearch(root, depth: depth, stopAtFirst: false, predicate: predicate)
    }

    private func firstMatch(_ root: AXUIElement, depth: Int = 24, where predicate: (AXUIElement) -> Bool) -> AXUIElement? {
        boundedSearch(root, depth: depth, stopAtFirst: true, predicate: predicate).first
    }

    private func boundedSearch(_ root: AXUIElement, depth: Int, stopAtFirst: Bool,
                               predicate: (AXUIElement) -> Bool) -> [AXUIElement] {
        var stack = [(root, 0)]
        var matches: [AXUIElement] = []
        var visited = 0
        let deadline = Date().addingTimeInterval(0.55)
        while visited < stack.count, visited < 300, Date() < deadline {
            let (node, level) = stack[visited]
            visited += 1
            if predicate(node) {
                matches.append(node)
                if stopAtFirst { break }
            }
            if level < min(depth, 18) {
                stack.append(contentsOf: discoveryChildren(node).map { ($0, level + 1) })
            }
        }
        return matches
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
        AXUIElementSetMessagingTimeout(element, 0.03)
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
        if let focused = windowElement(app, attribute: "AXFocusedWindow", timeout: 0.08),
           isUsableConversationWindow(focused) {
            cacheMainWindow(focused, pid: pid)
            return focused
        }
        // A transient dialog or preferences window may be focused while the
        // real conversation is still present. Continue to cached/main/windows
        // candidates rather than declaring WeChat unavailable.
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
        if cachedAXWindowPID != pid || cachedAXWindow.map({ !CFEqual($0, window) }) == true {
            activeCapturePlan = nil
            activePlanPID = nil
            activePlanWindow = nil
            activePlanWindowFrame = nil
            visionTitleTracker.reset()
            if backendPID != pid || capabilityProbeWindow.map({ !CFEqual($0, window) }) == true {
                cachedCapabilityProbe = nil
                readerBackend = .unknown
            }
        }
        cachedAXWindow = window
        cachedAXWindowPID = pid
        backendLock.unlock()
    }

    private func backendState(for pid: pid_t, window: AXUIElement) -> (backend: WeChatReaderBackend, probeMilliseconds: Int, initialProbe: AXCapabilityProbe?) {
        backendLock.lock()
        while backendPID == pid && backendProbeInProgress { backendLock.wait() }
        if backendPID == pid, readerBackend != .unknown,
           let capabilityProbeWindow, CFEqual(capabilityProbeWindow, window) {
            let value = (readerBackend, 0, cachedCapabilityProbe)
            backendLock.unlock()
            return value
        }
        backendPID = pid
        capabilityProbeWindow = window
        cachedCapabilityProbe = nil
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
        let observedProbe = completed ? result.get() : nil
        let probe = observedProbe ?? AXCapabilityProbe(
            title: nil, selectedSession: nil, hasMessageList: false, titleElement: nil,
            sessionElements: [], messageListElement: nil, visitedNodes: 0, timedOut: true
        )
        let selected: WeChatReaderBackend = probe.supportsFullAccessibility ? .accessibility : .vision
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        backendLock.lock()
        // A PID change during the asynchronous probe invalidates its result.
        if backendPID == pid {
            readerBackend = selected
            cachedCapabilityProbe = probe
            backendProbeMilliseconds = elapsed
            backendProbeNodes = probe.visitedNodes
            backendProbeResult = observedProbe == nil ? "deadline exceeded; mixed-source capture" :
                (probe.supportsFullAccessibility ? "AX identity and message list found" : "partial AX tree; mixed-source capture")
            semanticTitleAvailable = probe.hasAXIdentity
            backendProbeInProgress = false
            backendLock.broadcast()
        }
        let current = backendPID == pid
            ? (readerBackend, backendProbeMilliseconds, Optional(probe))
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
        var titleElement: AXUIElement?
        var sessionElements: [AXSessionElement] = []
        var hasMessageList = false
        var messageList: AXUIElement?
        let shortTimeout: Float = 0.02
        while visited < stack.count, visited < 96 {
            let (element, depth) = stack[visited]
            if cancellation.isCancelled || Date() >= deadline { break }
            visited += 1
            let id = identifier(element, timeout: shortTimeout)
            if id == WeChatParsing.chatTitleIdentifier {
                let raw = string(element, "AXValue", timeout: shortTimeout) ?? string(element, "AXTitle", timeout: shortTimeout) ?? ""
                let normalized = WeChatParsing.normalizeChatTitle(raw)
                if !normalized.isEmpty && !WeChatParsing.isGenericWindowTitle(normalized) {
                    title = normalized
                    titleElement = element
                }
            }
            if id.hasPrefix("session_item_") {
                sessionElements.append(AXSessionElement(identifier: id, element: element))
                if bool(element, "AXSelected", timeout: shortTimeout) {
                    selectedSession = WeChatParsing.selectedSessionName(from: id, isSelected: true)
                }
            }
            if id == WeChatParsing.messageListIdentifier {
                hasMessageList = true
                messageList = element
            }
            if depth < 8, Date() < deadline {
                stack.append(contentsOf: discoveryChildren(element).map { ($0, depth + 1) })
            }
            if (title != nil || selectedSession != nil) && hasMessageList { break }
        }
        return AXCapabilityProbe(title: title, selectedSession: selectedSession,
                                 hasMessageList: hasMessageList, titleElement: titleElement,
                                 sessionElements: sessionElements, messageListElement: messageList,
                                 visitedNodes: visited,
                                 timedOut: Date() >= deadline || visited >= 96)
    }

    private func targetedAXFallback(in window: AXUIElement, base: AXCapabilityProbe) -> (probe: AXCapabilityProbe, attempted: Bool, milliseconds: Int) {
        let started = Date()
        let deadline = started.addingTimeInterval(0.60)
        var stack: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        var title = base.title
        var selectedSession = base.selectedSession
        var titleElement = base.titleElement
        var sessionElements = base.sessionElements
        var messageList = base.messageListElement
        var foundList = base.hasMessageList
        while visited < stack.count, visited < 250, Date() < deadline {
            let (element, depth) = stack[visited]
            visited += 1
            let id = identifier(element, timeout: 0.006)
            if id == WeChatParsing.chatTitleIdentifier, title == nil {
                let raw = string(element, "AXValue", timeout: 0.006) ?? string(element, "AXTitle", timeout: 0.006) ?? ""
                let normalized = WeChatParsing.normalizeChatTitle(raw)
                if !normalized.isEmpty && !WeChatParsing.isGenericWindowTitle(normalized) {
                    title = normalized
                    titleElement = element
                }
            }
            if id.hasPrefix("session_item_") {
                if !sessionElements.contains(where: { $0.identifier == id }) {
                    sessionElements.append(AXSessionElement(identifier: id, element: element))
                }
                if selectedSession == nil, bool(element, "AXSelected", timeout: 0.006) {
                    selectedSession = WeChatParsing.selectedSessionName(from: id, isSelected: true)
                }
            }
            if !foundList, id == WeChatParsing.messageListIdentifier {
                foundList = true
                messageList = element
            }
            if depth < 18, Date() < deadline {
                stack.append(contentsOf: discoveryChildren(element).map { ($0, depth + 1) })
            }
            if (title != nil || selectedSession != nil) && foundList { break }
        }
        let probe = AXCapabilityProbe(title: title, selectedSession: selectedSession,
                                      hasMessageList: foundList, titleElement: titleElement,
                                      sessionElements: sessionElements, messageListElement: messageList,
                                      visitedNodes: base.visitedNodes + visited,
                                      timedOut: Date() >= deadline || visited >= 250)
        return (probe, true, Int(Date().timeIntervalSince(started) * 1000))
    }

    private func cacheCapabilityProbe(_ probe: AXCapabilityProbe, pid: pid_t, window: AXUIElement) {
        backendLock.lock()
        guard backendPID == pid, let capabilityProbeWindow, CFEqual(capabilityProbeWindow, window) else {
            backendLock.unlock()
            return
        }
        cachedCapabilityProbe = probe
        if probe.supportsFullAccessibility { readerBackend = .accessibility }
        semanticTitleAvailable = probe.hasAXIdentity
        backendProbeNodes = probe.visitedNodes
        backendProbeResult = probe.supportsFullAccessibility ? "AX identity and message list found" :
            (probe.timedOut ? "bounded AX search timed out; Vision fallback available" : "partial AX tree; Vision fallback available")
        backendLock.unlock()
    }

    private func cachedPlan(for pid: pid_t, window: AXUIElement) -> ConversationCapturePlan? {
        backendLock.lock()
        let matches = activePlanPID == pid && activePlanWindow.map { CFEqual($0, window) } == true
        let plan = matches ? activeCapturePlan : nil
        let storedFrame = matches ? activePlanWindowFrame : nil
        backendLock.unlock()
        guard let plan else { return nil }
        let currentFrame = frame(window, timeout: 0.08)
        let driftLimit = max(140, (storedFrame?.width ?? currentFrame.width) * 0.12)
        let drift = storedFrame.map {
            abs($0.minX - currentFrame.minX) + abs($0.minY - currentFrame.minY) +
                abs($0.width - currentFrame.width) + abs($0.height - currentFrame.height)
        }
        guard drift.map({ $0 <= driftLimit }) ?? true else {
            beginConversationSession()
            return nil
        }
        return plan
    }

    private func cacheActivePlan(_ plan: ConversationCapturePlan, pid: pid_t, window: AXUIElement) {
        let windowFrame = frame(window, timeout: 0.08)
        backendLock.lock()
        let sameSessionWindow = activePlanPID == pid && activePlanWindow.map { CFEqual($0, window) } == true
        activeCapturePlan = plan
        activePlanPID = pid
        activePlanWindow = window
        if !sameSessionWindow || activePlanWindowFrame == nil {
            activePlanWindowFrame = windowFrame
        }
        backendLock.unlock()
    }

    /// Capture-source choices are scoped to one explicit monitoring session.
    /// Keep the general AX capability probe, but never carry a selected source
    /// plan into a later activation.
    func beginConversationSession() {
        backendLock.lock()
        activeCapturePlan = nil
        activePlanPID = nil
        activePlanWindow = nil
        activePlanWindowFrame = nil
        geometryWindow = nil; geometryViewport = nil; geometryComposer = nil; geometrySource = nil
        visionTitleTracker.reset()
        backendLock.unlock()
    }

    func endConversationSession() { beginConversationSession() }

    private func resolveVisionTitle(_ title: String, identity: VisionConversationIdentity) -> String? {
        backendLock.lock()
        defer { backendLock.unlock() }
        return visionTitleTracker.resolve(title: title, identity: identity)
    }

    private func resetPendingVisionTitle() {
        backendLock.lock()
        visionTitleTracker.reset()
        backendLock.unlock()
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
        capabilityProbeWindow = nil
        cachedCapabilityProbe = nil
        activeCapturePlan = nil
        activePlanPID = nil
        activePlanWindow = nil
        activePlanWindowFrame = nil
        geometryWindow = nil; geometryViewport = nil; geometryComposer = nil; geometrySource = nil
        visionTitleTracker.reset()
        backendLock.broadcast()
        backendLock.unlock()
    }

    func currentContact() -> String? {
        detectCurrentConversation().contact
    }

    /// Captures one unified conversation observation, choosing AX, hybrid, or
    /// Vision independently for identity and message rows. When both AX pieces
    /// are available, they come from the same window and message-list element.
    func captureConversationSnapshot(limit: Int? = nil, forceFresh: Bool = true,
                                    accurateVision: Bool = false,
                                    previousHeaderFingerprint: String? = nil,
                                    previousMessageFingerprint: String? = nil,
                                    lockedContact: String? = nil,
                                    initialActivation: Bool = false,
                                    messagePaneLeftX: CGFloat? = nil,
                                    paneGeometry: ConversationPaneGeometry? = nil) -> ConversationCaptureResult {
        let totalStarted = Date()
        var validatedCapture = false
        var attempt = CaptureAttemptDiagnostics()
        defer {
            captureDiagnosticLock.lock()
            attempt.hasRun = true
            attempt.durationMilliseconds = Int(Date().timeIntervalSince(totalStarted) * 1000)
            attempt.acceptedCount = validatedCapture ? attempt.candidateCount : 0
            attempt.rejectionReason = lastCaptureFailure == "none"
                ? (validatedCapture ? nil : (attempt.geometryVerified ? "message content unverified" : "transcript geometry unverified"))
                : lastCaptureFailure
            lastAttempt = attempt
            captureLatencies.append((attempt.durationMilliseconds, validatedCapture))
            captureLatencies = Array(captureLatencies.suffix(200))
            captureDiagnosticLock.unlock()
        }
        guard let window = mainWindow(), let app = weChatApplication() else {
            updateCaptureDiagnostic(plan: nil, hasAXIdentity: false, hasAXMessages: false,
                                    failure: "WeChat window unavailable")
            return .failure(.windowUnavailable)
        }
        var windowPID: pid_t = 0
        guard AXUIElementGetPid(window, &windowPID) == .success, windowPID == app.processIdentifier else {
            updateCaptureDiagnostic(plan: nil, hasAXIdentity: false, hasAXMessages: false,
                                    failure: "WeChat window identity unavailable")
            return .failure(.windowUnavailable)
        }
        let windowFrame = frame(window, timeout: 0.08)
        let calibration = VisionLayoutCalibration.current
        let reusableGeometry = paneGeometry.flatMap { candidate -> ConversationPaneGeometry? in
            backendLock.lock()
            let previousFrame = activePlanWindowFrame
            backendLock.unlock()
            guard candidate.source == .visualDivider,
                  previousFrame?.size == windowFrame.size else { return nil }
            return candidate
        }
        let resolvedGeometry = accessibilityPaneGeometry(in: window, windowFrame: windowFrame) ?? reusableGeometry ??
            VisionLayoutRegions.geometry(
                leftX: messagePaneLeftX ?? calibration.messagePaneLeftX,
                headerBottomY: calibration.headerBottomY, composerTopY: calibration.composerTopY,
                source: .configuredFallback, confidence: 0.40
            )

        attempt.geometryVerified = resolvedGeometry.isValidated

        // Reuse the successful plan and its AX elements during monitoring. On
        // activation, the bounded probe is only a hint; a single targeted,
        // deeper fallback can recover elements the fast probe missed.
        let reusedPlan = cachedPlan(for: app.processIdentifier, window: window)
        let capability = backendState(for: app.processIdentifier, window: window)
        let fastProbe = capability.initialProbe
        var probe = fastProbe
        var fallbackAttempted = false
        var fallbackMilliseconds = 0
        if reusedPlan == nil, initialActivation, let currentProbe = probe,
           (!currentProbe.hasAXIdentity || !currentProbe.hasAXMessageList) {
            let fallback = targetedAXFallback(in: window, base: currentProbe)
            probe = fallback.probe
            fallbackAttempted = fallback.attempted
            fallbackMilliseconds = fallback.milliseconds
            cacheCapabilityProbe(fallback.probe, pid: app.processIdentifier, window: window)
        }
        let axResolutionStarted = Date()
        // A Vision choice is not permanent: AX identity may become readable
        // after a transiently collapsed tree. Recheck the already bounded/cached
        // AX identity path, especially when no contact has been locked yet.
        let axIdentity = accessibilityIdentity(in: window, app: app)
        let axContact = axIdentity.contact
        let list = reusedPlan?.messages == .vision ? nil : messageListElement(in: window)
        let axResolutionMilliseconds = Int(Date().timeIntervalSince(axResolutionStarted) * 1000)
        backendLock.lock()
        semanticTitleAvailable = axContact != nil
        backendLock.unlock()
        let plan: ConversationCapturePlan?
        if let reusedPlan {
            plan = ConversationCapturePlan(
                identity: axContact != nil ? .accessibility :
                    (reusedPlan.identity == .accessibility ? .vision : reusedPlan.identity),
                messages: reusedPlan.messages == .accessibility && list == nil ? .vision : reusedPlan.messages
            )
        } else {
            plan = ConversationCapturePlan.select(hasAXIdentity: axContact != nil,
                                                  hasAXMessages: list != nil)
        }
        guard let plan else {
            updateCaptureDiagnostic(plan: nil, hasAXIdentity: axContact != nil, hasAXMessages: list != nil,
                                    failure: "Bounded AX probe and activation fallback found no usable AX source",
                                    hasAXTitle: axIdentity.hasTitle,
                                    timing: axProbeDiagnostic(fastProbe, resolvedProbe: probe,
                                                              fallbackAttempted: fallbackAttempted,
                                                              fallbackMilliseconds: fallbackMilliseconds))
            return .failure(.axProbeUncertain)
        }

        let capturePlan = plan
        attempt.source = plan.messages
        var capturedAXMessages: [ChatMessage]?
        var capturedAXRowCount = 0
        var axMessageReadMilliseconds = 0
        var axHasUnreadableBubbles = false
        if plan.messages == .accessibility, let list {
            let readStarted = Date()
            let parsed = readAccessibilityMessages(in: list, limit: max(0, limit ?? 50))
            attempt.rawCount = parsed.bubbles
            attempt.candidateCount = parsed.messages.count
            axMessageReadMilliseconds = Int(Date().timeIntervalSince(readStarted) * 1000)
            if let failure = parsed.failure {
                updateCaptureDiagnostic(plan: plan, hasAXIdentity: axContact != nil, hasAXMessages: true,
                    failure: failure, hasAXTitle: axIdentity.hasTitle)
                return .failure(.accessibilityExtractionFailed(stage: failure))
            }
            capturedAXMessages = parsed.messages
            capturedAXRowCount = parsed.rows
            axHasUnreadableBubbles = parsed.unreadableBubbles > 0
        }

        let hasValidatedAXMessages = capturedAXMessages != nil

        // If AX supplied text but not a usable transcript frame, require
        // screenshot geometry evidence before any of that text is trusted.
        let needsVisualGeometryEvidence = !resolvedGeometry.isValidated
        let usesVision = capturePlan.identity == .vision || capturePlan.messages == .vision ||
            needsVisualGeometryEvidence
        if usesVision && !WeChatScreenReader.hasScreenCapturePermission {
            WeChatScreenReader.requestScreenCapturePermissionOnce()
            updateCaptureDiagnostic(plan: capturePlan, hasAXIdentity: axContact != nil, hasAXMessages: hasValidatedAXMessages,
                                    failure: "Screen Recording permission required", hasAXTitle: axIdentity.hasTitle,
                                    timing: axProbeDiagnostic(fastProbe, resolvedProbe: probe,
                                                              fallbackAttempted: fallbackAttempted,
                                                              fallbackMilliseconds: fallbackMilliseconds))
            return .failure(.screenRecordingPermissionRequired)
        }

        let messageLimit = max(0, limit ?? 50)
        var contact = axContact
        var visionIdentity: VisionConversationIdentity?
        var visionObservation: VisibleWeChatSnapshot?
        if usesVision {
            let observation = WeChatScreenReader.shared.readConversationObservation(
                pid: app.processIdentifier,
                windowFrame: windowFrame,
                includeTitle: capturePlan.identity == .vision || needsVisualGeometryEvidence,
                includeMessages: capturePlan.messages == .vision || needsVisualGeometryEvidence,
                forceFresh: forceFresh,
                accurateMessages: accurateVision,
                previousHeaderFingerprint: previousHeaderFingerprint,
                previousMessageFingerprint: previousMessageFingerprint,
                paneGeometry: resolvedGeometry
            )
            attempt.geometryVerified = observation.paneGeometry.isValidated
            attempt.ocrMode = observation.messageRecognitionLevel
            if plan.messages == .vision {
                attempt.rawCount = observation.messageObservationCount
                attempt.candidateCount = observation.messages.count
            }
            guard observation.captureSucceeded else {
                updateCaptureDiagnostic(plan: capturePlan, hasAXIdentity: axContact != nil, hasAXMessages: hasValidatedAXMessages,
                                        failure: "Vision capture unavailable", hasAXTitle: axIdentity.hasTitle,
                                        timing: axProbeDiagnostic(fastProbe, resolvedProbe: probe,
                                                                  fallbackAttempted: fallbackAttempted,
                                                                  fallbackMilliseconds: fallbackMilliseconds) + "\n" +
                                            visionTimingDiagnostic(observation, titleFound: false)
                )
                return .failure(.visionCaptureFailed)
            }
            visionObservation = observation
            if capturePlan.identity == .vision {
                if observation.headerFrameUnchanged, let lockedContact {
                    contact = lockedContact
                } else {
                    if let identity = observation.titleIdentity, let title = observation.title {
                        contact = resolveVisionTitle(title, identity: identity)
                    } else {
                        contact = nil
                        resetPendingVisionTitle()
                    }
                }
                visionIdentity = observation.titleIdentity
            }
        }
        let messages: [ChatMessage]
        let rowCount: Int
        let messagesUnchanged: Bool
        if capturePlan.messages == .accessibility, let capturedAXMessages {
            messages = capturedAXMessages
            rowCount = capturedAXRowCount
            messagesUnchanged = false
        } else {
            messages = Array((visionObservation?.messages ?? []).suffix(messageLimit))
            rowCount = visionObservation?.messageObservationCount ?? 0
            messagesUnchanged = visionObservation?.messageFrameUnchanged ?? false
        }

        guard let contact, !contact.isEmpty else {
            updateCaptureDiagnostic(plan: capturePlan, hasAXIdentity: axContact != nil, hasAXMessages: hasValidatedAXMessages,
                                    failure: capturePlan.identity == .vision
                                        ? "Vision conversation title unavailable"
                                        : "AX conversation identity unavailable", hasAXTitle: axIdentity.hasTitle,
                                    timing: axProbeDiagnostic(fastProbe, resolvedProbe: probe,
                                                              fallbackAttempted: fallbackAttempted,
                                                              fallbackMilliseconds: fallbackMilliseconds) +
                                        (visionObservation.map {
                                            "\n" + visionTimingDiagnostic($0, titleFound: false)
                                        } ?? ""))
            if !messages.isEmpty {
                return .identityPending(PendingConversationObservation(
                    messages: messages, messageRowCount: rowCount, messageSource: capturePlan.messages,
                    visionIdentity: visionIdentity,
                    headerFingerprint: visionObservation?.headerFingerprint,
                    paneGeometry: visionObservation?.paneGeometry ?? resolvedGeometry
                ))
            }
            return .failure(.identityUnavailable)
        }

        if capturePlan.identity == .accessibility {
            guard let checked = accessibilityIdentity(in: window, app: app).contact,
                  WeChatParsing.conversationIdentityKey(checked) == WeChatParsing.conversationIdentityKey(contact) else {
                updateCaptureDiagnostic(plan: capturePlan, hasAXIdentity: false, hasAXMessages: true,
                                        failure: "conversation changed or became uncertain during extraction")
                return .failure(.identityUnavailable)
            }
        }
        let totalMilliseconds = Int(Date().timeIntervalSince(totalStarted) * 1000)
        var capturedGeometry = visionObservation?.paneGeometry ?? resolvedGeometry
        var visualTitleMatchesAXIdentity: Bool?
        if capturePlan.identity == .accessibility,
           capturedGeometry.source == .visualDivider,
           let observedTitle = visionObservation?.title {
            let matches = WeChatParsing.conversationIdentityKey(observedTitle) ==
                WeChatParsing.conversationIdentityKey(contact)
            visualTitleMatchesAXIdentity = matches
            if !matches {
                capturedGeometry = VisionLayoutRegions.geometry(
                    leftX: capturedGeometry.leftX,
                    headerBottomY: capturedGeometry.headerRegion.minY,
                    composerTopY: capturedGeometry.messageRegion.minY,
                    source: .visualDividerCandidate, confidence: 0.55
                )
            }
        }
        let extractionTrustworthy: Bool
        if capturePlan.messages == .accessibility {
            extractionTrustworthy = hasValidatedAXMessages && !messages.isEmpty &&
                messages.allSatisfy { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        } else {
            extractionTrustworthy = visionObservation?.messageExtractionTrustworthy == true
        }
        let timing = [
            "Capture total: \(totalMilliseconds) ms",
            "AX capability probe: \(capability.probeMilliseconds) ms",
            axProbeDiagnostic(fastProbe, resolvedProbe: probe, fallbackAttempted: fallbackAttempted,
                              fallbackMilliseconds: fallbackMilliseconds),
            "AX identity/list resolution: \(axResolutionMilliseconds) ms",
            "AX message read: \(axMessageReadMilliseconds) ms",
            "Capture plan: \(capturePlan.identity.rawValue) / \(capturePlan.messages.rawValue)",
            "Visual title matches AX identity: \(visualTitleMatchesAXIdentity.map { $0 ? "yes" : "no" } ?? "not checked")",
            visionObservation.map {
                visionTimingDiagnostic($0, titleFound: $0.title != nil, geometry: capturedGeometry)
            } ?? "Vision: not used"
        ].joined(separator: "\n")
        attempt.geometryVerified = capturedGeometry.isValidated
        validatedCapture = extractionTrustworthy && capturedGeometry.isValidated
        updateCaptureDiagnostic(plan: capturePlan, hasAXIdentity: axContact != nil,
                                hasAXMessages: capturePlan.messages == .accessibility && list != nil,
                                failure: "none", hasAXTitle: axIdentity.hasTitle, timing: timing)
        cacheActivePlan(capturePlan, pid: app.processIdentifier, window: window)
        backendLock.lock()
        let verifiedViewport = capturedGeometry.isValidated && geometryWindow.map({ CFEqual($0, window) }) == true
            ? geometryViewport : nil
        backendLock.unlock()
        // Older builds can expose a verified native transcript viewport without
        // semantic bubble identifiers. Use the same scrollbar evidence there.
        let observedLiveEdge = axHasUnreadableBubbles || !capturedGeometry.isValidated
            ? nil : (list ?? verifiedViewport).flatMap { liveEdgeState(in: $0) }
        return .success(WeChatSnapshot(contact: contact, messages: messages, capturedAt: Date(),
                              messageRowCount: rowCount, identitySource: capturePlan.identity,
                              messageSource: capturePlan.messages,
                              messageExtractionTrustworthy: extractionTrustworthy,
                              visionIdentity: visionIdentity,
                              paneGeometry: capturedGeometry,
                              messageFingerprint: visionObservation?.messageFingerprint,
                              headerFingerprint: visionObservation?.headerFingerprint,
                              messagePaneLeftX: capturedGeometry.leftX,
                              messagesUnchanged: messagesUnchanged,
                              headerUnchanged: visionObservation?.headerFrameUnchanged ?? false,
                              captureTimingDiagnostic: timing,
                              liveEdgeState: observedLiveEdge))
    }

    private func axProbeDiagnostic(_ fastProbe: AXCapabilityProbe?, resolvedProbe: AXCapabilityProbe?, fallbackAttempted: Bool,
                                   fallbackMilliseconds: Int) -> String {
        "Fast AX probe: timed out \(fastProbe?.timedOut == true ? "yes" : "no"), nodes \(fastProbe?.visitedNodes ?? 0), identity \(fastProbe?.hasAXIdentity == true ? "found" : "missing"), message list \(fastProbe?.hasAXMessageList == true ? "found" : "missing")\n" +
        "AX fallback: attempted \(fallbackAttempted ? "yes" : "no"), identity \(resolvedProbe?.hasAXIdentity == true ? "found" : "missing"), list \(resolvedProbe?.hasAXMessageList == true ? "found" : "missing"), duration \(fallbackMilliseconds) ms"
    }

    private func visionTimingDiagnostic(_ observation: VisibleWeChatSnapshot, titleFound: Bool,
                                        geometry: ConversationPaneGeometry? = nil) -> String {
        let geometry = geometry ?? observation.paneGeometry
        let titleROI = geometry.headerRegion
        return "Vision: window capture \(observation.captureSucceeded ? "success" : "failed") " +
        "(discovery \(observation.windowDiscoveryDurationMilliseconds) ms, screenshot \(observation.captureDurationMilliseconds) ms), " +
        "title OCR \(observation.headerOCRDurationMilliseconds) ms, message OCR \(observation.messageOCRDurationMilliseconds) ms, " +
        "title found \(titleFound ? "yes" : "no"), visible messages \(observation.messages.count)\n" +
        "Geometry: \(geometry.source.rawValue), confidence \(String(format: "%.2f", geometry.confidence)), validated \(geometry.isValidated), pane left \(String(format: "%.3f", geometry.leftX)), " +
        "scroll target x/y \(String(format: "%.3f", geometry.messageRegion.midX))/\(String(format: "%.3f", 1 - geometry.messageRegion.midY))\n" +
        "Identity: title ROI inside pane \(String(format: "%.3f,%.3f,%.3f,%.3f", titleROI.minX, titleROI.minY, titleROI.width, titleROI.height)), " +
        "observations \(observation.headerObservationCount), candidates \(observation.headerCandidates.count), " +
        "selected \(observation.titleIdentity == nil ? "no" : "yes"), " +
        "confidence \(observation.acceptedTitleConfidence.map { String(format: "%.3f", $0) } ?? "unavailable"), " +
        "header fingerprint \(observation.headerFingerprint == nil ? "unavailable" : (observation.headerFrameUnchanged ? "unchanged" : "changed"))\n" +
        "Messages: pane left x=\(String(format: "%.3f", observation.messagePaneLeftX)), " +
        "width=\(String(format: "%.3f", observation.conversationCrop.width)), " +
        "region=\(String(format: "%.3f,%.3f,%.3f,%.3f", observation.messageCrop.minX, observation.messageCrop.minY, observation.messageCrop.width, observation.messageCrop.height))\n" +
        "OCR level: \(observation.messageRecognitionLevel), fast observations: \(observation.fastOCRObservationCount), " +
        "accurate fallback: \(observation.accurateFallbackAttempted ? "yes" : "no"), " +
        "accurate observations: \(observation.accurateOCRObservationCount), " +
        "plausible text: \(observation.plausibleTextObservationCount), " +
        "geometry rejected: \(observation.geometryRejectedMessageCount), " +
        "timestamp/control rejected: \(observation.timestampControlRejectedMessageCount), " +
        "grouped: \(observation.messages.count)\n" +
        "Wide crop fallback: attempted \(observation.wideCropFallbackAttempted ? "yes" : "no"), " +
        "observations \(observation.wideCropObservationCount), " +
        "succeeded \(observation.wideCropFallbackSucceeded ? "yes" : "no")\n" +
        "Message fingerprint: \(observation.messageFingerprint == nil ? "unavailable" : (observation.messageFrameUnchanged ? "unchanged" : "changed")), " +
        "additional title screenshot retries: none; next watchdog observation retries if needed"
    }

    var lastCaptureFailureStage: String {
        captureDiagnosticLock.lock()
        defer { captureDiagnosticLock.unlock() }
        return lastCaptureFailure
    }

    var conversationCaptureDiagnostic: String {
        captureDiagnosticLock.lock()
        defer { captureDiagnosticLock.unlock() }
        let plan = lastCapturePlan
        return [
            "Identity source: \(plan?.identity.rawValue ?? "unavailable")",
            "Message source: \(plan?.messages.rawValue ?? "unavailable")",
            "AX title available: \(lastAXTitleAvailable ? "yes" : "no")",
            "AX identity available: \(lastAXIdentityAvailable ? "yes" : "no")",
            "AX message list available: \(lastAXMessageListAvailable ? "yes" : "no")",
            "Screen Recording permission: \(WeChatScreenReader.hasScreenCapturePermission ? "yes" : "no")",
            "Last capture failure: \(lastCaptureFailure)",
            lastCaptureTimingDiagnostic,
            lastAXReadDiagnostic
        ].joined(separator: "\n")
    }

    private func updateCaptureDiagnostic(plan: ConversationCapturePlan?, hasAXIdentity: Bool,
                                         hasAXMessages: Bool, failure: String, hasAXTitle: Bool = false,
                                         timing: String? = nil) {
        captureDiagnosticLock.lock()
        lastCapturePlan = plan
        lastAXIdentityAvailable = hasAXIdentity
        lastAXTitleAvailable = hasAXTitle
        lastAXMessageListAvailable = hasAXMessages
        lastCaptureFailure = failure
        if let timing { lastCaptureTimingDiagnostic = timing }
        else if failure != "none" { lastCaptureTimingDiagnostic = "Failure stage: \(failure)" }
        captureDiagnosticLock.unlock()
    }

    func accessibilityObservationTargets() -> (pid: pid_t, elements: [AXUIElement])? {
        guard let window = mainWindow(), let app = weChatApplication(),
              let list = messageListElement(in: window) else { return nil }
        var windowPID: pid_t = 0
        guard AXUIElementGetPid(window, &windowPID) == .success, windowPID == app.processIdentifier else { return nil }
        return (app.processIdentifier, [AXUIElementCreateApplication(app.processIdentifier), window, list])
    }

    private func accessibilityContact(in window: AXUIElement, app: NSRunningApplication) -> String? {
        accessibilityIdentity(in: window, app: app).contact
    }

    private func accessibilityIdentity(in window: AXUIElement, app: NSRunningApplication) -> (contact: String?, hasTitle: Bool) {
        let info = backendState(for: app.processIdentifier, window: window)
        guard let probe = info.initialProbe else { return (nil, false) }
        var title: String?
        if let titleElement = probe.titleElement {
            let fields = attributes(titleElement, ["AXIdentifier", "AXValue", "AXTitle"])
            if fields["AXIdentifier"] as? String == WeChatParsing.chatTitleIdentifier {
                let raw = WeChatParsing.messageText(identifier: WeChatParsing.messageRowIdentifier,
                    title: fields["AXValue"] as? String, value: fields["AXTitle"] as? String) ?? ""
                let normalized = WeChatParsing.normalizeChatTitle(raw)
                if !normalized.isEmpty && !WeChatParsing.isGenericWindowTitle(normalized) { title = normalized }
            }
        }
        var selected: String?
        let identityDeadline = Date().addingTimeInterval(0.15)
        for session in probe.sessionElements {
            if Date() >= identityDeadline { break }
            let fields = attributes(session.element, ["AXIdentifier", "AXSelected"])
            if let id = fields["AXIdentifier"] as? String,
               let name = WeChatParsing.selectedSessionName(from: id,
                    isSelected: (fields["AXSelected"] as? NSNumber)?.boolValue == true) { selected = name; break }
        }
        if let title, let selected,
           WeChatParsing.conversationIdentityKey(title) != WeChatParsing.conversationIdentityKey(selected) {
            return (nil, false)
        }
        return (title ?? selected, title != nil)
    }

    private func messageListElement(in window: AXUIElement) -> AXUIElement? {
        guard let app = weChatApplication() else { return nil }
        guard let list = backendState(for: app.processIdentifier, window: window).initialProbe?.messageListElement else { return nil }
        if identifier(list, timeout: 0.02) == WeChatParsing.messageListIdentifier { return list }
        // A destroyed/replaced list invalidates the successful plan. Rediscover
        // within a bounded probe, never traverse the full window every poll.
        backendLock.lock()
        activeCapturePlan = nil
        backendLock.unlock()
        let fast = probeAXCapabilities(in: window, cancellation: ProbeCancellation())
        let probe = fast.hasAXMessageList ? fast : targetedAXFallback(in: window, base: fast).probe
        cacheCapabilityProbe(probe, pid: app.processIdentifier, window: window)
        return probe.messageListElement
    }

    private func accessibilityPaneGeometry(in window: AXUIElement,
                                           windowFrame: CGRect) -> ConversationPaneGeometry? {
        backendLock.lock()
        let matches = geometryWindow.map { CFEqual($0, window) } == true
        let cachedViewport = matches ? geometryViewport : nil
        let cachedComposer = matches ? geometryComposer : nil
        let cachedSource = matches ? geometrySource : nil
        backendLock.unlock()
        func measured(_ viewport: AXUIElement, composer: AXUIElement?, source: ConversationPaneGeometrySource) -> ConversationPaneGeometry? {
            VisionLayoutRegions.accessibilityTranscript(viewport: frame(viewport, timeout: 0.02),
                composer: composer.map { frame($0, timeout: 0.02) }, window: windowFrame, source: source)
        }
        if let cachedViewport, let cachedSource,
           let geometry = measured(cachedViewport, composer: cachedComposer, source: cachedSource) { return geometry }
        let list = messageListElement(in: window)
        var viewport = list
        var composer: AXUIElement?
        var source: ConversationPaneGeometrySource = .accessibilityMessageList
        if list == nil {
            let nodes = find(window, depth: 8) { node in
                let role = string(node, "AXRole", timeout: 0.01)
                return role == "AXScrollArea" || role == "AXTextArea"
            }
            composer = nodes.filter { string($0, "AXRole", timeout: 0.01) == "AXTextArea" }
                .filter { frame($0, timeout: 0.02).minY > windowFrame.minY + windowFrame.height * 0.60 }
                .max { frame($0, timeout: 0.02).width < frame($1, timeout: 0.02).width }
            viewport = nodes.filter { string($0, "AXRole", timeout: 0.01) == "AXScrollArea" }
                .first { measured($0, composer: composer, source: .accessibilityScrollArea) != nil }
            source = .accessibilityScrollArea
        }
        guard let viewport, let geometry = measured(viewport, composer: composer, source: source) else {
            backendLock.lock()
            geometryViewport = nil; geometryComposer = nil; geometryWindow = nil; geometrySource = nil
            backendLock.unlock()
            return nil
        }
        backendLock.lock()
        geometryWindow = window; geometryViewport = viewport; geometryComposer = composer; geometrySource = source
        backendLock.unlock()
        return geometry
    }

    private func configuredPaneGeometry() -> ConversationPaneGeometry {
        let calibration = VisionLayoutCalibration.current
        return VisionLayoutRegions.geometry(
            leftX: calibration.messagePaneLeftX, headerBottomY: calibration.headerBottomY,
            composerTopY: calibration.composerTopY, source: .configuredFallback, confidence: 0.40
        )
    }

    private struct AXMessageRead {
        var messages: [ChatMessage] = []
        var rows = 0
        var bubbles = 0
        var placeholders = 0
        var nodes = 0
        var exhausted = false
        var rowAttributesUnavailable = false
        var unreadableBubbles = 0
        var failure: String? {
            if exhausted { return "row traversal budget exceeded" }
            if rowAttributesUnavailable { return "AXVisibleChildren and AXChildren unavailable" }
            if rows == 0 { return "message list has no visible rows" }
            if bubbles == 0 { return "no confirmed chat_bubble_item_view rows" }
            if messages.isEmpty { return "confirmed bubbles have no readable AXTitle/AXValue or descendant text" }
            return nil
        }
    }

    private func readAccessibilityMessages(in list: AXUIElement, limit: Int) -> AXMessageRead {
        var result = AXMessageRead()
        let deadline = Date().addingTimeInterval(0.70)
        let visible = boundedChildren(list, attribute: "AXVisibleChildren")
        let fallback = visible == nil || visible?.isEmpty == true ? boundedChildren(list) : nil
        let rows = visible?.isEmpty == false ? visible! : fallback ?? []
        result.rowAttributesUnavailable = visible == nil && fallback == nil
        result.rows = rows.count
        var rowStack = rows.reversed().map { ($0, 0) }
        var pendingTimeSeparator: String?
        while let (row, rowDepth) = rowStack.popLast() {
            guard Date() < deadline, result.nodes < 500 else { result.exhausted = true; break }
            result.nodes += 1
            let fields = attributes(row, ["AXIdentifier", "AXRole", "AXTitle", "AXValue", "AXDescription"])
            let id = fields["AXIdentifier"] as? String ?? ""
            if id == WeChatParsing.placeholderRowIdentifier { result.placeholders += 1; continue }
            guard id == WeChatParsing.messageRowIdentifier else {
                // Only a stand-alone label inside the confirmed message list can
                // act as a time divider. Other UI text is never message content.
                let role = fields["AXRole"] as? String ?? ""
                if ["AXStaticText", "AXGroup", "AXRow", "AXCell"].contains(role),
                   let label = WeChatParsing.timeSeparatorLabel(
                    fields["AXTitle"] as? String ?? fields["AXValue"] as? String) {
                    pendingTimeSeparator = label
                }
                // Some releases wrap confirmed bubbles in list rows/cells.
                // These wrappers never supply message text themselves.
                if rowDepth < 2, ["AXRow", "AXCell", "AXGroup", "AXUnknown"].contains(role) {
                    rowStack.append(contentsOf: (boundedChildren(row, maximum: 8) ?? []).reversed().map { ($0, rowDepth + 1) })
                }
                continue
            }
            result.bubbles += 1
            var text = WeChatParsing.messageText(identifier: id, title: fields["AXTitle"] as? String, value: fields["AXValue"] as? String)
            if text == nil {
                // Descend only inside a positively identified bubble. Metadata
                // and controls cannot supply fallback message text.
                var stack = (boundedChildren(row, maximum: 32) ?? []).reversed().map { ($0, 1) }
                var fragments: [String] = []
                while let (node, depth) = stack.popLast() {
                    guard Date() < deadline, result.nodes < 500 else { result.exhausted = true; break }
                    result.nodes += 1
                    let child = attributes(node, ["AXIdentifier", "AXRole", "AXTitle", "AXValue"])
                    let childID = child["AXIdentifier"] as? String ?? ""
                    let role = child["AXRole"] as? String ?? ""
                    guard childID.isEmpty || ["chat_bubble_text", "chat_message_text"].contains(childID) else { continue }
                    if role == "AXStaticText" || role == "AXTextArea" {
                        if let fragment = WeChatParsing.descendantMessageText(role: role, identifier: childID,
                            title: child["AXTitle"] as? String, value: child["AXValue"] as? String) {
                            fragments.append(fragment)
                        }
                    } else if ["AXGroup", "AXUnknown"].contains(role), depth < 4 {
                        stack.append(contentsOf: (boundedChildren(node, maximum: 32) ?? []).reversed().map { ($0, depth + 1) })
                    }
                }
                if !fragments.isEmpty { text = fragments.joined(separator: "\n") }
            }
            if let text {
                result.messages.append(ChatMessage(text: text,
                    sender: WeChatParsing.sender(from: fields["AXDescription"] as? String ?? ""),
                    source: .accessibility, timeSeparatorBefore: pendingTimeSeparator))
                pendingTimeSeparator = nil
            } else {
                result.unreadableBubbles += 1
                pendingTimeSeparator = nil
            }
        }
        result.messages = Array(result.messages.suffix(max(0, limit)))
        captureDiagnosticLock.lock()
        lastAXReadDiagnostic = "AX rows: \(result.rows), bubbles: \(result.bubbles), placeholders: \(result.placeholders), scanned nodes: \(result.nodes), extracted: \(result.messages.count), unreadable bubbles: \(result.unreadableBubbles), stage: \(result.failure ?? "complete")"
        captureDiagnosticLock.unlock()
        return result
    }

    func detectCurrentConversation(forceFreshVision: Bool = false,
                                  paneGeometry: ConversationPaneGeometry? = nil,
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
        if (backendInfo.initialProbe?.hasAXIdentity == true || titleAXAvailable),
           let axIdentity = accessibilityIdentity(in: window, app: app).contact {
            return WeChatConversationDetection(contact: axIdentity, windowFound: true, treeCollapsed: false,
                                              visionSnapshot: nil, backend: backend,
                                              mainWindowLookupMilliseconds: windowLookupMilliseconds,
                                              capabilityProbeMilliseconds: backendInfo.probeMilliseconds)
        }
        let currentFrame = frame(window, timeout: 0.08)
        let geometry = paneGeometry ?? accessibilityPaneGeometry(in: window, windowFrame: currentFrame) ??
            configuredPaneGeometry()
        let snapshot = visibleTitleIdentity(for: window, forceFresh: forceFreshVision,
                                            paneGeometry: geometry)
        return WeChatConversationDetection(
            contact: snapshot?.title,
            windowFound: true,
            treeCollapsed: backendInfo.initialProbe?.hasAXIdentity != true,
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

        if let list = messageListElement(in: window) { return readRows(in: list, limit: limit) }
        return .messageListUnavailable(treeCollapsed: false, visionState: nil)
    }

    func scrollMessagePaneUpwardIfConversationMatches(
        contact: String,
        identity: VisionConversationIdentity?,
        fraction: CGFloat,
        paneGeometry: ConversationPaneGeometry? = nil,
        cancellation: MonitorWorkCancellation?
    ) -> OlderContextScrollResult {
        scrollMessagePaneIfConversationMatches(contact: contact, identity: identity, fraction: fraction,
                                               paneGeometry: paneGeometry,
                                               cancellation: cancellation, direction: .older)
    }

    func scrollMessagePaneUpOnePageIfConversationMatches(contact: String,
                                                          paneGeometry: ConversationPaneGeometry? = nil) -> OlderContextScrollResult {
        scrollAccessibilityMessagePane(contact: contact, paneGeometry: paneGeometry, direction: .older)
    }

    func scrollMessagePaneDownOnePageIfConversationMatches(contact: String,
                                                            paneGeometry: ConversationPaneGeometry? = nil) -> OlderContextScrollResult {
        scrollAccessibilityMessagePane(contact: contact, paneGeometry: paneGeometry, direction: .newer)
    }

    private func scrollAccessibilityMessagePane(contact: String, paneGeometry: ConversationPaneGeometry?,
                                                direction: ChatScrollDirection) -> OlderContextScrollResult {
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
        let geometry = paneGeometry ?? accessibilityPaneGeometry(in: window, windowFrame: windowFrame) ?? configuredPaneGeometry()
        let location = geometry.scrollTarget(in: windowFrame)
        guard windowFrame.insetBy(dx: 8, dy: 8).contains(location) else { return .scrollUnavailable }
        let amount = Int32(min(240, max(60, windowFrame.height * 0.18)))
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
        paneGeometry: ConversationPaneGeometry? = nil,
        cancellation: MonitorWorkCancellation?
    ) -> OlderContextScrollResult {
        scrollMessagePaneIfConversationMatches(contact: contact, identity: identity, fraction: fraction,
                                               paneGeometry: paneGeometry,
                                               cancellation: cancellation, direction: .newer)
    }

    private func scrollMessagePaneIfConversationMatches(
        contact: String,
        identity: VisionConversationIdentity?,
        fraction: CGFloat,
        paneGeometry: ConversationPaneGeometry?,
        cancellation: MonitorWorkCancellation?,
        direction: ChatScrollDirection
    ) -> OlderContextScrollResult {
        guard cancellation?.isCancelled != true else { return .cancelled }
        let detection = detectCurrentConversation(forceFreshVision: true, paneGeometry: paneGeometry)
        switch olderContextIdentityCheck(detection, contact: contact, identity: identity) {
        case .changed: return .conversationChanged
        case .uncertain: return .identityUncertain
        case .matches: break
        }
        guard let app = weChatApplication(), let window = mainWindow() else { return .windowUnavailable }
        guard cancellation?.isCancelled != true else { return .cancelled }
        let windowFrame = frame(window, timeout: 0.08)
        guard windowFrame.width >= 400, windowFrame.height >= 300 else { return .windowUnavailable }
        let geometry = paneGeometry ?? accessibilityPaneGeometry(in: window, windowFrame: windowFrame) ?? configuredPaneGeometry()
        let canvasHeight = geometry.messageRegion.height
        guard canvasHeight > 0.1 else { return .scrollUnavailable }
        let location = geometry.scrollTarget(in: windowFrame)
        guard windowFrame.insetBy(dx: 8, dy: 8).contains(location) else { return .scrollUnavailable }
        let stepFraction = min(0.28, max(0.12, fraction))
        let amount = Int32(min(240, max(60, windowFrame.height * canvasHeight * stepFraction)))
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
        previousHeaderFingerprint: String? = nil,
        previousMessageFingerprint: String? = nil,
        paneGeometry: ConversationPaneGeometry? = nil,
        cancellation: MonitorWorkCancellation?
    ) -> OlderContextReadResult {
        guard cancellation?.isCancelled != true else { return .cancelled }
        let capture = captureConversationSnapshot(limit: 50, forceFresh: forceFresh,
                                                  accurateVision: accurate,
                                                  previousHeaderFingerprint: previousHeaderFingerprint,
                                                  previousMessageFingerprint: previousMessageFingerprint,
                                                  lockedContact: contact,
                                                  paneGeometry: paneGeometry)
        let snapshot: WeChatSnapshot
        switch capture {
        case .success(let value): snapshot = value
        case .identityPending: return cancellation?.isCancelled == true ? .cancelled : .identityUncertain
        case .failure: return cancellation?.isCancelled == true ? .cancelled : .captureUnavailable
        }
        guard WeChatParsing.conversationIdentityKey(snapshot.contact) ==
                WeChatParsing.conversationIdentityKey(contact) else { return .conversationChanged }
        if let identity, let observedIdentity = snapshot.visionIdentity,
           !identity.isSpatiallyConsistent(with: observedIdentity) {
            return .identityUncertain
        }
        return .snapshot(snapshot)
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

    private func visibleTitleIdentity(for window: AXUIElement, forceFresh: Bool = false,
                                      paneGeometry: ConversationPaneGeometry? = nil) -> VisibleWeChatSnapshot? {
        guard let app = weChatApplication() else { return nil }
        return WeChatScreenReader.shared.readTitleIdentity(
            pid: app.processIdentifier, windowFrame: frame(window, timeout: 0.08), forceFresh: forceFresh,
            paneGeometry: paneGeometry
        )
    }

    func visionDiagnosticReport() -> String {
        guard let app = weChatApplication() else {
            return "Screen Recording permission: \(WeChatScreenReader.hasScreenCapturePermission ? "granted" : "not granted")\nTarget WeChat PID: unavailable\nWindow capture: WeChat window not found\n"
        }
        guard let window = mainWindow() else {
            return "Screen Recording permission: \(WeChatScreenReader.hasScreenCapturePermission ? "granted" : "not granted")\nTarget WeChat PID: \(app.processIdentifier)\nWindow capture: WeChat window not found\n"
        }
        return "\(readerBackendDiagnostic)\n\(WeChatScreenReader.shared.diagnosticReport(pid: app.processIdentifier, windowFrame: frame(window), paneGeometry: accessibilityPaneGeometry(in: window, windowFrame: frame(window))))"
    }

    func annotatedVisionPreview() -> NSImage? {
        guard let app = weChatApplication(), let window = mainWindow() else { return nil }
        let bounds = frame(window)
        let geometry = accessibilityPaneGeometry(in: window, windowFrame: bounds)
        return WeChatScreenReader.shared.annotatedPreview(pid: app.processIdentifier, windowFrame: bounds, paneGeometry: geometry)
    }

    /// Scrollbar evidence establishes arrival direction. Missing or
    /// unsupported evidence stays unknown and cannot authorize automatic analysis.
    private func liveEdgeState(in list: AXUIElement) -> Bool? {
        var current: AXUIElement? = list
        for _ in 0..<4 {
            guard let element = current else { break }
            let fields = attributes(element, ["AXVerticalScrollBar", "AXParent"])
            if let raw = fields["AXVerticalScrollBar"], CFGetTypeID(raw as CFTypeRef) == AXUIElementGetTypeID() {
                let bar = raw as! AXUIElement
                let values = attributes(bar, ["AXValue", "AXMinValue", "AXMaxValue", "AXRole", "AXOrientation"])
                return ScrollBarEvidence.liveEdge(value: (values["AXValue"] as? NSNumber)?.doubleValue,
                    minimum: (values["AXMinValue"] as? NSNumber)?.doubleValue,
                    maximum: (values["AXMaxValue"] as? NSNumber)?.doubleValue,
                    role: values["AXRole"] as? String, orientation: values["AXOrientation"] as? String)
            }
            if let raw = fields["AXParent"], CFGetTypeID(raw as CFTypeRef) == AXUIElementGetTypeID() {
                current = (raw as! AXUIElement)
            } else { current = nil }
        }
        return nil
    }

    private func readRows(in list: AXUIElement, limit: Int) -> MessageReadResult {
        let read = readAccessibilityMessages(in: list, limit: limit)
        guard read.failure == nil else { return .messageListUnavailable(treeCollapsed: false, visionState: nil) }
        return .messageListFound(messages: read.messages, renderedRows: read.rows,
            bubbleRows: read.bubbles, placeholders: read.placeholders, isVision: false, fingerprint: nil)
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
            "Accessibility trusted: \(hasAccessibilityPermission)",
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

        lines.append(conversationCaptureDiagnostic)
        lines.append(capturePerformanceSummary)
        let nodes = structuralNodes(in: window, maximum: 500)
        lines.append("Structural nodes (text values omitted; identifiers sanitized):")
        lines.append(contentsOf: nodes)
        lines.append("Structural row counts: bubbles=\(nodes.filter { $0.contains("identifier=" + WeChatParsing.messageRowIdentifier + " ") }.count), placeholders=\(nodes.filter { $0.contains("identifier=" + WeChatParsing.placeholderRowIdentifier + " ") }.count); bounded diagnostic sample")
        return lines.joined(separator: "\n") + "\n"
    }

    private func structuralNodes(in root: AXUIElement, maximum: Int) -> [String] {
        var output: [String] = []
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        let deadline = Date().addingTimeInterval(2)
        while let (element, depth) = stack.popLast(), output.count < maximum, Date() < deadline {
            let role = string(element, "AXRole") ?? "<unavailable>"
            let id = WeChatParsing.diagnosticIdentifier(identifier(element))
            let childNodes = boundedChildren(element, maximum: 80) ?? []
            var names: CFArray?
            AXUIElementSetMessagingTimeout(element, 0.02)
            AXUIElementCopyAttributeNames(element, &names)
            let supported = names as? [String] ?? []
            output.append("  \(String(repeating: " ", count: min(depth, 12)))role=\(role) identifier=\(id) children=\(childNodes.count) AXTitle=\(supported.contains("AXTitle")) AXValue=\(supported.contains("AXValue"))")
            if depth < 18 { for child in childNodes.reversed() { stack.append((child, depth + 1)) } }
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
