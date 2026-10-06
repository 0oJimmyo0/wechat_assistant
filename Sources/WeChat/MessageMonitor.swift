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
    private var timer: Timer?
    private var debounce: Task<Void, Never>?
    private var lastIDs: [String] = []
    private var lockedContact: String?
    private var generation = 0

    func start() {
        guard !isRunning else { return }
        guard bridge.hasAccessibilityPermission else { status = "Accessibility permission required"; bridge.requestAccessibilityPermission(); return }
        guard bridge.isWeChatRunning else { status = "Open WeChat to start monitoring"; return }
        guard let contact = bridge.currentContact(), !contact.isEmpty else { status = "Open a conversation before activating"; return }
        contactName = contact
        messages = bridge.recentMessages()
        lockedContact = contact
        lastIDs = messages.map(\.id)
        isRunning = true
        status = messages.contains(where: { !$0.senderIdentified }) ? "Manual analysis only · sender unclear" : "Monitoring this conversation"
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        isRunning = false
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
        guard isRunning else { return }
        guard bridge.isWeChatRunning else {
            stop()
            status = "WeChat is not running — activate again when it is open."
            return
        }
        guard let contact = bridge.currentContact(), contact == lockedContact else {
            stop()
            status = "Conversation changed — activate again to monitor this chat."
            return
        }
        let snapshot = bridge.recentMessages(limit: 20)
        contactName = contact
        messages = snapshot
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
