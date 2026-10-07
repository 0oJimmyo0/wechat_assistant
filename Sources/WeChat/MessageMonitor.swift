import Foundation
import Combine

enum ConversationIdentityState: String, Sendable {
    case confirmed
    case temporarilyUncertain
    case candidateChange
    case changed
}

private enum SnapshotPurpose {
    case live
    case historical
    case manualSync
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
    @Published private(set) var acquisitionState: ConversationAcquisitionState = .inactive
    @Published private(set) var isFollowingLatest = false
    @Published private(set) var hasUnverifiedMessageChanges = false
    @Published private(set) var isReturningToLatest = false
    @Published private(set) var isSyncing = false

    var onBurst: ((String, [ChatMessage], Bool) -> Void)?
    var onDeactivated: (() -> Void)?

    private let bridge = WeChatBridge.shared
    private let conversationStore = ConversationStore()
    private let pendingIdentityStore = ConversationStore(maximumMessages: 50)
    private let accessibilityObserver = AccessibilityObserver()
    private let accessibilityQueue = DispatchQueue(label: "com.wechatreplycopilot.accessibility")
    private var timer: Timer?
    private var burstDebounce: Task<Void, Never>?
    private var observerDebounce: Task<Void, Never>?
    private var lockedContact: String?
    private var lockedVisionIdentity: VisionConversationIdentity?
    private var pendingVisionIdentity: VisionConversationIdentity?
    private var pendingHeaderFingerprint: String?
    private var candidateContact: String?
    private var candidateContactPolls = 0
    private var isCheckingConversation = false
    private var isPolling = false
    private var generation = 0
    private var lastObservedSnapshot: [String] = []
    private var lastHeaderFingerprint: String?
    private var visionMessageBaseline = VisionMessageBaseline()
    private var activeMessagePaneLeftX: CGFloat?
    private var lastProcessedIncomingMessage: UUID?
    private var sessionCancellation: MonitorWorkCancellation?
    private var lastTitleValidationUptime: TimeInterval = 0
    private var messageCaptureCount = 0
    private var consecutiveEmptyAXSnapshots = 0
    private var consecutiveCaptureFailures = 0
    private var latestSnapshotBlockCount = 0
    private var latestTailOverlap = 0
    private var latestHistoricalOverlap = 0
    private var lastOlderContextDiagnostic = "Older-context load: not run"
    private let historyLimit = 200
    private let analysisContextLimit = 20
    private let watchdogInterval: TimeInterval = 3
    private let observerDebounceNanoseconds: UInt64 = 400_000_000
    private let rowMaterializationDelay: UInt64 = 350_000_000
    private let maxScrollAttempts = 6
    private let maxNoProgressAttempts = 2

    private var contextHistory: [ChatMessage] { conversationStore.messages }

    var canAnalyzeManually: Bool {
        acquisitionState == .ready && conversationIdentityState == .confirmed &&
            !hasUnverifiedMessageChanges && viewportState != .uncertain
    }

    var canSyncNow: Bool {
        isRunning && lockedContact != nil && !isCheckingConversation && !isPolling &&
            !isLoadingOlderContext && !isSyncing
    }

    var visionIdentityDiagnostic: String {
        let age = lastTitleValidationUptime > 0
            ? String(format: "%.1f sec", ProcessInfo.processInfo.systemUptime - lastTitleValidationUptime)
            : "unavailable"
        return [
            "Acquisition state: \(acquisitionState.rawValue)",
            "Conversation identity: \(conversationIdentityState.rawValue)",
            "Candidate change observations: \(candidateContactPolls)",
            "Conversation captures: \(messageCaptureCount)",
            "Valid Vision message baseline: \(visionMessageBaseline.isValid ? "yes" : "no")",
            "Active message crop left edge: \(activeMessagePaneLeftX.map { String(format: "%.3f", $0) } ?? "configured")",
            "Latest observed rows: \(latestSnapshotBlockCount)",
            "Stored context size: \(conversationStore.messages.count)",
            "Tail overlap: \(latestTailOverlap)",
            "Historical overlap: \(latestHistoricalOverlap)",
            "Last successful identity validation age: \(age)",
            lastOlderContextDiagnostic,
            bridge.conversationCaptureDiagnostic,
            bridge.readerBackendDiagnostic
        ].joined(separator: "\n")
    }

    func start() {
        guard !isRunning, !isCheckingConversation else { return }
        guard bridge.hasAccessibilityPermission else {
            status = "Accessibility permission required"
            bridge.requestAccessibilityPermission()
            return
        }
        guard bridge.isWeChatRunning else { status = "WeChat not running"; return }

        resetForActivation()
        bridge.beginConversationSession()
        isCheckingConversation = true
        acquisitionState = .identifying
        status = "Reading the active WeChat conversation…"
        generation += 1
        let token = generation
        let cancellation = MonitorWorkCancellation()
        sessionCancellation?.cancel()
        sessionCancellation = cancellation
        let bridge = self.bridge
        let previousHeaderFingerprint = lastHeaderFingerprint
        let previousMessageFingerprint = visionMessageBaseline.fingerprint
        let preferredMessagePaneLeftX = activeMessagePaneLeftX
        accessibilityQueue.async { [weak self] in
            let captureResult = bridge.captureConversationSnapshot(
                previousHeaderFingerprint: previousHeaderFingerprint,
                previousMessageFingerprint: previousMessageFingerprint,
                initialActivation: true,
                messagePaneLeftX: preferredMessagePaneLeftX
            )
            guard cancellation.isCancelled == false else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.isCheckingConversation else { return }
                self.isCheckingConversation = false
                if case .identityPending(let observation) = captureResult {
                    self.retainPendingIdentityObservation(observation)
                    self.isRunning = true
                    self.conversationIdentityState = .temporarilyUncertain
                    self.acquisitionState = .messagesPending
                    self.status = "Messages captured locally · confirming conversation before analysis"
                    self.startWatchdog()
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        guard let self, self.isRunning, self.generation == token else { return }
                        self.poll()
                    }
                    return
                }
                guard case .success(let snapshot) = captureResult else {
                    self.noteCaptureFailure()
                    if case .failure(let failure) = captureResult {
                        self.status = failure.userMessage
                    }
                    return
                }
                self.consecutiveCaptureFailures = 0
                self.lockedContact = snapshot.contact
                self.lockedVisionIdentity = snapshot.visionIdentity
                self.contactName = snapshot.contact
                self.conversationIdentityState = .confirmed
                self.acquisitionState = ConversationAcquisitionState.resolve(
                    identityConfirmed: true, hasMessages: !snapshot.messages.isEmpty
                )
                self.lastTitleValidationUptime = ProcessInfo.processInfo.systemUptime
                self.isRunning = true
                self.applySnapshot(snapshot, purpose: .live, allowAutomaticAnalysis: false)
                self.status = snapshot.messages.isEmpty
                    ? "Conversation identified, but visible messages could not be read · retrying"
                    : "Monitoring this conversation · \(self.messages.count) messages in context"
                self.startAXObserver()
                self.startWatchdog()
            }
        }
    }

    private func resetForActivation() {
        stopTimersAndObserver()
        burstDebounce?.cancel(); burstDebounce = nil
        observerDebounce?.cancel(); observerDebounce = nil
        conversationStore.clear()
        pendingIdentityStore.clear()
        pendingVisionIdentity = nil
        pendingHeaderFingerprint = nil
        messages = []
        lastObservedSnapshot = []
        lastHeaderFingerprint = nil
        visionMessageBaseline.reset()
        activeMessagePaneLeftX = nil
        lastProcessedIncomingMessage = nil
        lockedContact = nil
        lockedVisionIdentity = nil
        contactName = nil
        candidateContact = nil
        candidateContactPolls = 0
        viewportState = .uncertain
        conversationIdentityState = .temporarilyUncertain
        acquisitionState = .inactive
        hasUnverifiedMessageChanges = false
        isLoadingOlderContext = false
        isSyncing = false
        isFollowingLatest = false
        isReturningToLatest = false
        olderContextProgress = nil
        olderContextStatus = nil
        canLoadOlderContext = true
        messageCaptureCount = 0
        latestSnapshotBlockCount = 0
        latestTailOverlap = 0
        latestHistoricalOverlap = 0
        consecutiveEmptyAXSnapshots = 0
        consecutiveCaptureFailures = 0
    }

    func stop() {
        let wasActive = isRunning || isCheckingConversation
        isRunning = false
        isCheckingConversation = false
        isPolling = false
        isLoadingOlderContext = false
        isSyncing = false
        isFollowingLatest = false
        isReturningToLatest = false
        olderContextProgress = nil
        sessionCancellation?.cancel()
        sessionCancellation = nil
        bridge.endConversationSession()
        stopTimersAndObserver()
        burstDebounce?.cancel(); burstDebounce = nil
        observerDebounce?.cancel(); observerDebounce = nil
        generation += 1
        conversationStore.clear()
        pendingIdentityStore.clear()
        pendingVisionIdentity = nil
        pendingHeaderFingerprint = nil
        messages = []
        lastObservedSnapshot = []
        lastHeaderFingerprint = nil
        visionMessageBaseline.reset()
        activeMessagePaneLeftX = nil
        lastProcessedIncomingMessage = nil
        lockedContact = nil
        lockedVisionIdentity = nil
        contactName = nil
        candidateContact = nil
        candidateContactPolls = 0
        viewportState = .uncertain
        conversationIdentityState = .temporarilyUncertain
        acquisitionState = .inactive
        hasUnverifiedMessageChanges = false
        consecutiveEmptyAXSnapshots = 0
        consecutiveCaptureFailures = 0
        status = "Paused"
        if wasActive { onDeactivated?() }
    }

    func pollNow() { poll() }

    func syncLatest() {
        guard canSyncNow, let contact = lockedContact else { return }
        isSyncing = true
        isReturningToLatest = viewportState == .historical
        status = "Syncing latest messages…"
        generation += 1
        let token = generation
        burstDebounce?.cancel(); burstDebounce = nil
        let cancellation = sessionCancellation
        Task { @MainActor [weak self] in
            guard let self else { return }
            var discoveredIncoming: [ChatMessage] = []
            if self.viewportState == .historical {
                let latest = await self.scrollToLatest(contact: contact, cancellation: cancellation,
                                                       generation: token)
                discoveredIncoming.append(contentsOf: latest.appended)
                guard self.isRunning, self.generation == token else { return }
                if !latest.reached {
                    self.isSyncing = false
                    self.isReturningToLatest = false
                    self.status = "Could not verify latest messages; stored context was kept"
                    return
                }
            }
            let result = await self.captureAndMerge(contact: contact, purpose: .manualSync,
                                                    cancellation: cancellation, generation: token)
            guard self.isRunning, self.generation == token else { return }
            if case .conversationChanged = result {
                self.stop()
                self.status = "Conversation changed. Activate again in the chat you want to monitor."
                return
            }
            if case .merged(let merge) = result { discoveredIncoming += merge.appended }
            self.isSyncing = false
            self.isReturningToLatest = false
            if !discoveredIncoming.isEmpty {
                self.processIncoming(discoveredIncoming, contact: contact)
                self.status = "Synced · \(discoveredIncoming.count) new messages"
            } else if case .merged(let merge) = result, merge.unchanged {
                self.status = "Sync complete · no visible changes"
            } else {
                self.status = "Synced · \(self.messages.count) messages in context"
            }
        }
    }

    /// Compatibility name for the sidebar's earlier Sync now action.
    func syncNow() { syncLatest() }

    func followLatest() {
        guard isRunning, !isLoadingOlderContext, !isPolling, !isSyncing,
              let contact = lockedContact else { return }
        isFollowingLatest = true
        isReturningToLatest = true
        isSyncing = true
        generation += 1
        let token = generation
        let cancellation = sessionCancellation
        Task { @MainActor [weak self] in
            guard let self else { return }
            let latest = await self.scrollToLatest(contact: contact, cancellation: cancellation,
                                                   generation: token)
            guard self.isRunning, self.generation == token else { return }
            self.isFollowingLatest = false
            self.isReturningToLatest = false
            self.isSyncing = false
            if !latest.appended.isEmpty { self.processIncoming(latest.appended, contact: contact) }
            self.status = latest.reached
                ? "Live monitoring resumed"
                : "Viewing older messages · live incoming tracking paused"
            self.startWatchdog()
        }
    }

    func loadOlderContext(targetCount: Int = 20) {
        guard isRunning, !isLoadingOlderContext, !isPolling, !isSyncing,
              canLoadOlderContext, messages.count < targetCount,
              let contact = lockedContact else { return }
        isLoadingOlderContext = true
        isReturningToLatest = false
        olderContextStatus = nil
        olderContextProgress = "\(messages.count) / \(targetCount)"
        timer?.invalidate(); timer = nil
        generation += 1
        let token = generation
        let cancellation = sessionCancellation
        Task { @MainActor [weak self] in
            guard let self else { return }
            let started = ProcessInfo.processInfo.systemUptime
            var attempts = 0
            var noProgress = 0
            var identityFailed = false
            var reachedTop = false
            while self.isRunning, self.generation == token, self.messages.count < targetCount,
                  attempts < self.maxScrollAttempts, noProgress < self.maxNoProgressAttempts {
                let before = self.messages.count
                let identity = self.lockedVisionIdentity
                let messagePaneLeftX = self.activeMessagePaneLeftX
                let workCancellation = self.sessionCancellation
                let scroll = await self.performAccessibilityOperation {
                    self.bridge.scrollMessagePaneUpwardIfConversationMatches(
                        contact: contact, identity: identity, fraction: 0.5,
                        messagePaneLeftX: messagePaneLeftX,
                        cancellation: workCancellation
                    )
                }
                guard self.isRunning, self.generation == token else { return }
                switch scroll {
                case .conversationChanged:
                    identityFailed = true
                    break
                case .identityUncertain, .windowUnavailable, .scrollUnavailable:
                    reachedTop = true
                    break
                case .cancelled:
                    return
                case .scrolled:
                    attempts += 1
                }
                if identityFailed || reachedTop { break }
                try? await Task.sleep(nanoseconds: self.rowMaterializationDelay)
                guard self.isRunning, self.generation == token else { return }
                let result = await self.captureAndMerge(contact: contact, purpose: .historical,
                                                        cancellation: cancellation, generation: token)
                guard self.isRunning, self.generation == token else { return }
                if case .conversationChanged = result { identityFailed = true; break }
                noProgress = self.messages.count > before ? 0 : noProgress + 1
                self.olderContextProgress = "\(self.messages.count) / \(targetCount)"
            }

            guard self.isRunning, self.generation == token else { return }
            self.isReturningToLatest = true
            let latest = await self.scrollToLatest(contact: contact, cancellation: cancellation,
                                                   generation: token)
            guard self.isRunning, self.generation == token else { return }
            self.isReturningToLatest = false
            self.isLoadingOlderContext = false
            self.olderContextProgress = nil
            if !identityFailed && (reachedTop || noProgress >= self.maxNoProgressAttempts) {
                self.canLoadOlderContext = false
            }
            if identityFailed {
                self.olderContextStatus = "Conversation could not be verified; older loading stopped"
                self.stop()
                self.status = "Conversation changed. Activate again in the chat you want to monitor."
            } else if latest.reached {
                self.olderContextStatus = "Context: \(self.messages.count) / \(targetCount) · latest messages restored"
            } else {
                self.olderContextStatus = "Context: \(self.messages.count) / \(targetCount) · live tracking paused"
            }
            self.lastOlderContextDiagnostic = [
                "Older-context load:", "scroll attempts: \(attempts)",
                "no-progress attempts: \(noProgress)", "top reached: \(reachedTop)",
                "stored count: \(self.messages.count)",
                "elapsed ms: \(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))"
            ].joined(separator: "\n")
            if !latest.appended.isEmpty { self.processIncoming(latest.appended, contact: contact) }
            self.startWatchdog()
        }
    }

    private enum CaptureMergeOutcome {
        case merged(ConversationMergeResult)
        case unavailable
        case identityUncertain
        case conversationChanged
    }

    private func captureAndMerge(contact: String, purpose: SnapshotPurpose,
                                 cancellation: MonitorWorkCancellation?, generation token: Int) async -> CaptureMergeOutcome {
        let bridge = self.bridge
        let identity = lockedVisionIdentity
        let previousHeaderFingerprint = lastHeaderFingerprint
        let previousMessageFingerprint = visionMessageBaseline.fingerprint
        let preferredMessagePaneLeftX = activeMessagePaneLeftX
        let captured: OlderContextReadResult? = await performAccessibilityOperation {
            if purpose == .historical {
                return bridge.readMessagesIfConversationMatches(contact: contact, identity: identity,
                                                               accurate: false, forceFresh: true,
                                                               previousHeaderFingerprint: previousHeaderFingerprint,
                                                               previousMessageFingerprint: previousMessageFingerprint,
                                                               messagePaneLeftX: preferredMessagePaneLeftX,
                                                               cancellation: cancellation)
            }
            let capture = bridge.captureConversationSnapshot(
                previousHeaderFingerprint: previousHeaderFingerprint,
                previousMessageFingerprint: previousMessageFingerprint,
                lockedContact: contact,
                messagePaneLeftX: preferredMessagePaneLeftX
            )
            guard case .success(let snapshot) = capture else { return nil }
            return .snapshot(snapshot)
        }
        guard isRunning, generation == token, cancellation?.isCancelled != true else { return .unavailable }
        let snapshot: WeChatSnapshot?
        switch captured {
        case .snapshot(let value): snapshot = value
        case .conversationChanged: return .conversationChanged
        case .identityUncertain, .captureUnavailable, .cancelled, .none: snapshot = nil
        }
        guard let snapshot else {
            noteCaptureFailure()
            status = "Conversation capture unavailable · keeping stored context"
            conversationIdentityState = .temporarilyUncertain
            hasUnverifiedMessageChanges = true
            return .unavailable
        }
        consecutiveCaptureFailures = 0
        switch confirmSnapshotContact(snapshot.contact) {
        case .confirmed: break
        case .candidate: return .identityUncertain
        case .changed: return .conversationChanged
        }
        lastTitleValidationUptime = ProcessInfo.processInfo.systemUptime
        refreshReaderIfAXSnapshotUnexpectedlyEmpty(snapshot)
        recordCaptureFingerprints(snapshot)
        if visionMessageBaseline.shouldSkipOCR(frameUnchanged: snapshot.messagesUnchanged) {
            status = "Monitoring · no visible message changes"
            let result = ConversationMergeResult(appended: [], prepended: [], unchanged: true, viewport: viewportState)
            return .merged(result)
        }
        guard !snapshot.messages.isEmpty else {
            latestSnapshotBlockCount = 0
            status = "Conversation identified, but visible messages could not be read · retrying"
            return .merged(ConversationMergeResult(appended: [], prepended: [], unchanged: true, viewport: .uncertain))
        }
        return .merged(mergeSnapshot(snapshot, purpose: purpose))
    }

    @discardableResult
    private func mergeSnapshot(_ snapshot: WeChatSnapshot, purpose: SnapshotPurpose) -> ConversationMergeResult {
        let result = conversationStore.merge(snapshot.messages)
        if lockedVisionIdentity == nil { lockedVisionIdentity = snapshot.visionIdentity }
        recordCaptureFingerprints(snapshot)
        messages = conversationStore.messages
        viewportState = result.viewport
        latestTailOverlap = result.viewport == .liveTail ? result.appended.count : 0
        latestHistoricalOverlap = result.viewport == .historical ? result.prepended.count : 0
        latestSnapshotBlockCount = snapshot.messageRowCount
        lastObservedSnapshot = snapshot.messages.map(ChatHistoryMerger.key(for:))
        messageCaptureCount += 1
        acquisitionState = ConversationAcquisitionState.resolve(identityConfirmed: true,
                                                                  hasMessages: !messages.isEmpty)
        hasUnverifiedMessageChanges = result.viewport == .uncertain
        if purpose == .historical || result.viewport == .historical {
            status = "Historical context merged · \(messages.count) messages stored"
        } else if result.viewport == .uncertain {
            status = "Snapshot did not overlap stored context · keeping existing messages"
        } else if result.appended.isEmpty {
            status = "Monitoring · \(messages.count) messages in context"
        } else {
            status = "New message observed · \(messages.count) messages in context"
        }
        return result
    }

    private func retainPendingIdentityObservation(_ observation: PendingConversationObservation) {
        let headerChanged = pendingHeaderFingerprint != nil && observation.headerFingerprint != nil &&
            pendingHeaderFingerprint != observation.headerFingerprint
        let titleChanged: Bool
        if let previous = pendingVisionIdentity, let current = observation.visionIdentity {
            titleChanged = !previous.isSpatiallyConsistent(with: current)
        } else {
            titleChanged = false
        }
        if headerChanged || titleChanged {
            pendingIdentityStore.clear()
            pendingVisionIdentity = nil
        }
        if let identity = observation.visionIdentity { pendingVisionIdentity = identity }
        if let fingerprint = observation.headerFingerprint { pendingHeaderFingerprint = fingerprint }
        _ = pendingIdentityStore.merge(observation.messages)
        messages = pendingIdentityStore.messages
        latestSnapshotBlockCount = observation.messageRowCount
        messageCaptureCount += 1
    }

    private func adoptPendingIdentityMessages(for snapshot: WeChatSnapshot) {
        let confirmedKey = WeChatParsing.conversationIdentityKey(snapshot.contact)
        let pendingMatches = pendingVisionIdentity?.normalizedTitle == confirmedKey
        let geometryMatches = snapshot.visionIdentity.map { identity in
            pendingVisionIdentity?.isSpatiallyConsistent(with: identity) ?? false
        } ?? true
        if pendingMatches && geometryMatches {
            _ = conversationStore.merge(pendingIdentityStore.messages)
        } else {
            conversationStore.clear()
        }
        pendingIdentityStore.clear()
        pendingVisionIdentity = nil
        pendingHeaderFingerprint = nil
        messages = conversationStore.messages
    }

    private enum ContactCheck: Equatable { case confirmed, candidate, changed }

    private func confirmSnapshotContact(_ contact: String) -> ContactCheck {
        guard let lockedContact else {
            self.lockedContact = contact
            contactName = contact
            conversationIdentityState = .confirmed
            acquisitionState = ConversationAcquisitionState.resolve(
                identityConfirmed: true, hasMessages: !conversationStore.messages.isEmpty
            )
            candidateContact = nil
            candidateContactPolls = 0
            hasUnverifiedMessageChanges = false
            lastTitleValidationUptime = ProcessInfo.processInfo.systemUptime
            return .confirmed
        }
        let detectedKey = WeChatParsing.conversationIdentityKey(contact)
        let lockedKey = WeChatParsing.conversationIdentityKey(lockedContact)
        if detectedKey == lockedKey {
            conversationIdentityState = .confirmed
            acquisitionState = ConversationAcquisitionState.resolve(
                identityConfirmed: true, hasMessages: !conversationStore.messages.isEmpty
            )
            candidateContact = nil
            candidateContactPolls = 0
            hasUnverifiedMessageChanges = false
            return .confirmed
        }
        if candidateContact.map(WeChatParsing.conversationIdentityKey) == detectedKey {
            candidateContactPolls += 1
        } else {
            candidateContact = contact
            candidateContactPolls = 1
        }
        conversationIdentityState = .candidateChange
        if candidateContactPolls >= 2 {
            conversationIdentityState = .changed
            stop()
            status = "Conversation changed. Activate again in the chat you want to monitor."
            return .changed
        } else {
            status = "Checking a possible conversation change…"
            return .candidate
        }
    }

    private func applySnapshot(_ snapshot: WeChatSnapshot, purpose: SnapshotPurpose,
                               allowAutomaticAnalysis: Bool) {
        guard confirmSnapshotContact(snapshot.contact) == .confirmed else { return }
        recordCaptureFingerprints(snapshot)
        guard !snapshot.messages.isEmpty else {
            status = "Conversation identified, but visible messages could not be read · retrying"
            return
        }
        let result = mergeSnapshot(snapshot, purpose: purpose)
        if allowAutomaticAnalysis, result.viewport == .liveTail, !result.appended.isEmpty {
            processIncoming(result.appended, contact: snapshot.contact)
        }
    }

    private func processIncoming(_ appended: [ChatMessage], contact: String) {
        let incoming = appended.filter { $0.senderIdentified && !$0.isFromMe }
        guard !incoming.isEmpty else { return }
        lastProcessedIncomingMessage = incoming.last?.localID
        let canAutoAnalyze = WeChatParsing.canAutomaticallyAnalyze(messages.suffix(analysisContextLimit))
        scheduleBurst(contact: contact, canAutoAnalyze: canAutoAnalyze)
    }

    private func scheduleBurst(contact: String, canAutoAnalyze: Bool) {
        generation += 1
        let token = generation
        burstDebounce?.cancel()
        guard viewportState == .liveTail, conversationIdentityState == .confirmed else { return }
        status = "Waiting for the message burst to finish…"
        burstDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self, self.isRunning, self.generation == token else { return }
            guard self.viewportState == .liveTail, self.conversationIdentityState == .confirmed else { return }
            self.status = "Message ready · Analyze"
            if canAutoAnalyze {
                self.onBurst?(contact, Array(self.messages.suffix(self.analysisContextLimit)), true)
            }
        }
    }

    private func poll() {
        guard isRunning, !isCheckingConversation, !isPolling, !isLoadingOlderContext, !isSyncing else { return }
        let contact = lockedContact
        isPolling = true
        let token = generation
        let cancellation = sessionCancellation
        let bridge = self.bridge
        let previousHeaderFingerprint = lastHeaderFingerprint
        let previousMessageFingerprint = visionMessageBaseline.fingerprint
        let preferredMessagePaneLeftX = activeMessagePaneLeftX
        accessibilityQueue.async { [weak self] in
            let capture = bridge.captureConversationSnapshot(
                previousHeaderFingerprint: previousHeaderFingerprint,
                previousMessageFingerprint: previousMessageFingerprint,
                lockedContact: contact,
                messagePaneLeftX: preferredMessagePaneLeftX
            )
            guard cancellation?.isCancelled != true else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPolling = false
                guard self.isRunning, self.generation == token else { return }
                if case .identityPending(let observation) = capture {
                    self.retainPendingIdentityObservation(observation)
                    self.conversationIdentityState = .temporarilyUncertain
                    self.acquisitionState = .messagesPending
                    self.status = "Messages captured locally · confirming conversation before analysis"
                    return
                }
                guard case .success(let snapshot) = capture else {
                    self.noteCaptureFailure()
                    // A temporary failure in the selected source does not
                    // change stored context or the successful merge baseline.
                    if case .failure(let failure) = capture {
                        self.status = failure.userMessage
                    }
                    self.conversationIdentityState = .temporarilyUncertain
                    self.acquisitionState = .temporarilyUnavailable
                    self.hasUnverifiedMessageChanges = true
                    return
                }
                self.consecutiveCaptureFailures = 0
                if self.lockedContact == nil {
                    self.adoptPendingIdentityMessages(for: snapshot)
                }
                guard self.confirmSnapshotContact(snapshot.contact) == .confirmed else { return }
                if contact == nil { self.startAXObserver() }
                self.lastTitleValidationUptime = ProcessInfo.processInfo.systemUptime
                self.refreshReaderIfAXSnapshotUnexpectedlyEmpty(snapshot)
                self.recordCaptureFingerprints(snapshot)
                if self.visionMessageBaseline.shouldSkipOCR(frameUnchanged: snapshot.messagesUnchanged) {
                    self.status = "Monitoring · no visible message changes"
                    return
                }
                guard !snapshot.messages.isEmpty else {
                    self.latestSnapshotBlockCount = 0
                    self.status = "Conversation identified, but visible messages could not be read · retrying"
                    return
                }
                let result = self.mergeSnapshot(snapshot, purpose: .live)
                if result.viewport == .liveTail && !result.appended.isEmpty {
                    if let contact = self.lockedContact {
                        self.processIncoming(result.appended, contact: contact)
                    }
                }
            }
        }
    }

    private func startWatchdog() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: watchdogInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func refreshReaderIfAXSnapshotUnexpectedlyEmpty(_ snapshot: WeChatSnapshot) {
        if snapshot.messageSource == .accessibility,
           snapshot.messages.isEmpty,
           !conversationStore.messages.isEmpty {
            consecutiveEmptyAXSnapshots += 1
            if consecutiveEmptyAXSnapshots >= 3 {
                bridge.resetReaderBackend()
                consecutiveEmptyAXSnapshots = 0
                lastOlderContextDiagnostic = "AX capability cache refreshed after repeated empty message snapshots"
            }
        } else {
            consecutiveEmptyAXSnapshots = 0
        }
    }

    private func recordCaptureFingerprints(_ snapshot: WeChatSnapshot) {
        if let fingerprint = snapshot.headerFingerprint { lastHeaderFingerprint = fingerprint }
        if snapshot.messagePaneLeftX != nil { activeMessagePaneLeftX = snapshot.messagePaneLeftX }
        guard snapshot.messageSource == .vision else {
            visionMessageBaseline.reset()
            activeMessagePaneLeftX = nil
            return
        }
        visionMessageBaseline.record(source: snapshot.messageSource,
                                     hasMessages: !snapshot.messages.isEmpty,
                                     fingerprint: snapshot.messageFingerprint,
                                     frameUnchanged: snapshot.messagesUnchanged)
    }

    private func noteCaptureFailure() {
        consecutiveCaptureFailures += 1
        guard consecutiveCaptureFailures >= 3 else { return }
        bridge.resetReaderBackend()
        consecutiveCaptureFailures = 0
        lastOlderContextDiagnostic = "AX capability cache refreshed after repeated capture failures"
    }

    private func startAXObserver() {
        guard let targets = bridge.accessibilityObservationTargets() else {
            lastOlderContextDiagnostic = "AXObserver: message-list target unavailable; watchdog polling remains enabled"
            return
        }
        let started = accessibilityObserver.start(pid: targets.pid, targets: targets.elements) { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleObserverCapture() }
        }
        lastOlderContextDiagnostic = started
            ? "AXObserver: active on WeChat window and message list"
            : "AXObserver: notifications unavailable; watchdog polling remains enabled"
    }

    private func scheduleObserverCapture() {
        guard isRunning else { return }
        observerDebounce?.cancel()
        observerDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.observerDebounceNanoseconds ?? 400_000_000)
            guard !Task.isCancelled, let self, self.isRunning else { return }
            self.poll()
        }
    }

    private func stopTimersAndObserver() {
        timer?.invalidate(); timer = nil
        accessibilityObserver.stop()
    }

    private func scrollToLatest(contact: String, cancellation: MonitorWorkCancellation?, generation token: Int) async -> (reached: Bool, appended: [ChatMessage]) {
        isReturningToLatest = true
        var appended: [ChatMessage] = []
        let bridge = self.bridge
        let identity = lockedVisionIdentity
        let messagePaneLeftX = activeMessagePaneLeftX
        for _ in 0..<maxScrollAttempts {
            guard isRunning, generation == token, cancellation?.isCancelled != true else { return (false, appended) }
            let scroll = await performAccessibilityOperation {
                bridge.scrollMessagePaneDownwardIfConversationMatches(
                    contact: contact, identity: identity,
                    fraction: 0.5, messagePaneLeftX: messagePaneLeftX,
                    cancellation: cancellation
                )
            }
            guard isRunning, generation == token else { return (false, appended) }
            switch scroll {
            case .conversationChanged:
                stop()
                status = "Conversation changed. Activate again in the chat you want to monitor."
                return (false, appended)
            case .identityUncertain, .windowUnavailable, .scrollUnavailable, .cancelled:
                return (false, appended)
            case .scrolled: break
            }
            try? await Task.sleep(nanoseconds: rowMaterializationDelay)
            guard isRunning, generation == token else { return (false, appended) }
            let outcome = await captureAndMerge(contact: contact, purpose: .historical,
                                                cancellation: cancellation, generation: token)
            guard isRunning, generation == token else { return (false, appended) }
            if case .conversationChanged = outcome { return (false, appended) }
            if case .merged(let merge) = outcome {
                if merge.viewport == .liveTail {
                    appended.append(contentsOf: merge.appended)
                    viewportState = .liveTail
                    return (true, appended)
                }
            }
        }
        return (false, appended)
    }

    private func performAccessibilityOperation<T: Sendable>(
        _ operation: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            accessibilityQueue.async { continuation.resume(returning: operation()) }
        }
    }
}
