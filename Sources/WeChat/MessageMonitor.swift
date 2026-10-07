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
    private var isUsingVision = false
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
            let detection = bridge.detectCurrentConversation()
            let contact = detection.contact
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.isCheckingConversation = false
                guard let contact, !contact.isEmpty else {
                    self.requestScreenCaptureAccessIfNeeded(detection.visionSnapshot?.captureState)
                    self.status = self.detectionFailureStatus(detection)
                    return
                }
                self.contactName = contact
                self.lockedContact = contact
                self.isUsingVision = detection.visionSnapshot != nil
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
        isUsingVision = false
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
            let detection = bridge.detectCurrentConversation()
            let contact = detection.contact
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
                        self.status = self.detectionFailureStatus(detection)
                    } else {
                        self.status = self.detectionFailureStatus(detection)
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
                self.isUsingVision = detection.visionSnapshot != nil
                guard let result else { return }
                switch result {
                case .messageListUnavailable(let collapsed, let visionState):
                    self.requestScreenCaptureAccessIfNeeded(visionState)
                    self.messages = self.contextHistory
                    self.status = visionState.map(self.visionCaptureFailureStatus) ?? (collapsed
                        ? self.collapsedTreeStatus(screenCaptureAllowed: WeChatScreenReader.hasScreenCapturePermission)
                        : "Conversation detected, but message list is unavailable")
                case .messageListFound(let snapshot, let renderedRows, let bubbleRows, _, let isVision):
                    self.isUsingVision = self.isUsingVision || isVision
                    guard !snapshot.isEmpty else {
                        self.messages = self.contextHistory
                        self.status = isVision
                            ? (renderedRows == 0 ? "Vision OCR found no text" : "Vision OCR found text, but no message bubbles were recognized")
                            : (renderedRows == 0 || bubbleRows == 0
                            ? "Message list found, but no rendered message rows are available"
                            : "Message rows found, but message text is unavailable")
                        return
                    }
                    self.processSnapshot(snapshot, contact: contact)
                }
            }
        }
    }

    private func applyInitialReadResult(_ result: MessageReadResult, contact: String) {
        switch result {
        case .messageListUnavailable(let collapsed, let visionState):
            requestScreenCaptureAccessIfNeeded(visionState)
            messages = contextHistory
            status = visionState.map(visionCaptureFailureStatus) ?? (collapsed
                ? collapsedTreeStatus(screenCaptureAllowed: WeChatScreenReader.hasScreenCapturePermission)
                : "Conversation detected: \(contact) · message list is unavailable")
        case .messageListFound(let snapshot, let renderedRows, let bubbleRows, _, let isVision):
            isUsingVision = isUsingVision || isVision
            contextHistory = Array(snapshot.suffix(contextHistoryLimit))
            messages = contextHistory
            lastIDs = snapshot.map(contextKey)
            if snapshot.isEmpty {
                status = isVision
                    ? (renderedRows == 0 ? "Vision OCR found no text" : "Vision OCR found text, but no message bubbles were recognized")
                    : (renderedRows == 0 || bubbleRows == 0
                    ? "Message list found, but no rendered message rows are available"
                    : "Message rows found, but message text is unavailable")
            } else if snapshot.allSatisfy({ !$0.senderIdentified }) {
                status = isUsingVision ? "Vision mode · sender identity tentative" : "Message rows found, sender identity unavailable"
            } else if snapshot.contains(where: { !$0.senderIdentified }) {
                status = isUsingVision ? "Vision mode · some sender identities tentative" : "Message rows found, some sender identities are unavailable"
            } else {
                status = isUsingVision ? "Vision mode · monitoring this conversation" : "Monitoring this conversation"
            }
        }
    }

    private func collapsedTreeStatus(screenCaptureAllowed: Bool) -> String {
        screenCaptureAllowed
            ? "WeChat window capture failed · keep the main chat window open and on screen"
            : "Screen Recording permission required · enable it in System Settings, then activate again"
    }

    private func detectionFailureStatus(_ detection: WeChatConversationDetection) -> String {
        guard detection.windowFound else { return "WeChat window not found" }
        guard let vision = detection.visionSnapshot else {
            return detection.treeCollapsed
                ? "Screen Recording permission required or WeChat window capture failed"
                : "Could not identify the open WeChat conversation"
        }
        guard vision.captureSucceeded else {
            return visionCaptureFailureStatus(vision.captureState)
        }
        if vision.ocrObservationCount == 0 { return "Vision OCR found no text" }
        if vision.title == nil {
            return vision.messages.isEmpty
                ? "Vision OCR found text, but no message bubbles were recognized"
                : "Conversation visible, but title OCR failed"
        }
        return "Conversation detected · reading messages"
    }

    private func visionCaptureFailureStatus(_ state: VisionCaptureState) -> String {
        switch state {
        case .screenRecordingPermissionRequired:
            return "Screen Recording permission required"
        case .weChatWindowNotFound:
            return "WeChat window not found"
        case .invalidWindow:
            return "WeChat window capture failed · selected window did not match the main chat"
        case .windowCaptureFailed:
            return "WeChat window capture failed"
        case .visionFailed:
            return "Vision OCR failed"
        case .success:
            return "WeChat window capture failed"
        }
    }

    private func requestScreenCaptureAccessIfNeeded(_ state: VisionCaptureState?) {
        guard state == .screenRecordingPermissionRequired else { return }
        WeChatScreenReader.requestScreenCapturePermissionOnce()
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
                : (isUsingVision ? "Vision mode · monitoring this conversation" : "Monitoring this conversation")
            return
        }
        lastIDs = ids
        guard !added.isEmpty else {
            status = historyChanged ? "Conversation context updated" : (isUsingVision ? "Vision mode · monitoring this conversation" : "Monitoring this conversation")
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
