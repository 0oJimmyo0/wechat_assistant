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
    private var stableVisionIdentity: VisionConversationIdentity?
    private var candidateVisionIdentity: VisionConversationIdentity?
    private var titleConsensusCount = 0
    private let unidentifiedPollLimit = 5
    private let accessibilitySwitchConfirmationCount = 2
    private let visionSwitchConfirmationCount = 3
    private let minimumVisionSwitchTitleConfidence: Float = 0.35
    private let contextHistoryLimit = 100
    private let automaticAnalysisContextLimit = 50
    private let pollingInterval: TimeInterval = 1

    var visionIdentityDiagnostic: String {
        [
            "Stable contact state: \(lockedContact == nil ? "unset" : "set")",
            "Candidate contact active: \(candidateContact == nil ? "no" : "yes")",
            "Candidate contact consecutive detections: \(candidateContactPolls)",
            "Vision title consensus count: \(titleConsensusCount)",
            "Consecutive title misses: \(unidentifiedPolls)"
        ].joined(separator: "\n")
    }

    func start() {
        guard !isRunning, !isCheckingConversation else { return }
        guard bridge.hasAccessibilityPermission else { status = "Accessibility permission required"; bridge.requestAccessibilityPermission(); return }
        guard bridge.isWeChatRunning else { status = "WeChat not running"; return }
        isCheckingConversation = true
        unidentifiedPolls = 0
        candidateContact = nil
        candidateContactPolls = 0
        isUsingVision = false
        messages = []
        contextHistory = []
        lastIDs = []
        stableVisionIdentity = nil
        candidateVisionIdentity = nil
        titleConsensusCount = 0
        status = "Identifying conversation…"
        generation += 1
        let token = generation
        let bridge = self.bridge
        let minimumTitleConfidence = minimumVisionSwitchTitleConfidence
        accessibilityQueue.async { [weak self] in
            var detection = bridge.detectCurrentConversation()
            var contact = detection.contact
            var titleWasUnstable = false
            var consensusCount = 0
            if detection.visionSnapshot != nil {
                var captures = [detection]
                Thread.sleep(forTimeInterval: 0.12)
                captures.append(bridge.detectCurrentConversation(forceFreshVision: true))

                let fastPairIsStrong: Bool = {
                    guard captures.count == 2,
                          let first = captures[0].visionSnapshot?.titleIdentity,
                          let second = captures[1].visionSnapshot?.titleIdentity else { return false }
                    return first.isSpatiallyConsistent(with: second) &&
                        (captures[0].visionSnapshot?.acceptedTitleConfidence ?? 0) >= 0.60 &&
                        (captures[1].visionSnapshot?.acceptedTitleConfidence ?? 0) >= 0.60
                }()
                if fastPairIsStrong {
                    detection = captures[1]
                    contact = detection.contact
                    consensusCount = 2
                } else {
                    Thread.sleep(forTimeInterval: 0.12)
                    captures.append(bridge.detectCurrentConversation(forceFreshVision: true))
                    let latestPairConfirmsTitle: Bool = {
                        guard let earlier = captures[1].visionSnapshot?.titleIdentity,
                              let later = captures[2].visionSnapshot?.titleIdentity else { return false }
                        return (captures[1].visionSnapshot?.acceptedTitleConfidence ?? 0) >= minimumTitleConfidence &&
                            (captures[2].visionSnapshot?.acceptedTitleConfidence ?? 0) >= minimumTitleConfidence &&
                            earlier.isSpatiallyConsistent(with: later)
                    }()
                    let confirmedIndex = latestPairConfirmsTitle ? 2 : nil
                    if let confirmedIndex {
                        detection = captures[confirmedIndex]
                        contact = detection.contact
                        consensusCount = 2
                    } else {
                        detection = captures.last ?? detection
                        contact = nil
                        titleWasUnstable = true
                    }
                }
            }
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.isCheckingConversation = false
                guard let contact, !contact.isEmpty else {
                    self.requestScreenCaptureAccessIfNeeded(detection.visionSnapshot?.captureState)
                    self.status = titleWasUnstable
                        ? "Identifying conversation… title did not remain stable across captures"
                        : self.detectionFailureStatus(detection)
                    return
                }
                self.contactName = contact
                self.lockedContact = contact
                self.isUsingVision = detection.visionSnapshot != nil
                self.stableVisionIdentity = detection.visionSnapshot?.titleIdentity
                self.candidateVisionIdentity = nil
                self.titleConsensusCount = consensusCount
                self.isRunning = true
                self.status = "Conversation identified · reading messages"
            }
            guard let contact else { return }
            let result = bridge.readMessages(accurateVision: true)
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
        stableVisionIdentity = nil
        candidateVisionIdentity = nil
        titleConsensusCount = 0
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
        let lockedVisionIdentity = self.stableVisionIdentity
        let minimumTitleConfidence = self.minimumVisionSwitchTitleConfidence
        accessibilityQueue.async { [weak self] in
            let detection = bridge.detectCurrentConversation()
            let contact: String?
            if let vision = detection.visionSnapshot {
                contact = (vision.acceptedTitleConfidence ?? 0) >= minimumTitleConfidence
                    ? detection.contact
                    : nil
            } else {
                contact = lockedVisionIdentity == nil ? detection.contact : nil
            }
            let contactsMatch = contact.map { detected in
                guard let lockedContact else { return false }
                guard WeChatParsing.conversationIdentityKey(detected) == WeChatParsing.conversationIdentityKey(lockedContact) else { return false }
                if let lockedVisionIdentity {
                    guard let newIdentity = detection.visionSnapshot?.titleIdentity else { return false }
                    return lockedVisionIdentity.isSpatiallyConsistent(with: newIdentity)
                }
                return true
            } ?? false
            let result = contactsMatch ? bridge.readMessages(limit: 50, accurateVision: false) : nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPolling = false
                guard self.isRunning, self.generation == token else { return }
                guard let contact, !contact.isEmpty else {
                    self.unidentifiedPolls += 1
                    self.candidateContact = nil
                    self.candidateContactPolls = 0
                    self.candidateVisionIdentity = nil
                    self.titleConsensusCount = 0
                    if self.unidentifiedPolls >= self.unidentifiedPollLimit {
                        let failureStatus = self.detectionFailureStatus(detection)
                        self.stop()
                        self.status = failureStatus
                    } else {
                        self.status = "Verifying conversation… (\(self.unidentifiedPolls)/\(self.unidentifiedPollLimit))"
                    }
                    return
                }

                let matchesLockedTitle = self.lockedContact.map {
                    self.conversationKey(contact) == self.conversationKey($0)
                } ?? false
                let matchesLockedPosition: Bool
                if let stableIdentity = self.stableVisionIdentity, detection.visionSnapshot != nil {
                    matchesLockedPosition = detection.visionSnapshot?.titleIdentity.map {
                        stableIdentity.isSpatiallyConsistent(with: $0)
                    } ?? false
                } else {
                    matchesLockedPosition = self.stableVisionIdentity == nil
                }
                guard matchesLockedTitle && matchesLockedPosition else {
                    let incomingKey = self.conversationKey(contact)
                    let incomingIdentity = detection.visionSnapshot?.titleIdentity
                    let sameCandidateText = self.candidateContact.map {
                        self.conversationKey($0) == incomingKey
                    } ?? false
                    let sameCandidatePosition: Bool
                    if let current = self.candidateVisionIdentity, let incomingIdentity {
                        sameCandidatePosition = current.isSpatiallyConsistent(with: incomingIdentity)
                    } else {
                        sameCandidatePosition = self.candidateVisionIdentity == nil && incomingIdentity == nil
                    }
                    if sameCandidateText && sameCandidatePosition {
                        self.candidateContactPolls += 1
                    } else {
                        self.candidateContact = contact
                        self.candidateContactPolls = 1
                        self.candidateVisionIdentity = incomingIdentity
                    }
                    self.titleConsensusCount = self.candidateContactPolls
                    let requiredCount = detection.visionSnapshot == nil
                        ? self.accessibilitySwitchConfirmationCount
                        : self.visionSwitchConfirmationCount
                    if self.candidateContactPolls >= requiredCount {
                        self.stop()
                        self.status = "Conversation changed. Activate again in the chat you want to monitor."
                    } else {
                        self.status = "Checking a possible conversation change… (\(self.candidateContactPolls)/\(requiredCount))"
                    }
                    return
                }
                self.unidentifiedPolls = 0
                self.candidateContact = nil
                self.candidateContactPolls = 0
                self.candidateVisionIdentity = nil
                self.titleConsensusCount = self.stableVisionIdentity == nil ? 0 : 3
                self.isUsingVision = self.isUsingVision || detection.visionSnapshot != nil
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
                            ? (renderedRows == 0 ? "Vision OCR found no text" : "Vision found \(renderedRows) text observations; 0 passed chat-message filtering")
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
                    ? (renderedRows == 0 ? "Vision OCR found no text" : "Vision found \(renderedRows) text observations; 0 passed chat-message filtering")
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
                ? "Vision found \(vision.messageObservationCount) text observations; 0 passed chat-message filtering"
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
        if message.id.hasPrefix("vision:") { return message.id }
        let normalized = message.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let scalars = normalized.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) &&
                !CharacterSet.punctuationCharacters.contains($0)
        }
        let key = String(String.UnicodeScalarView(scalars))
        let sender: String
        switch message.sender {
        case .me: sender = "me"
        case .other: sender = "other"
        case .unknown: sender = "unknown"
        }
        return "\(sender):\(key.isEmpty ? message.text : key)"
    }

    private func conversationKey(_ contact: String) -> String {
        WeChatParsing.conversationIdentityKey(contact)
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
