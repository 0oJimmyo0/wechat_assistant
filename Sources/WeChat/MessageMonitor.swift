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
        guard bridge.isWeChatRunning else { status = "Open WeChat to start monitoring"; return }
        isCheckingConversation = true
        status = "Checking the open WeChat conversation…"
        generation += 1
        let token = generation
        let bridge = self.bridge
        accessibilityQueue.async { [weak self] in
            let contact = bridge.currentContact()
            let snapshot = contact == nil ? [] : bridge.recentMessages()
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.isCheckingConversation = false
                guard let contact, !contact.isEmpty else {
                    self.status = "Open a conversation before activating"
                    return
                }
                self.contactName = contact
                self.messages = snapshot
                self.lockedContact = contact
                self.lastIDs = snapshot.map(\.id)
                self.isRunning = true
                self.status = snapshot.isEmpty
                    ? "Chat opened · WeChat exposed no message text"
                    : (snapshot.contains(where: { !$0.senderIdentified }) ? "Manual analysis only · sender unclear" : "Monitoring this conversation")
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
        accessibilityQueue.async { [weak self] in
            let contact = bridge.currentContact()
            let snapshot = contact == nil ? [] : bridge.recentMessages(limit: 20)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPolling = false
                guard self.isRunning, self.generation == token else { return }
                guard let contact, contact == self.lockedContact else {
                    self.stop()
                    self.status = "Conversation changed or WeChat did not respond — activate again when the chat is open."
                    return
                }
                self.processSnapshot(snapshot, contact: contact)
            }
        }
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
        guard hasIncoming || hasUnknown else { status = "Monitoring this conversation"; return }
        scheduleBurst(contact: contact, canAutoAnalyze: hasIncoming && snapshot.allSatisfy(\.senderIdentified))
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
            self.onBurst?(contact, self.messages.suffix(20).map { $0 }, canAutoAnalyze)
        }
    }
}
