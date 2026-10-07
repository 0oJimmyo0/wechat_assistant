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
    private var contextHistory: [ChatMessage] = []
    private var lockedContact: String?
    private var generation = 0
    private var isCheckingConversation = false
    private var isPolling = false
    private var unidentifiedPolls = 0
    private var candidateContact: String?
    private var candidateContactPolls = 0
    private let unidentifiedPollLimit = 5
    private let contactSwitchConfirmationCount = 2
    private let contextHistoryLimit = 100
    private let automaticAnalysisContextLimit = 50
    private let pollingInterval: TimeInterval = 1

    func start() {
        guard !isRunning, !isCheckingConversation else { return }
        guard bridge.hasAccessibilityPermission else { status = "Accessibility permission required"; bridge.requestAccessibilityPermission(); return }
        guard bridge.isWeChatRunning else { status = "WeChat not running"; return }
        isCheckingConversation = true
        unidentifiedPolls = 0
        candidateContact = nil
        candidateContactPolls = 0
        messages = []
        contextHistory = []
        lastIDs = []
        status = "Connected to WeChat · checking conversation"
        generation += 1
        let token = generation
        let bridge = self.bridge
        accessibilityQueue.async { [weak self] in
            let contact = bridge.currentContact()
            let treeCollapsed = contact == nil && bridge.accessibilityTreeAppearsCollapsed()
            let screenCaptureAllowed = WeChatScreenReader.hasScreenCapturePermission
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
                self.status = "Connected · reading recent messages"
            }
            guard let contact else { return }
            let result = bridge.readMessages()
            Task { @MainActor [weak self] in
                guard let self,
                      self.generation == token,
                      self.isRunning,
                      self.lockedContact == contact else { return }
                self.applyInitialReadResult(result, contact: contact)
                self.timer = Timer.scheduledTimer(withTimeInterval: self.pollingInterval, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.poll() }
                }
            }
        }
    }

    func stop() {
        isRunning = false
        isCheckingConversation = false
        isPolling = false
        unidentifiedPolls = 0
        candidateContact = nil
        candidateContactPolls = 0
        timer?.invalidate(); timer = nil
        debounce?.cancel(); debounce = nil
        generation += 1
        messages = []
        contextHistory = []
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
            let result = contact == nil || contact != lockedContact ? nil : bridge.readMessages(limit: 50)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPolling = false
                guard self.isRunning, self.generation == token else { return }
                guard let contact, !contact.isEmpty else {
                    self.unidentifiedPolls += 1
                    self.candidateContact = nil
                    self.candidateContactPolls = 0
                    self.contactName = nil
                    self.messages = []
                    if self.unidentifiedPolls >= self.unidentifiedPollLimit {
                        self.stop()
                        self.status = treeCollapsed
                            ? "Could not verify the conversation after several checks. Bring the chat to the front and activate again."
                            : "Could not identify the open WeChat conversation. Activate again when the chat is open."
                    } else {
                        self.status = "Conversation check missed (\(self.unidentifiedPolls)/\(self.unidentifiedPollLimit)) · retrying…"
                    }
                    return
                }
                self.unidentifiedPolls = 0

                guard contact == self.lockedContact else {
                    if self.candidateContact == contact {
                        self.candidateContactPolls += 1
                    } else {
                        self.candidateContact = contact
                        self.candidateContactPolls = 1
                    }
                    self.contactName = nil
                    self.messages = []
                    if self.candidateContactPolls >= self.contactSwitchConfirmationCount {
                        self.stop()
                        self.status = "Conversation changed. Activate again in the chat you want to monitor."
                    } else {
                        self.status = "Checking a possible conversation change…"
                    }
                    return
                }
                self.candidateContact = nil
                self.candidateContactPolls = 0
                guard let result else { return }
                switch result {
                case .messageListUnavailable(let collapsed):
                    self.messages = self.contextHistory
                    self.status = collapsed
                        ? self.collapsedTreeStatus(screenCaptureAllowed: WeChatScreenReader.hasScreenCapturePermission)
                        : "Conversation detected, but message list is unavailable"
                case .messageListFound(let snapshot, let renderedRows, let bubbleRows, _):
                    guard !snapshot.isEmpty else {
                        self.messages = self.contextHistory
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
            messages = contextHistory
            status = collapsed
                ? collapsedTreeStatus(screenCaptureAllowed: WeChatScreenReader.hasScreenCapturePermission)
                : "Conversation detected: \(contact) · message list is unavailable"
        case .messageListFound(let snapshot, let renderedRows, let bubbleRows, _):
            contextHistory = Array(snapshot.suffix(contextHistoryLimit))
            messages = contextHistory
            lastIDs = snapshot.map(contextKey)
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
        if snapshot.isEmpty {
            messages = contextHistory
            status = contextHistory.isEmpty
                ? "Chat opened · WeChat exposed no message text"
                : "Keeping captured context · no new visible messages"
            return
        }
        let ids = snapshot.map(contextKey)
        let previousHistory = contextHistory
        let mergedHistory = mergeContextHistory(snapshot)
        let historyChanged = mergedHistory.map(\.id) != contextHistory.map(\.id)
        let added = appendedMessages(previous: previousHistory, merged: mergedHistory)
        contextHistory = mergedHistory
        messages = contextHistory
        guard ids != lastIDs else {
            status = snapshot.allSatisfy { !$0.senderIdentified }
                ? "Monitoring · OCR senders are tentative"
                : "Monitoring this conversation"
            return
        }
        lastIDs = ids
        guard !added.isEmpty else {
            status = historyChanged ? "Conversation context updated" : "Monitoring this conversation"
            return
        }
        let hasIncoming = added.contains(where: { $0.senderIdentified && !$0.isFromMe })
        let hasUnknown = added.contains(where: { !$0.senderIdentified })
        guard hasIncoming else {
            status = hasUnknown ? "Message rows found, sender identity unavailable" : "Monitoring this conversation"
            return
        }
        scheduleBurst(contact: contact, canAutoAnalyze: WeChatParsing.canAutomaticallyAnalyze(contextHistory))
    }

    private func appendedMessages(previous: [ChatMessage], merged: [ChatMessage]) -> [ChatMessage] {
        guard !previous.isEmpty else { return [] }
        let previousKeys = previous.map(contextKey)
        let mergedKeys = merged.map(contextKey)
        for length in stride(from: min(previousKeys.count, mergedKeys.count), through: 1, by: -1) {
            let previousSuffix = Array(previousKeys.suffix(length))
            if Array(mergedKeys.prefix(length)) == previousSuffix {
                return Array(merged.dropFirst(length))
            }
        }
        return []
    }

    private func mergeContextHistory(_ visibleSnapshot: [ChatMessage]) -> [ChatMessage] {
        guard !contextHistory.isEmpty else {
            return Array(visibleSnapshot.suffix(contextHistoryLimit))
        }

        let historyIDs = contextHistory.map(contextKey)
        let visibleIDs = visibleSnapshot.map(contextKey)
        var refreshedHistory = contextHistory

        // New live messages appear after an overlap with the accumulated tail.
        for length in stride(from: min(historyIDs.count, visibleIDs.count), through: 1, by: -1) {
            let historySuffix = Array(historyIDs.suffix(length))
            for start in (0...(visibleIDs.count - length)).reversed() {
                guard Array(visibleIDs[start..<(start + length)]) == historySuffix else { continue }
                let historyStart = contextHistory.count - length
                for offset in 0..<length {
                    refreshedHistory[historyStart + offset] = visibleSnapshot[start + offset]
                }
                let tail = Array(visibleSnapshot.dropFirst(start + length))
                if !tail.isEmpty {
                    return Array((refreshedHistory + tail).suffix(contextHistoryLimit))
                }
                break
            }
        }

        // If the user scrolls to older rows, prepend unseen rows before any
        // matching portion of the captured timeline.
        for length in stride(from: min(historyIDs.count, visibleIDs.count), through: 1, by: -1) {
            for historyStart in 0...(historyIDs.count - length) {
                let historySegment = Array(historyIDs[historyStart..<(historyStart + length)])
                for visibleStart in 0...(visibleIDs.count - length) {
                    guard Array(visibleIDs[visibleStart..<(visibleStart + length)]) == historySegment else { continue }
                    for offset in 0..<length {
                        refreshedHistory[historyStart + offset] = visibleSnapshot[visibleStart + offset]
                    }
                    if visibleStart > 0 {
                        let older = Array(visibleSnapshot.prefix(visibleStart))
                        return Array((older + refreshedHistory).suffix(contextHistoryLimit))
                    }
                    return refreshedHistory
                }
            }
        }
        return refreshedHistory
    }

    private func contextKey(_ message: ChatMessage) -> String {
        let normalized = message.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let scalars = normalized.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) &&
                !CharacterSet.punctuationCharacters.contains($0)
        }
        let key = String(String.UnicodeScalarView(scalars))
        return key.isEmpty ? message.text : key
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
                self.onBurst?(contact, self.messages.suffix(self.automaticAnalysisContextLimit).map { $0 }, true)
            }
        }
    }
}
