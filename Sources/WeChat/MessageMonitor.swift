import Foundation
import Combine

private enum SnapshotPurpose: Equatable {
    case livePolling
    case historicalBackfill
    case manualSync
}

enum ConversationIdentityState: String, Sendable {
    case confirmed
    case temporarilyUncertain
    case candidateChange
    case changed
}

private enum LiveTailRestoreResult: Equatable {
    case reached
    case notReached
    case conversationChanged
    case identityUncertain
    case captureFailed
    case cancelled
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
    @Published private(set) var viewportState: ChatViewportState = .uncertain
    @Published private(set) var conversationIdentityState: ConversationIdentityState = .temporarilyUncertain
    @Published private(set) var isFollowingLatest = false
    @Published private(set) var hasUnverifiedMessageChanges = false
    @Published private(set) var isReturningToLatest = false
    @Published private(set) var isSyncing = false
    @Published private(set) var storageStatus: String?
    var onBurst: ((String, [ChatMessage], Bool) -> Void)?
    var onDeactivated: (() -> Void)?

    private let bridge = WeChatBridge.shared
    private let conversationStore = ConversationStore.shared
    private let accessibilityQueue = DispatchQueue(label: "com.wechatreplycopilot.accessibility")
    private var timer: Timer?
    private var debounce: Task<Void, Never>?
    private var lastIDs: [String] = []
    private var lastMessageFingerprint: String?
    private var lastSemanticMessageKeys: [String] = []
    private var contextHistory: [ChatMessage] = []
    private var lockedContact: String?
    private var activeConversationKey: String?
    private var persistentHistoryBuffer: [ChatMessage] = []
    private var persistenceTask: Task<Void, Never>?
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
    private var lastTitleValidationUptime: TimeInterval = 0
    private var pendingAutomaticBurst = false
    private var messageCaptureCount = 0
    private var messageOCRRunCount = 0
    private var unchangedFrameCount = 0
    private var latestSnapshotBlockCount = 0
    private var latestTailOverlap = 0
    private var latestHistoricalOverlap = 0
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
    private let latestRestoreTimeout: TimeInterval = 4
    private let olderContextScrollFraction: CGFloat = 0.5
    private let olderContextRenderDelay: UInt64 = 300_000_000
    private let titleValidationInterval: TimeInterval = 4
    private let identityMissStopLimit = 5
    private var lastTitleConsensusDiagnostic = "Title consensus: not run"
    private var lastOlderContextDiagnostic = "Older-context load: not run"
    private let pollingInterval: TimeInterval = 0.8

    var visionIdentityDiagnostic: String {
        [
            "Stable contact state: \(lockedContact == nil ? "unset" : "set")",
            "Candidate contact active: \(candidateContact == nil ? "no" : "yes")",
            "Candidate contact consecutive detections: \(candidateContactPolls)",
            "Vision title consensus count: \(titleConsensusCount)",
            "Consecutive title misses: \(unidentifiedPolls)",
            lastTitleConsensusDiagnostic,
            lastOlderContextDiagnostic,
            realtimeDiagnostic,
            lastActivationDiagnostic
        ].joined(separator: "\n")
    }

    private var realtimeDiagnostic: String {
        let age = lastTitleValidationUptime > 0
            ? String(format: "%.1f sec", ProcessInfo.processInfo.systemUptime - lastTitleValidationUptime)
            : "unavailable"
        return [
            "Realtime monitor:",
            "viewport: \(viewportState.rawValue)",
            "message captures: \(messageCaptureCount)",
            "message OCR runs: \(messageOCRRunCount)",
            "unchanged frames skipped: \(unchangedFrameCount)",
            "latest snapshot blocks: \(latestSnapshotBlockCount)",
            "history size: \(contextHistory.count)",
            "tail overlap: \(latestTailOverlap)",
            "historical overlap: \(latestHistoricalOverlap)",
            "title validation age: \(age)",
            "conversation identity: \(conversationIdentityState.rawValue)"
        ].joined(separator: "\n")
    }

    var canAnalyzeManually: Bool {
        conversationIdentityState == .confirmed && !hasUnverifiedMessageChanges && viewportState != .uncertain
    }

    var canSyncNow: Bool {
        isRunning && lockedContact != nil && !isLoadingOlderContext && !isPolling && !isSyncing
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
        activeConversationKey = nil
        persistentHistoryBuffer = []
        persistenceTask?.cancel()
        persistenceTask = nil
        isLoadingOlderContext = false
        isFollowingLatest = false
        isReturningToLatest = false
        olderContextProgress = nil
        olderContextStatus = nil
        canLoadOlderContext = true
        lastIDs = []
        lastMessageFingerprint = nil
        lastSemanticMessageKeys = []
        viewportState = .uncertain
        conversationIdentityState = .temporarilyUncertain
        lastTitleValidationUptime = 0
        hasUnverifiedMessageChanges = false
        pendingAutomaticBurst = false
        messageCaptureCount = 0
        messageOCRRunCount = 0
        unchangedFrameCount = 0
        latestSnapshotBlockCount = 0
        latestTailOverlap = 0
        latestHistoricalOverlap = 0
        storageStatus = nil
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
                self.activeConversationKey = self.conversationStore.identityKey(for: contact)
                if self.conversationStore.isEnabled, let key = self.activeConversationKey {
                    do {
                        self.persistentHistoryBuffer = try self.conversationStore.load(identityKey: key)
                        self.contextHistory = Array(self.persistentHistoryBuffer.suffix(self.contextHistoryLimit))
                        self.messages = self.contextHistory
                    } catch {
                        self.storageStatus = "Saved local context could not be unlocked; continuing with this session only"
                    }
                }
                self.isUsingVision = detection.visionSnapshot != nil
                self.stableVisionIdentity = detection.visionSnapshot?.titleIdentity
                self.conversationIdentityState = .confirmed
                self.lastTitleValidationUptime = ProcessInfo.processInfo.systemUptime
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
        isSyncing = false
        isFollowingLatest = false
        isReturningToLatest = false
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
        flushConversationSave()
        generation += 1
        messages = []
        contextHistory = []
        persistentHistoryBuffer = []
        lastIDs = []
        lastMessageFingerprint = nil
        lastSemanticMessageKeys = []
        viewportState = .uncertain
        conversationIdentityState = .temporarilyUncertain
        hasUnverifiedMessageChanges = false
        pendingAutomaticBurst = false
        contactName = nil
        lockedContact = nil
        activeConversationKey = nil
        isUsingVision = false
        status = "Paused"
        onDeactivated?()
    }

    func pollNow() { poll() }

    func syncNow() {
        guard canSyncNow, let contact = lockedContact else { return }
        isSyncing = true
        status = "Syncing latest messages…"
        generation += 1
        let token = generation
        debounce?.cancel(); debounce = nil
        pendingAutomaticBurst = false
        let bridge = self.bridge
        let identity = stableVisionIdentity
        let cancellation = sessionCancellation
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.viewportState == .historical {
                self.isReturningToLatest = true
                let restore = await self.restoreToLatest(bridge: bridge, contact: contact, identity: identity,
                                                         cancellation: cancellation, generation: token)
                self.isReturningToLatest = false
                guard self.isRunning, self.generation == token else { return }
                guard restore == .reached else {
                    self.isSyncing = false
                    if restore == .conversationChanged {
                        self.stop()
                        self.status = "Conversation changed. Activate again in the chat you want to monitor."
                    } else {
                        self.status = restore == .identityUncertain
                            ? "Could not verify the current conversation"
                            : "Could not return to the latest messages · live tracking remains paused"
                    }
                    return
                }
            }

            let result = await self.performAccessibilityOperation {
                bridge.readMessagesIfConversationMatches(
                    contact: contact, identity: identity, accurate: true, forceFresh: true, cancellation: cancellation
                )
            }
            guard self.isRunning, self.generation == token else { return }
            switch result {
            case .conversationChanged:
                self.stop()
                self.status = "Conversation changed. Activate again in the chat you want to monitor."
            case .identityUncertain:
                self.conversationIdentityState = .temporarilyUncertain
                self.isSyncing = false
                self.status = "Could not verify the current conversation"
            case .captureUnavailable:
                self.isSyncing = false
                self.status = "Could not capture the current WeChat conversation"
            case .cancelled:
                self.isSyncing = false
            case .messages(let readResult):
                self.conversationIdentityState = .confirmed
                self.hasUnverifiedMessageChanges = false
                switch readResult {
                case .messageListUnavailable(_, let visionState):
                    self.isSyncing = false
                    self.status = visionState.map(self.visionCaptureFailureStatus) ?? "Could not read visible messages"
                case .messageListUnchanged:
                    self.isSyncing = false
                    self.status = "Sync complete · no visible changes"
                case .messageListFound(let snapshot, _, _, _, let isVision, let fingerprint):
                    let previousCount = self.contextHistory.count
                    let previousHistory = self.contextHistory
                    self.isUsingVision = self.isUsingVision || isVision
                    self.messageCaptureCount += 1
                    self.messageOCRRunCount += isVision ? 1 : 0
                    self.latestSnapshotBlockCount = snapshot.count
                    self.lastMessageFingerprint = fingerprint
                    self.lastSemanticMessageKeys = snapshot.map(self.contextKey)
                    self.processSnapshot(snapshot, contact: contact, purpose: .manualSync)
                    let currentKeys = self.contextHistory.map(self.contextKey)
                    let newCount = ChatHistoryMerger.appended(previous: previousHistory, merged: self.contextHistory).count
                    let totalAdded = max(0, self.contextHistory.count - previousCount)
                    if self.viewportState == .uncertain {
                        self.status = "Sync complete · visible context could not be matched safely"
                    } else if newCount > 0 {
                        self.status = "Synced · \(newCount) new messages"
                    } else if totalAdded > 0 {
                        self.status = "Synced · \(self.contextHistory.count) messages captured"
                    } else if currentKeys == previousHistory.map(self.contextKey) {
                        self.status = "Sync complete · no visible changes"
                    } else {
                        self.status = "Synced · \(self.contextHistory.count) messages captured"
                    }
                    self.isSyncing = false
                }
            }
        }
    }

    func clearCurrentStoredHistory() throws {
        guard let key = activeConversationKey else { return }
        stop()
        try conversationStore.clear(identityKey: key)
        status = "Current conversation history cleared"
    }

    func clearAllStoredHistory() throws {
        stop()
        try conversationStore.clearAll()
        status = "All stored conversation history cleared"
    }


    func loadOlderContext() {
        guard isRunning, !isLoadingOlderContext, !isPolling, !isSyncing, canLoadOlderContext,
              viewportState == .liveTail,
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
        var restoredToTail = false

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
                case .messageListUnchanged(let fingerprint):
                    lastMessageFingerprint = fingerprint
                    noProgressAttempts += 1
                case .messageListFound(let snapshot, _, _, _, _, let fingerprint):
                    lastMessageFingerprint = fingerprint
                    conversationIdentityState = .confirmed
                    lastTitleValidationUptime = ProcessInfo.processInfo.systemUptime
                    hasUnverifiedMessageChanges = false
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
        if !identityFailure, attempts > 0 {
            isReturningToLatest = true
            olderContextStatus = "Returning to latest messages…"
            let restoreResult = await restoreToLatest(bridge: bridge, contact: contact, identity: identity,
                                                      cancellation: cancellation, generation: token)
            guard isRunning, generation == token else { return }
            switch restoreResult {
            case .reached:
                restoredToTail = true
            case .conversationChanged, .identityUncertain:
                identityFailure = true
            case .captureFailed:
                captureFailure = true
            case .notReached:
                break
            case .cancelled:
                return
            }
        } else if viewportState == .liveTail {
            restoredToTail = true
        }
        isReturningToLatest = false
        let endingCount = contextHistory.count
        let elapsedMilliseconds = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
        let newCount = max(0, endingCount - startingCount)
        if identityFailure {
            olderContextStatus = "Stopped loading older context because the conversation could not be verified."
            canLoadOlderContext = false
        } else if captureFailure {
            olderContextStatus = "Could not read older messages from the WeChat window."
        } else if restoredToTail {
            olderContextStatus = "\(endingCount) captured · live monitoring resumed"
        } else if reachedEnd || noProgressAttempts >= maxNoProgressAttempts {
            olderContextStatus = "\(endingCount) captured · viewing older history; live message tracking paused"
        } else if timedOut || attempts >= maxScrollAttempts || ProcessInfo.processInfo.systemUptime >= deadline {
            olderContextStatus = "\(endingCount) captured · viewing older history; live message tracking paused"
        } else {
            olderContextStatus = "\(endingCount) captured · viewing older history; live message tracking paused"
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

    func followLatest() {
        guard isRunning, !isLoadingOlderContext, !isPolling, !isSyncing, viewportState != .liveTail,
              let contact = lockedContact else { return }
        timer?.invalidate()
        timer = nil
        debounce?.cancel()
        debounce = nil
        generation += 1
        isLoadingOlderContext = true
        isFollowingLatest = true
        isReturningToLatest = true
        olderContextStatus = nil
        let token = generation
        let bridge = self.bridge
        let identity = stableVisionIdentity
        let cancellation = sessionCancellation
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.restoreToLatest(bridge: bridge, contact: contact, identity: identity,
                                                    cancellation: cancellation, generation: token)
            guard self.isRunning, self.generation == token else { return }
            self.isReturningToLatest = false
            self.isFollowingLatest = false
            self.isLoadingOlderContext = false
            if result == .reached {
                self.olderContextStatus = "\(self.contextHistory.count) captured · live monitoring resumed"
                self.status = "Live monitoring resumed"
            } else {
                if result == .conversationChanged || result == .identityUncertain {
                    self.conversationIdentityState = .temporarilyUncertain
                }
                self.viewportState = .historical
                self.olderContextStatus = "\(self.contextHistory.count) captured · viewing older history; live message tracking paused"
                self.status = "Viewing older messages · live incoming tracking paused"
            }
            self.timer = Timer.scheduledTimer(withTimeInterval: self.pollingInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
        }
    }

    private func restoreToLatest(
        bridge: WeChatBridge,
        contact: String,
        identity: VisionConversationIdentity?,
        cancellation: MonitorWorkCancellation?,
        generation token: Int
    ) async -> LiveTailRestoreResult {
        isReturningToLatest = true
        let deadline = ProcessInfo.processInfo.systemUptime + latestRestoreTimeout
        for _ in 0..<maxScrollAttempts {
            guard isRunning, generation == token else { return .cancelled }
            guard ProcessInfo.processInfo.systemUptime < deadline else { return .notReached }
            let scrollResult = await performAccessibilityOperation {
                bridge.scrollMessagePaneDownwardIfConversationMatches(
                    contact: contact, identity: identity, fraction: self.olderContextScrollFraction,
                    cancellation: cancellation
                )
            }
            guard isRunning, generation == token else { return .cancelled }
            switch scrollResult {
            case .scrolled: break
            case .conversationChanged: return .conversationChanged
            case .identityUncertain: return .identityUncertain
            case .windowUnavailable, .scrollUnavailable: return .captureFailed
            case .cancelled: return .cancelled
            }
            do { try await Task.sleep(nanoseconds: olderContextRenderDelay) }
            catch { return .cancelled }
            guard isRunning, generation == token else { return .cancelled }
            let readResult = await performAccessibilityOperation {
                bridge.readMessagesIfConversationMatches(
                    contact: contact, identity: identity, accurate: false, cancellation: cancellation
                )
            }
            guard isRunning, generation == token else { return .cancelled }
            switch readResult {
            case .conversationChanged: return .conversationChanged
            case .identityUncertain: return .identityUncertain
            case .captureUnavailable: return .captureFailed
            case .cancelled: return .cancelled
            case .messages(let result):
                switch result {
                case .messageListUnavailable: return .captureFailed
                case .messageListUnchanged(let fingerprint):
                    lastMessageFingerprint = fingerprint
                    unchangedFrameCount += 1
                case .messageListFound(let snapshot, _, _, _, _, let fingerprint):
                    messageCaptureCount += 1
                    messageOCRRunCount += 1
                    latestSnapshotBlockCount = snapshot.count
                    lastMessageFingerprint = fingerprint
                    lastSemanticMessageKeys = snapshot.map(contextKey)
                    let classification = classifyVisibleSnapshot(snapshot)
                    viewportState = classification.state
                    latestTailOverlap = classification.tailOverlap
                    latestHistoricalOverlap = classification.historicalOverlap
                    if classification.state == .liveTail {
                        conversationIdentityState = .confirmed
                        lastTitleValidationUptime = ProcessInfo.processInfo.systemUptime
                        hasUnverifiedMessageChanges = false
                        processSnapshot(snapshot, contact: contact, purpose: .historicalBackfill)
                        return .reached
                    }
                    if classification.state == .historical {
                        processSnapshot(snapshot, contact: contact, purpose: .historicalBackfill)
                    }
                }
            }
        }
        return .notReached
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
        guard isRunning, !isPolling, !isLoadingOlderContext, !isSyncing else { return }
        isPolling = true
        let token = generation
        let bridge = self.bridge
        let cancellation = sessionCancellation
        let shouldValidateTitle = lastTitleValidationUptime == 0 ||
            ProcessInfo.processInfo.systemUptime - lastTitleValidationUptime >= titleValidationInterval
        let previousFingerprint = lastMessageFingerprint
        let useVision = isUsingVision
        accessibilityQueue.async { [weak self] in
            let detection = shouldValidateTitle ? bridge.detectCurrentConversation(forceFreshVision: true) : nil
            guard cancellation?.isCancelled != true else { return }
            // Message capture is independent of title OCR. Vision always captures a fresh
            // frame; its perceptual fingerprint can skip text recognition on unchanged pixels.
            let result = bridge.readMessages(
                limit: 50,
                accurateVision: false,
                forceFresh: true,
                previousFingerprint: useVision ? previousFingerprint : nil
            )
            guard cancellation?.isCancelled != true else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPolling = false
                guard self.isRunning, self.generation == token else { return }
                self.messageCaptureCount += 1
                let identityConfirmedThisPoll: Bool
                if let detection {
                    identityConfirmedThisPoll = self.applyConversationIdentityObservation(detection)
                    guard self.isRunning, self.generation == token else { return }
                } else {
                    identityConfirmedThisPoll = false
                }

                switch result {
                case .messageListUnavailable(let collapsed, let visionState):
                    self.requestScreenCaptureAccessIfNeeded(visionState)
                    self.status = visionState.map(self.visionCaptureFailureStatus) ?? (collapsed
                        ? self.collapsedTreeStatus(screenCaptureAllowed: WeChatScreenReader.hasScreenCapturePermission)
                        : "Conversation detected, but message list is unavailable")
                    return
                case .messageListUnchanged(let fingerprint):
                    self.lastMessageFingerprint = fingerprint
                    self.unchangedFrameCount += 1
                    self.finishPendingAutomaticBurstIfSafe(identityConfirmedThisPoll: identityConfirmedThisPoll)
                    return
                case .messageListFound(let snapshot, _, _, _, let isVision, let fingerprint):
                    self.isUsingVision = self.isUsingVision || isVision
                    self.messageOCRRunCount += 1
                    self.latestSnapshotBlockCount = snapshot.count
                    if isVision {
                        self.lastMessageFingerprint = fingerprint
                    } else {
                        let keys = snapshot.map(self.contextKey)
                        guard keys != self.lastSemanticMessageKeys else {
                            self.unchangedFrameCount += 1
                            self.finishPendingAutomaticBurstIfSafe(identityConfirmedThisPoll: identityConfirmedThisPoll)
                            return
                        }
                        self.lastSemanticMessageKeys = keys
                    }
                    if !identityConfirmedThisPoll {
                        self.hasUnverifiedMessageChanges = true
                    }
                    if self.conversationIdentityState == .candidateChange {
                        return
                    }
                    self.processSnapshot(snapshot, contact: self.lockedContact ?? "", purpose: .livePolling)
                    self.finishPendingAutomaticBurstIfSafe(identityConfirmedThisPoll: identityConfirmedThisPoll)
                }
            }
        }
    }

    @discardableResult
    private func applyConversationIdentityObservation(_ detection: WeChatConversationDetection) -> Bool {
        lastTitleValidationUptime = ProcessInfo.processInfo.systemUptime
        let acceptedConfidence = detection.visionSnapshot?.acceptedTitleConfidence ??
            (detection.visionSnapshot == nil ? 1 : 0)
        guard detection.windowFound,
              let detectedContact = detection.contact,
              !detectedContact.isEmpty,
              acceptedConfidence >= minimumVisionSwitchTitleConfidence else {
            conversationIdentityState = .temporarilyUncertain
            unidentifiedPolls += 1
            candidateContact = nil
            candidateContactPolls = 0
            candidateVisionIdentity = nil
            titleConsensusCount = 0
            if unidentifiedPolls >= identityMissStopLimit {
                let failureStatus = detectionFailureStatus(detection)
                stop()
                status = failureStatus
            } else {
                status = "Conversation identity temporarily uncertain · local capture continues"
            }
            return false
        }

        let matchesName = lockedContact.map {
            conversationKey(detectedContact) == conversationKey($0)
        } ?? false
        let matchesGeometry: Bool
        if let stableIdentity = stableVisionIdentity {
            matchesGeometry = detection.visionSnapshot?.titleIdentity.map {
                stableIdentity.isSpatiallyConsistent(with: $0)
            } ?? false
        } else {
            matchesGeometry = true
        }
        if matchesName && matchesGeometry {
            conversationIdentityState = .confirmed
            unidentifiedPolls = 0
            candidateContact = nil
            candidateContactPolls = 0
            candidateVisionIdentity = nil
            titleConsensusCount = stableVisionIdentity == nil ? 0 : 3
            hasUnverifiedMessageChanges = false
            return true
        }

        guard !matchesName else {
            conversationIdentityState = .temporarilyUncertain
            unidentifiedPolls += 1
            candidateContact = nil
            candidateContactPolls = 0
            candidateVisionIdentity = nil
            titleConsensusCount = 0
            status = "Conversation title geometry uncertain · local capture continues"
            return false
        }

        let incomingIdentity = detection.visionSnapshot?.titleIdentity
        let sameCandidateText = candidateContact.map {
            conversationKey($0) == conversationKey(detectedContact)
        } ?? false
        let sameCandidatePosition: Bool
        if let current = candidateVisionIdentity, let incomingIdentity {
            sameCandidatePosition = current.isSpatiallyConsistent(with: incomingIdentity)
        } else {
            sameCandidatePosition = candidateVisionIdentity == nil && incomingIdentity == nil
        }
        if sameCandidateText && sameCandidatePosition {
            candidateContactPolls += 1
        } else {
            candidateContact = detectedContact
            candidateContactPolls = 1
            candidateVisionIdentity = incomingIdentity
        }
        conversationIdentityState = .candidateChange
        titleConsensusCount = candidateContactPolls
        let requiredCount = detection.visionSnapshot == nil
            ? accessibilitySwitchConfirmationCount
            : visionSwitchConfirmationCount
        if candidateContactPolls >= requiredCount {
            stop()
            conversationIdentityState = .changed
            status = "Conversation changed. Activate again in the chat you want to monitor."
        } else {
            status = "Checking a possible conversation change… (\(candidateContactPolls)/\(requiredCount))"
        }
        return false
    }

    private func finishPendingAutomaticBurstIfSafe(identityConfirmedThisPoll: Bool) {
        guard identityConfirmedThisPoll, pendingAutomaticBurst,
              conversationIdentityState == .confirmed,
              !hasUnverifiedMessageChanges,
              viewportState == .liveTail else { return }
        pendingAutomaticBurst = false
        scheduleBurst(contact: lockedContact ?? "", canAutoAnalyze: WeChatParsing.canAutomaticallyAnalyze(contextHistory))
    }

    private func applyInitialReadResult(_ result: MessageReadResult, contact: String) {
        switch result {
        case .messageListUnavailable(let collapsed, let visionState):
            requestScreenCaptureAccessIfNeeded(visionState)
            messages = contextHistory
            status = visionState.map(visionCaptureFailureStatus) ?? (collapsed
                ? collapsedTreeStatus(screenCaptureAllowed: WeChatScreenReader.hasScreenCapturePermission)
                : "Conversation detected: \(contact) · message list is unavailable")
        case .messageListUnchanged(let fingerprint):
            lastMessageFingerprint = fingerprint
            viewportState = .liveTail
            status = "Monitoring this conversation"
        case .messageListFound(let snapshot, let renderedRows, let bubbleRows, _, let isVision, let fingerprint):
            isUsingVision = isUsingVision || isVision
            let classification = classifyVisibleSnapshot(snapshot)
            viewportState = classification.state
            latestTailOverlap = classification.tailOverlap
            latestHistoricalOverlap = classification.historicalOverlap
            if classification.state != .uncertain {
                contextHistory = ChatHistoryMerger.merge(existing: contextHistory, visible: snapshot,
                                                         limit: contextHistoryLimit)
                mergeIntoPersistentHistory(snapshot)
                scheduleConversationSave()
            } else if contextHistory.isEmpty {
                contextHistory = Array(snapshot.suffix(contextHistoryLimit))
            }
            messages = contextHistory
            lastIDs = snapshot.map(contextKey)
            lastSemanticMessageKeys = lastIDs
            lastMessageFingerprint = fingerprint
            latestSnapshotBlockCount = snapshot.count
            if classification.state == .uncertain {
                status = "Stored context restored · visible messages could not be reconciled safely"
                hasUnverifiedMessageChanges = true
                return
            }
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
        if snapshot.isEmpty {
            messages = contextHistory
            status = contextHistory.isEmpty
                ? "Chat opened · WeChat exposed no message text"
                : "Keeping captured context · no new visible messages"
            return
        }
        let classification = classifyVisibleSnapshot(snapshot)
        viewportState = classification.state
        latestTailOverlap = classification.tailOverlap
        latestHistoricalOverlap = classification.historicalOverlap
        guard classification.state != .uncertain else {
            status = "Visible messages could not be matched safely · keeping captured context"
            return
        }
        contactName = contact
        let ids = snapshot.map(contextKey)
        let previousHistory = contextHistory
        let previousPersistentKeys = persistentHistoryBuffer.map(contextKey)
        let mergedHistory = mergeContextHistory(snapshot)
        let historyChanged = mergedHistory.map(\.id) != contextHistory.map(\.id)
        let added = appendedMessages(previous: previousHistory, merged: mergedHistory)
        contextHistory = mergedHistory
        messages = contextHistory
        mergeIntoPersistentHistory(snapshot)
        let persistentChanged = persistentHistoryBuffer.map(contextKey) != previousPersistentKeys
        if historyChanged || persistentChanged {
            scheduleConversationSave()
        }
        if purpose == .historicalBackfill || purpose == .manualSync || classification.state == .historical {
            lastIDs = ids
            pendingAutomaticBurst = false
            if purpose == .manualSync {
                status = "Syncing latest messages…"
            } else if isLoadingOlderContext {
                status = "Older chat context updated · \(contextHistory.count) messages"
            } else {
                status = "Viewing older messages · live incoming tracking paused"
            }
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
        let canAutomaticallyAnalyze = WeChatParsing.canAutomaticallyAnalyze(contextHistory)
        guard canAutomaticallyAnalyze else {
            status = hasUnknown ? "Message rows found, sender identity unavailable" : "Monitoring this conversation"
            return
        }
        guard conversationIdentityState == .confirmed,
              !hasUnverifiedMessageChanges,
              viewportState == .liveTail else {
            pendingAutomaticBurst = true
            status = "Incoming message captured · waiting to verify conversation"
            return
        }
        pendingAutomaticBurst = false
        scheduleBurst(contact: contact, canAutoAnalyze: true)
    }

    private func appendedMessages(previous: [ChatMessage], merged: [ChatMessage]) -> [ChatMessage] {
        ChatHistoryMerger.appended(previous: previous, merged: merged)
    }

    private func mergeContextHistory(_ visibleSnapshot: [ChatMessage]) -> [ChatMessage] {
        ChatHistoryMerger.merge(existing: contextHistory, visible: visibleSnapshot, limit: contextHistoryLimit)
    }

    private func classifyVisibleSnapshot(_ snapshot: [ChatMessage]) -> ChatViewportClassification {
        let timeline = conversationStore.isEnabled && !persistentHistoryBuffer.isEmpty
            ? persistentHistoryBuffer
            : contextHistory
        guard !timeline.isEmpty else {
            return ChatViewportClassification(state: .liveTail, tailOverlap: snapshot.count, historicalOverlap: 0)
        }
        return ChatHistoryMerger.classify(existing: timeline, visible: snapshot)
    }

    private func mergeIntoPersistentHistory(_ visibleSnapshot: [ChatMessage]) {
        guard conversationStore.isEnabled else { return }
        if persistentHistoryBuffer.isEmpty, !contextHistory.isEmpty {
            persistentHistoryBuffer = contextHistory
        }
        persistentHistoryBuffer = ChatHistoryMerger.merge(
            existing: persistentHistoryBuffer,
            visible: visibleSnapshot,
            limit: 500
        )
    }

    private func scheduleConversationSave() {
        guard conversationStore.isEnabled,
              let key = activeConversationKey,
              let name = lockedContact,
              !persistentHistoryBuffer.isEmpty else { return }
        persistenceTask?.cancel()
        let messagesToSave = persistentHistoryBuffer
        persistenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            do {
                try self.conversationStore.save(messages: messagesToSave, identityKey: key, displayName: name)
                self.persistenceTask = nil
            } catch {
                self.storageStatus = "Encrypted local history could not be saved"
                self.persistenceTask = nil
            }
        }
    }

    private func flushConversationSave() {
        persistenceTask?.cancel()
        persistenceTask = nil
        guard conversationStore.isEnabled,
              let key = activeConversationKey,
              let name = lockedContact,
              !persistentHistoryBuffer.isEmpty else { return }
        do {
            try conversationStore.save(messages: persistentHistoryBuffer, identityKey: key, displayName: name)
        } catch {
            storageStatus = "Encrypted local history could not be saved"
        }
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
        guard canAutoAnalyze,
              conversationIdentityState == .confirmed,
              !hasUnverifiedMessageChanges,
              viewportState == .liveTail else {
            pendingAutomaticBurst = canAutoAnalyze
            status = canAutoAnalyze
                ? "Incoming message captured · waiting to verify conversation"
                : "Message ready · Analyze manually"
            return
        }
        pendingAutomaticBurst = false
        status = "Waiting for the message burst to finish…"
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self, self.isRunning, self.generation == token else { return }
            guard self.conversationIdentityState == .confirmed,
                  !self.hasUnverifiedMessageChanges,
                  self.viewportState == .liveTail else {
                self.pendingAutomaticBurst = true
                self.status = "Incoming message captured · waiting to verify conversation"
                return
            }
            self.status = canAutoAnalyze ? "Message ready · analyzing" : "Message ready · Analyze manually"
            if canAutoAnalyze {
                self.onBurst?(contact, self.messages.suffix(self.automaticAnalysisContextLimit).map { $0 }, true)
            }
        }
    }
}
