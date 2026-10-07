import Foundation
import Combine

private enum SnapshotPurpose: Equatable {
    case livePolling
    case historicalBackfill
}

final class MonitorWorkCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

@MainActor
final class MessageMonitor: ObservableObject {
    static let shared = MessageMonitor()
    @Published private(set) var isRunning = false
    @Published private(set) var contactName: String?
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var status = "Paused"
    @Published private(set) var isLoadingOlderContext = false
    @Published private(set) var olderContextProgress: String?
    @Published private(set) var olderContextStatus: String?
    @Published private(set) var canLoadOlderContext = true
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
    private var activationTimeoutWorkItem: DispatchWorkItem?
    private var sessionCancellation: MonitorWorkCancellation?
    private var lastActivationDiagnostic = "Activation timing: not recorded yet"
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
    private let automaticAnalysisContextLimit = 30
    private let targetContextCount = 20
    private let maxScrollAttempts = 5
    private let maxNoProgressAttempts = 2
    private let olderContextTimeout: TimeInterval = 9
    private let olderContextScrollFraction: CGFloat = 0.5
    private let olderContextRenderDelay: UInt64 = 300_000_000
    private var lastTitleConsensusDiagnostic = "Title consensus: not run"
    private var lastOlderContextDiagnostic = "Older-context load: not run"
    private let pollingInterval: TimeInterval = 1

    var visionIdentityDiagnostic: String {
        [
            "Stable contact state: \(lockedContact == nil ? "unset" : "set")",
            "Candidate contact active: \(candidateContact == nil ? "no" : "yes")",
            "Candidate contact consecutive detections: \(candidateContactPolls)",
            "Vision title consensus count: \(titleConsensusCount)",
            "Consecutive title misses: \(unidentifiedPolls)",
            lastTitleConsensusDiagnostic,
            lastOlderContextDiagnostic,
            lastActivationDiagnostic
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
        isLoadingOlderContext = false
        olderContextProgress = nil
        olderContextStatus = nil
        canLoadOlderContext = true
        lastIDs = []
        stableVisionIdentity = nil
        candidateVisionIdentity = nil
        titleConsensusCount = 0
        lastTitleConsensusDiagnostic = "Title observations: pending"
        generation += 1
        let token = generation
        let cancellation = MonitorWorkCancellation()
        sessionCancellation?.cancel()
        sessionCancellation = cancellation
        status = "Finding WeChat window…"
        let timeout = DispatchWorkItem { [weak self, cancellation] in
            guard let self, self.generation == token, self.isCheckingConversation else { return }
            cancellation.cancel()
            self.isCheckingConversation = false
            self.generation += 1
            self.activationTimeoutWorkItem = nil
            self.lastActivationDiagnostic = "Activation total: >=5000 ms\n\(self.bridge.readerBackendDiagnostic)"
            self.status = "Conversation identification timed out. Retry or inspect Vision diagnostics."
        }
        activationTimeoutWorkItem?.cancel()
        activationTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
        let activationStarted = ProcessInfo.processInfo.systemUptime
        let bridge = self.bridge
        let minimumTitleConfidence = minimumVisionSwitchTitleConfidence
        accessibilityQueue.async { [weak self] in
            var titleCaptureWallMilliseconds: [Int] = []
            var titleConsensusDiagnostic = "Title consensus: not run"
            let stageUpdate: (String) -> Void = { [weak self] value in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token, self.isCheckingConversation else { return }
                    self.status = value
                }
            }
            let firstCaptureStarted = ProcessInfo.processInfo.systemUptime
            var detection = bridge.detectCurrentConversation(onStage: stageUpdate)
            titleCaptureWallMilliseconds.append(Int((ProcessInfo.processInfo.systemUptime - firstCaptureStarted) * 1000))
            guard !cancellation.isCancelled else { return }
            var titleDetections = [detection]
            var contact = detection.contact
            var titleWasUnstable = false
            var consensusCount = 0
            if detection.visionSnapshot != nil {
                var captures = [detection]
                Thread.sleep(forTimeInterval: 0.12)
                guard !cancellation.isCancelled else { return }
                stageUpdate("Confirming conversation…")
                let secondCaptureStarted = ProcessInfo.processInfo.systemUptime
                let secondDetection = bridge.detectCurrentConversation(forceFreshVision: true)
                captures.append(secondDetection)
                titleDetections.append(secondDetection)
                titleCaptureWallMilliseconds.append(Int((ProcessInfo.processInfo.systemUptime - secondCaptureStarted) * 1000))
                guard !cancellation.isCancelled else { return }

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
                    guard !cancellation.isCancelled else { return }
                    let thirdCaptureStarted = ProcessInfo.processInfo.systemUptime
                    let thirdDetection = bridge.detectCurrentConversation(forceFreshVision: true)
                    captures.append(thirdDetection)
                    titleDetections.append(thirdDetection)
                    titleCaptureWallMilliseconds.append(Int((ProcessInfo.processInfo.systemUptime - thirdCaptureStarted) * 1000))
                    guard !cancellation.isCancelled else { return }
                    let consensus = VisionTitleConsensus.evaluate(
                        captures.map { $0.visionSnapshot?.titleIdentity },
                        minimumConfidence: minimumTitleConfidence
                    )
                    if let bestPair = consensus.bestPair {
                        detection = captures[bestPair.secondIndex]
                        contact = detection.contact
                        consensusCount = 2
                        titleConsensusDiagnostic = consensus.diagnostic
                    } else {
                        detection = captures.last ?? detection
                        contact = nil
                        titleWasUnstable = true
                        titleConsensusDiagnostic = consensus.diagnostic
                    }
                }
                if fastPairIsStrong {
                    titleConsensusDiagnostic = VisionTitleConsensus.evaluate(
                        captures.map { $0.visionSnapshot?.titleIdentity },
                        minimumConfidence: 0.60
                    ).diagnostic
                }
            } else {
                titleConsensusDiagnostic = "Title observations: 1\nBackend: \(detection.backend.rawValue)\nSemantic title accepted"
            }
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.lastTitleConsensusDiagnostic = titleConsensusDiagnostic
                self.isCheckingConversation = false
                self.activationTimeoutWorkItem?.cancel()
                self.activationTimeoutWorkItem = nil
                guard let contact, !contact.isEmpty else {
                    self.lastActivationDiagnostic = self.activationTimingReport(
                        titleDetections: titleDetections,
                        titleCaptureWallMilliseconds: titleCaptureWallMilliseconds,
                        messageReadMilliseconds: nil,
                        totalMilliseconds: Int((ProcessInfo.processInfo.systemUptime - activationStarted) * 1000)
                    )
                    self.requestScreenCaptureAccessIfNeeded(detection.visionSnapshot?.captureState)
                    self.status = titleWasUnstable
                        ? "Could not confirm a stable conversation title. Try again or inspect Vision diagnostics."
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
            guard !cancellation.isCancelled else { return }
            let messageReadStarted = ProcessInfo.processInfo.systemUptime
            let result = bridge.readMessages(accurateVision: true)
            let messageReadMilliseconds = Int((ProcessInfo.processInfo.systemUptime - messageReadStarted) * 1000)
            let totalMilliseconds = Int((ProcessInfo.processInfo.systemUptime - activationStarted) * 1000)
            Task { @MainActor [weak self] in
                guard let self,
                      self.generation == token,
                      self.isRunning,
                      self.lockedContact == contact else { return }
                self.lastActivationDiagnostic = self.activationTimingReport(
                    titleDetections: titleDetections,
                    titleCaptureWallMilliseconds: titleCaptureWallMilliseconds,
                    messageReadMilliseconds: messageReadMilliseconds,
                    totalMilliseconds: totalMilliseconds
                )
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
        isLoadingOlderContext = false
        olderContextProgress = nil
        olderContextStatus = nil
        canLoadOlderContext = true
        unidentifiedPolls = 0
        candidateContact = nil
        candidateContactPolls = 0
        stableVisionIdentity = nil
        candidateVisionIdentity = nil
        titleConsensusCount = 0
        activationTimeoutWorkItem?.cancel()
        activationTimeoutWorkItem = nil
        sessionCancellation?.cancel()
        sessionCancellation = nil
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

    func loadOlderContext() {
        guard isRunning, !isLoadingOlderContext, !isPolling, canLoadOlderContext,
              contextHistory.count < targetContextCount,
              let contact = lockedContact else { return }
        let originalIdentity = stableVisionIdentity

        timer?.invalidate()
        timer = nil
        debounce?.cancel()
        debounce = nil
        generation += 1
        isLoadingOlderContext = true
        olderContextProgress = "\(contextHistory.count) / \(targetContextCount)"
        olderContextStatus = nil
        let token = generation
        let bridge = self.bridge
        let cancellation = sessionCancellation
        let startingCount = contextHistory.count
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runOlderContextLoad(
                bridge: bridge,
                contact: contact,
                identity: originalIdentity,
                cancellation: cancellation,
                startingCount: startingCount,
                generation: token
            )
        }
    }

    private func runOlderContextLoad(
        bridge: WeChatBridge,
        contact: String,
        identity: VisionConversationIdentity?,
        cancellation: MonitorWorkCancellation?,
        startingCount: Int,
        generation token: Int
    ) async {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let deadline = startedAt + olderContextTimeout
        let scrollFraction = olderContextScrollFraction
        var attempts = 0
        var noProgressAttempts = 0
        var identityFailure = false
        var captureFailure = false
        var timedOut = false
        var reachedEnd = false

        while isRunning, generation == token, contextHistory.count < targetContextCount,
              attempts < maxScrollAttempts, ProcessInfo.processInfo.systemUptime < deadline {
            let scrollResult = await performAccessibilityOperation {
                bridge.scrollMessagePaneUpwardIfConversationMatches(
                    contact: contact,
                    identity: identity,
                    fraction: scrollFraction,
                    cancellation: cancellation
                )
            }
            guard isRunning, generation == token else { return }
            switch scrollResult {
            case .scrolled:
                attempts += 1
            case .conversationChanged, .identityUncertain:
                identityFailure = true
                break
            case .cancelled:
                return
            case .windowUnavailable, .scrollUnavailable:
                captureFailure = true
                break
            }
            if identityFailure || captureFailure { break }

            do { try await Task.sleep(nanoseconds: olderContextRenderDelay) }
            catch { return }
            guard isRunning, generation == token else { return }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                timedOut = true
                break
            }

            let readResult = await performAccessibilityOperation {
                bridge.readMessagesIfConversationMatches(
                    contact: contact, identity: identity, accurate: true, cancellation: cancellation
                )
            }
            guard isRunning, generation == token else { return }
            switch readResult {
            case .conversationChanged, .identityUncertain:
                identityFailure = true
            case .cancelled:
                return
            case .captureUnavailable:
                captureFailure = true
            case .messages(let result):
                switch result {
                case .messageListUnavailable:
                    captureFailure = true
                case .messageListFound(let snapshot, _, _, _, _):
                    let beforeCount = contextHistory.count
                    processSnapshot(snapshot, contact: contact, purpose: .historicalBackfill)
                    let afterCount = contextHistory.count
                    olderContextProgress = "\(afterCount) / \(targetContextCount)"
                    if afterCount > beforeCount {
                        noProgressAttempts = 0
                    } else {
                        noProgressAttempts += 1
                    }
                    if snapshot.isEmpty { reachedEnd = noProgressAttempts >= maxNoProgressAttempts }
                }
            }
            if identityFailure || captureFailure || contextHistory.count >= targetContextCount { break }
            if noProgressAttempts >= maxNoProgressAttempts {
                reachedEnd = true
                break
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                timedOut = true
                break
            }
        }

        guard isRunning, generation == token else { return }
        let endingCount = contextHistory.count
        let elapsedMilliseconds = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
        let newCount = max(0, endingCount - startingCount)
        if identityFailure {
            olderContextStatus = "Stopped loading older context because the conversation could not be verified."
            canLoadOlderContext = false
        } else if captureFailure {
            olderContextStatus = "Could not read older messages from the WeChat window."
        } else if endingCount >= targetContextCount {
            olderContextStatus = "Loaded \(endingCount) messages. WeChat is scrolled to older messages."
        } else if reachedEnd || noProgressAttempts >= maxNoProgressAttempts {
            olderContextStatus = "Loaded \(endingCount) messages. No additional older messages could be matched. WeChat is scrolled to older messages."
        } else if timedOut || attempts >= maxScrollAttempts || ProcessInfo.processInfo.systemUptime >= deadline {
            olderContextStatus = "Loaded \(endingCount) messages. Stopped after the bounded loading limit. WeChat is scrolled to older messages."
        } else {
            olderContextStatus = "Loaded \(endingCount) messages. WeChat is scrolled to older messages."
        }
        lastOlderContextDiagnostic = [
            "Older-context load:",
            "attempts: \(attempts)",
            "starting count: \(startingCount)",
            "ending count: \(endingCount)",
            "new messages merged: \(newCount)",
            "no-progress attempts: \(noProgressAttempts)",
            "identity checks failed: \(identityFailure ? 1 : 0)",
            "elapsed ms: \(elapsedMilliseconds)"
        ].joined(separator: "\n")
        isLoadingOlderContext = false
        olderContextProgress = nil
        if isRunning {
            timer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
        }
    }

    private func performAccessibilityOperation<T: Sendable>(
        _ operation: @escaping @Sendable () -> T
    ) async -> T {
        let queue = accessibilityQueue
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: operation())
            }
        }
    }

    private func poll() {
        guard isRunning, !isPolling, !isLoadingOlderContext else { return }
        isPolling = true
        let token = generation
        let bridge = self.bridge
        let lockedContact = self.lockedContact
        let lockedVisionIdentity = self.stableVisionIdentity
        let cancellation = self.sessionCancellation
        let minimumTitleConfidence = self.minimumVisionSwitchTitleConfidence
        accessibilityQueue.async { [weak self] in
            let detection = bridge.detectCurrentConversation()
            guard cancellation?.isCancelled != true else { return }
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
            guard cancellation?.isCancelled != true else { return }
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
                    self.processSnapshot(snapshot, contact: contact, purpose: .livePolling)
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

    private func activationTimingReport(
        titleDetections: [WeChatConversationDetection],
        titleCaptureWallMilliseconds: [Int],
        messageReadMilliseconds: Int?,
        totalMilliseconds: Int
    ) -> String {
        let first = titleDetections.first
        var lines = [
            "Backend: \(first?.backend.rawValue ?? "unknown")",
            "Main window AX lookup: \(first?.mainWindowLookupMilliseconds ?? 0) ms",
            "AX capability probe: \(first?.capabilityProbeMilliseconds ?? 0) ms"
        ]
        for index in titleDetections.indices {
            let snapshot = titleDetections[index].visionSnapshot
            lines.append("Title capture \(index + 1): wall \(index < titleCaptureWallMilliseconds.count ? titleCaptureWallMilliseconds[index] : 0) ms, window discovery \(snapshot?.windowDiscoveryDurationMilliseconds ?? 0) ms, screenshot \(snapshot?.captureDurationMilliseconds ?? 0) ms, OCR \(snapshot?.visionDurationMilliseconds ?? 0) ms")
        }
        lines.append("Title confirmation total: \(titleCaptureWallMilliseconds.reduce(0, +)) ms")
        lines.append("Initial message read (OCR/AX): \(messageReadMilliseconds.map { "\($0) ms" } ?? "not run")")
        lines.append("Activation total: \(totalMilliseconds) ms")
        return lines.joined(separator: "\n")
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

    private func processSnapshot(_ snapshot: [ChatMessage], contact: String, purpose: SnapshotPurpose) {
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
        if purpose == .historicalBackfill {
            lastIDs = ids
            status = "Older chat context updated · \(contextHistory.count) messages"
            return
        }
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
        ChatHistoryMerger.appended(previous: previous, merged: merged)
    }

    private func mergeContextHistory(_ visibleSnapshot: [ChatMessage]) -> [ChatMessage] {
        ChatHistoryMerger.merge(existing: contextHistory, visible: visibleSnapshot, limit: contextHistoryLimit)
    }

    private func contextKey(_ message: ChatMessage) -> String {
        ChatHistoryMerger.key(for: message)
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
