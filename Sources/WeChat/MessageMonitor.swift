import Foundation
import Combine

@MainActor
final class MessageMonitor: ObservableObject {
    static let shared = MessageMonitor()
    @Published private(set) var isRunning = false
    @Published private(set) var contactName: String?
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var status = "Paused"
    var onBurst: ((String, [ChatMessage]) -> Void)?

    private let bridge = WeChatBridge.shared
    private var timer: Timer?
    private var debounce: Task<Void, Never>?
    private var lastIDs: [String] = []
    private var lastObservedContact: String?
    private var generation = 0

    func start() {
        guard !isRunning else { return }
        guard bridge.hasAccessibilityPermission else { status = "Accessibility permission required"; bridge.requestAccessibilityPermission(); return }
        guard bridge.isWeChatRunning else { status = "Open WeChat to start monitoring"; return }
        contactName = bridge.currentContact()
        messages = bridge.recentMessages()
        lastObservedContact = contactName
        lastIDs = messages.map(\.id)
        isRunning = true
        status = "Monitoring"
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        isRunning = false
        timer?.invalidate(); timer = nil
        debounce?.cancel(); debounce = nil
        status = "Paused"
    }

    func pollNow() { poll() }

    private func poll() {
        guard isRunning else { return }
        guard bridge.isWeChatRunning else { status = "WeChat is not running"; return }
        let contact = bridge.currentContact()
        let snapshot = bridge.recentMessages(limit: 20)
        if contact != lastObservedContact {
            lastObservedContact = contact
            contactName = contact
            messages = snapshot
            lastIDs = snapshot.map(\.id)
            debounce?.cancel(); debounce = nil
            status = "Monitoring"
            return
        }
        contactName = contact
        messages = snapshot
        let ids = snapshot.map(\.id)
        guard ids != lastIDs else { return }
        let added = newMessages(snapshot, old: lastIDs)
        lastIDs = ids
        guard added.contains(where: { !$0.isFromMe }) else { status = "Monitoring"; return }
        scheduleBurst(contact: contact ?? "WeChat", context: snapshot)
    }

    private func newMessages(_ current: [ChatMessage], old: [String]) -> [ChatMessage] {
        if old.isEmpty { return current }
        let ids = current.map(\.id)
        for length in stride(from: min(ids.count, old.count), through: 1, by: -1) {
            if Array(old.suffix(length)) == Array(ids.prefix(length)) { return Array(current.dropFirst(length)) }
        }
        return Array(current.suffix(1))
    }

    private func scheduleBurst(contact: String, context: [ChatMessage]) {
        generation += 1
        let token = generation
        debounce?.cancel()
        status = "Waiting for the message burst to finish…"
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self, self.isRunning, self.generation == token else { return }
            self.status = "Generating suggestions…"
            self.onBurst?(contact, self.messages.suffix(20).map { $0 })
        }
    }
}
