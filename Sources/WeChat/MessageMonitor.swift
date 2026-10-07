import Foundation
import Combine

@MainActor
final class MessageMonitor: ObservableObject {
    static let shared = MessageMonitor()
    @Published private(set) var isRunning = false
    @Published private(set) var contactName: String?
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var status = "Paused"
    var onBurst: ((String, [ChatMessage], Bool) -> Void)?
    var onDeactivated: (() -> Void)?

    private let bridge = WeChatBridge.shared
    private let accessibilityQueue = DispatchQueue(label: "com.wechatreplycopilot.accessibility")
    private var timer: Timer?
    private var debounce: Task<Void, Never>?
    private var lastIDs: [String] = []
    private var lockedContact: String?
    private var generation = 0
    private var isCheckingConversation = false
    private var isPolling = false

    func start() {
        guard !isRunning, !isCheckingConversation else { return }
        guard bridge.hasAccessibilityPermission else { status = "Accessibility permission required"; bridge.requestAccessibilityPermission(); return }
        guard bridge.isWeChatRunning else { status = "WeChat not running"; return }
        isCheckingConversation = true
        status = "Connected to WeChat · checking conversation"
        generation += 1
        let token = generation
        let bridge = self.bridge
        accessibilityQueue.async { [weak self] in
            let contact = bridge.currentContact()
            let treeCollapsed = contact == nil && bridge.accessibilityTreeAppearsCollapsed()
            let screenCaptureAllowed = WeChatScreenReader.hasScreenCapturePermission
            let result = contact == nil ? nil : bridge.readMessages()
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.isCheckingConversation = false
                guard let contact, !contact.isEmpty else {
                    self.status = treeCollapsed
                        ? self.collapsedTreeStatus(screenCaptureAllowed: screenCaptureAllowed)
                        : "Could not identify the open WeChat conversation"
                    return
                }
                self.contactName = contact
                self.lockedContact = contact
                self.isRunning = true
                if let result { self.applyInitialReadResult(result, contact: contact) }
                self.timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.poll() }
                }
            }
        }
    }

    func stop() {
        isRunning = false
        isCheckingConversation = false
        isPolling = false
        timer?.invalidate(); timer = nil
        debounce?.cancel(); debounce = nil
        generation += 1
        messages = []
        lastIDs = []
        contactName = nil
        lockedContact = nil
        status = "Paused"
        onDeactivated?()
    }

    func pollNow() { poll() }

    private func poll() {
        guard isRunning, !isPolling else { return }
        isPolling = true
        let token = generation
        let bridge = self.bridge
        let lockedContact = self.lockedContact
        accessibilityQueue.async { [weak self] in
            let contact = bridge.currentContact()
            let treeCollapsed = contact == nil && bridge.accessibilityTreeAppearsCollapsed()
            let result = contact == nil || contact != lockedContact ? nil : bridge.readMessages(limit: 20)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPolling = false
                guard self.isRunning, self.generation == token else { return }
                guard let contact, contact == self.lockedContact else {
                    self.stop()
                    self.status = treeCollapsed
                        ? self.collapsedTreeStatus(screenCaptureAllowed: WeChatScreenReader.hasScreenCapturePermission)
                        : "Conversation changed or could not be identified — activate again when the chat is open."
                    return
                }
                guard let result else { return }
                switch result {
                case .messageListUnavailable(let collapsed):
                    self.messages = []
                    self.lastIDs = []
                    self.status = collapsed
                        ? self.collapsedTreeStatus(screenCaptureAllowed: WeChatScreenReader.hasScreenCapturePermission)
                        : "Conversation detected, but message list is unavailable"
                case .messageListFound(let snapshot, let renderedRows, let bubbleRows, _):
                    guard !snapshot.isEmpty else {
                        self.messages = []
                        self.lastIDs = []
                        self.status = renderedRows == 0 || bubbleRows == 0
                            ? "Message list found, but no rendered message rows are available"
                            : "Message rows found, but message text is unavailable"
                        return
                    }
                    self.processSnapshot(snapshot, contact: contact)
                }
            }
        }
    }

    private func applyInitialReadResult(_ result: MessageReadResult, contact: String) {
        switch result {
        case .messageListUnavailable(let collapsed):
            messages = []
            lastIDs = []
            status = collapsed
                ? collapsedTreeStatus(screenCaptureAllowed: WeChatScreenReader.hasScreenCapturePermission)
                : "Conversation detected: \(contact) · message list is unavailable"
        case .messageListFound(let snapshot, let renderedRows, let bubbleRows, _):
            messages = snapshot
            lastIDs = snapshot.map(\.id)
            if snapshot.isEmpty {
                status = renderedRows == 0 || bubbleRows == 0
                    ? "Message list found, but no rendered message rows are available"
                    : "Message rows found, but message text is unavailable"
            } else if snapshot.allSatisfy({ !$0.senderIdentified }) {
                status = "Message rows found, sender identity unavailable"
            } else if snapshot.contains(where: { !$0.senderIdentified }) {
                status = "Message rows found, some sender identities are unavailable"
            } else {
                status = "Monitoring this conversation"
            }
        }
    }

    private func collapsedTreeStatus(screenCaptureAllowed: Bool) -> String {
        screenCaptureAllowed
            ? "WeChat's visible conversation could not be read; bring its window to the front and try again"
            : "Allow Screen Recording for WeChat Reply Copilot in System Settings, then activate again"
    }

    private func processSnapshot(_ snapshot: [ChatMessage], contact: String) {
        contactName = contact
        messages = snapshot
        if snapshot.isEmpty {
            lastIDs = []
            status = "Chat opened · WeChat exposed no message text"
            return
        }
        let ids = snapshot.map(\.id)
        guard ids != lastIDs else { return }
        let added = newMessages(snapshot, old: lastIDs)
        lastIDs = ids
        guard !added.isEmpty else { status = "Monitoring this conversation"; return }
        let hasIncoming = added.contains(where: { $0.senderIdentified && !$0.isFromMe })
        let hasUnknown = added.contains(where: { !$0.senderIdentified })
        guard hasIncoming else {
            status = hasUnknown ? "Message rows found, sender identity unavailable" : "Monitoring this conversation"
            return
        }
        scheduleBurst(contact: contact, canAutoAnalyze: WeChatParsing.canAutomaticallyAnalyze(snapshot))
    }

    private func newMessages(_ current: [ChatMessage], old: [String]) -> [ChatMessage] {
        if old.isEmpty { return current }
        let ids = current.map(\.id)
        for length in stride(from: min(ids.count, old.count), through: 1, by: -1) {
            if Array(old.suffix(length)) == Array(ids.prefix(length)) { return Array(current.dropFirst(length)) }
        }
        return Array(current.suffix(1))
    }

    private func scheduleBurst(contact: String, canAutoAnalyze: Bool) {
        generation += 1
        let token = generation
        debounce?.cancel()
        status = "Waiting for the message burst to finish…"
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self, self.isRunning, self.generation == token else { return }
            self.status = canAutoAnalyze ? "Message ready · analyzing" : "Message ready · Analyze manually"
            if canAutoAnalyze {
                self.onBurst?(contact, self.messages.suffix(20).map { $0 }, true)
            }
        }
    }
}
