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
    // Session-only bounded fingerprints prevent scroll-back from looking like incoming text.
    private var seenHashes: Set<Int> = []
    private var seenHashOrder: [Int] = []
    private var lockedContact: String?
    private var generation = 0
    private var burstGeneration = 0
    private var isCheckingConversation = false
    private var isPolling = false

    func start() {
        guard !isRunning, !isCheckingConversation else { return }
        guard bridge.hasAccessibilityPermission else {
            status = "Accessibility permission required"
            bridge.requestAccessibilityPermission()
            return
        }
        guard bridge.isWeChatRunning else { status = "Open WeChat to start monitoring"; return }
        isCheckingConversation = true
        status = "Checking the open WeChat conversation…"
        generation += 1
        let token = generation
        let bridge = self.bridge
        accessibilityQueue.async { [weak self] in
            // A single capture replaces two expensive full-window AX traversals.
            let snapshot = bridge.capture(limit: 20)
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.isCheckingConversation = false
                guard let contact = snapshot.contact, !contact.isEmpty else {
                    self.status = "Open a conversation before activating"
                    return
                }
                self.contactName = contact
                self.messages = snapshot.messages
                self.lockedContact = contact
                self.lastIDs = snapshot.messages.map(\.id)
                self.rememberSeen(self.lastIDs)
                self.isRunning = true
                self.status = self.captureStatus(snapshot)
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
        timer?.invalidate()
        timer = nil
        debounce?.cancel()
        debounce = nil
        generation += 1
        burstGeneration += 1
        messages = []
        lastIDs = []
        seenHashes.removeAll()
        seenHashOrder.removeAll()
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
            let snapshot = bridge.capture(limit: 20)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPolling = false
                guard self.isRunning, self.generation == token else { return }
                guard let contact = snapshot.contact, contact == self.lockedContact else {
                    self.stop()
                    self.status = "Conversation changed or WeChat did not respond — activate again when the chat is open."
                    return
                }
                self.processSnapshot(snapshot, contact: contact)
            }
        }
    }

    private func captureStatus(_ snapshot: WeChatSnapshot) -> String {
        if !snapshot.messageListFound { return "Chat detected · message list not exposed" }
        if snapshot.messages.isEmpty {
            return snapshot.bubbleRowsFound > 0
                ? "Message list detected · bubble text unavailable"
                : "Message list detected · no visible chat bubbles"
        }
        return snapshot.messages.contains(where: { !$0.senderIdentified })
            ? "Messages ready · sender unclear (manual analysis)"
            : "Monitoring this conversation"
    }

    private func processSnapshot(_ snapshot: WeChatSnapshot, contact: String) {
        contactName = contact
        guard !snapshot.messages.isEmpty else {
            // Temporary AX failures must not erase the last good snapshot or make
            // recovered old messages look like a newly received burst.
            status = captureStatus(snapshot)
            return
        }
        messages = snapshot.messages
        let ids = snapshot.messages.map(\.id)
        guard ids != lastIDs else { return }
        let candidates = newMessages(snapshot.messages, old: lastIDs)
        let added = candidates.filter { !seenHashes.contains($0.id.hashValue) }
        rememberSeen(ids)
        lastIDs = ids

        // An unanchored view change (including scrolling to earlier history)
        // is not evidence of a newly received message.
        guard !added.isEmpty else {
            status = "Context updated · use Analyze for this view"
            return
        }
        let hasIncoming = added.contains(where: { $0.senderIdentified && !$0.isFromMe })
        let hasUnknown = added.contains(where: { !$0.senderIdentified })
        guard hasIncoming || hasUnknown else {
            status = captureStatus(snapshot)
            return
        }
        scheduleBurst(contact: contact, canAutoAnalyze: hasIncoming && snapshot.messages.allSatisfy(\.senderIdentified))
    }

    private func newMessages(_ current: [ChatMessage], old: [String]) -> [ChatMessage] {
        guard !old.isEmpty else { return [] }
        let ids = current.map(\.id)
        for length in stride(from: min(ids.count, old.count), through: 1, by: -1) {
            if Array(old.suffix(length)) == Array(ids.prefix(length)) {
                return Array(current.dropFirst(length))
            }
        }
        // No overlap is ambiguous: scroll/recycling/failed reads vs truly new.
        return []
    }

    private func rememberSeen(_ ids: [String]) {
        for id in ids {
            let hash = id.hashValue
            if seenHashes.insert(hash).inserted { seenHashOrder.append(hash) }
        }
        if seenHashOrder.count > 400 {
            let excess = seenHashOrder.count - 400
            for hash in seenHashOrder.prefix(excess) { seenHashes.remove(hash) }
            seenHashOrder.removeFirst(excess)
        }
    }

    private func scheduleBurst(contact: String, canAutoAnalyze: Bool) {
        burstGeneration += 1
        let token = burstGeneration
        debounce?.cancel()
        status = "Waiting for the message burst to finish…"
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self, self.isRunning, self.burstGeneration == token else { return }
            self.status = canAutoAnalyze ? "Message ready · analyzing" : "Message ready · Analyze manually"
            self.onBurst?(contact, Array(self.messages.suffix(20)), canAutoAnalyze)
        }
    }
}
