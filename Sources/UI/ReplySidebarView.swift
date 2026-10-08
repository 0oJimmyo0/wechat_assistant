import SwiftUI

struct ReplySidebarView: View {
    @ObservedObject private var monitor = MessageMonitor.shared
    @ObservedObject private var auth = ChatGPTAuthManager.shared
    @StateObject private var profileStore = RelationshipProfileStore()
    @State private var suggestion: ReplySuggestion?
    @State private var instruction = ""
    @State private var errorMessage: String?
    @State private var isGenerating = false
    @State private var showSettings = false
    @State private var generationTask: Task<Void, Never>?
    @State private var generationID: UUID?
    @AppStorage("auto_analyze_enabled") private var autoAnalyze = false
    @State private var usageLimitReached = false
    @State private var displayedMessageLimit = 5
    private let manualAnalysisContextLimit = 20

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    currentConversationCard
                    recentMessagesSection

                    if let suggestion {
                        sectionLabel("SITUATION")
                        Text(suggestion.situation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let caution = suggestion.caution, !caution.isEmpty {
                            Label(caution, systemImage: "exclamationmark.circle.fill").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(Array(suggestion.replies.enumerated()), id: \.element.id) { index, candidate in
                            CandidateReplyCard(candidate: candidate, prominent: index == 0)
                        }
                    } else if isGenerating {
                        HStack(spacing: 10) { ProgressView(); Text("Preparing three reply ideas…").font(.callout).foregroundStyle(.secondary) }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
                    } else {
                        ContentUnavailableView("No suggestions yet", systemImage: "bubble.left.and.text.bubble.right", description: Text("Start monitoring or wait for a new incoming message."))
                    }
                    if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Special instruction").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        TextField("e.g. keep it light", text: $instruction, axis: .vertical).lineLimit(1...3).textFieldStyle(.roundedBorder)
                    }
                    Toggle("Automatically analyze identified messages", isOn: $autoAnalyze).font(.caption)
                    Text(autoAnalyze
                         ? "Clearly identified incoming messages may be sent to OpenAI after the conversation pauses."
                         : "Messages stay on this Mac until you choose Analyze.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Button { generate(context: Array(monitor.messages.suffix(manualAnalysisContextLimit)), model: auth.everydayModel) } label: {
                        Label(isGenerating ? "Analyzing…" : "Analyze latest message", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).disabled(isGenerating || monitor.isLoadingOlderContext || monitor.isSyncing || !monitor.canAnalyzeManually || usageLimitReached || !auth.isSignedIn || monitor.messages.isEmpty)
                    Button { generate(context: Array(monitor.messages.suffix(manualAnalysisContextLimit)), model: auth.carefulModel) } label: {
                        Label("Regenerate carefully", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered).disabled(isGenerating || monitor.isLoadingOlderContext || monitor.isSyncing || !monitor.canAnalyzeManually || usageLimitReached || !auth.isSignedIn || auth.carefulModel.isEmpty || monitor.messages.isEmpty)
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(minWidth: 320, idealWidth: 360, maxWidth: 390, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            monitor.onBurst = { _, context, canAutoAnalyze in
                guard autoAnalyze && canAutoAnalyze else { return }
                generate(context: context, model: auth.everydayModel)
            }
            monitor.onDeactivated = { clearSession() }
            if auth.isSignedIn, monitor.messages.isEmpty { monitor.pollNow() }
        }
        .onChange(of: monitor.contactName) { _, _ in
            generationTask?.cancel()
            generationTask = nil
            generationID = nil
            isGenerating = false
            suggestion = nil
            errorMessage = nil
        }
        .onDisappear {
            monitor.onBurst = nil
            monitor.onDeactivated = nil
            generationTask?.cancel()
            generationTask = nil
            generationID = nil
            isGenerating = false
            suggestion = nil
        }
        .sheet(isPresented: $showSettings) { SettingsView(profileStore: profileStore).frame(width: 390, height: 380) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill").font(.title3).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("WeChat Reply Copilot").font(.headline).lineLimit(1)
                Text(monitor.isRunning ? "Monitoring is on" : "Monitoring is off").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showSettings = true } label: { Image(systemName: "gearshape") }.buttonStyle(.plain).help("Settings")
        }.padding(14)
    }

    private var currentConversationCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                sectionLabel("CURRENT CHAT")
                Text(monitor.contactName ?? "No conversation selected")
                    .font(.headline)
                    .lineLimit(1)
                Text(monitor.status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private var recentMessagesSection: some View {
        let visibleMessages = Array(monitor.messages.suffix(displayedMessageLimit))
        return VStack(alignment: .leading, spacing: 8) {
            sectionLabel("RECENT MESSAGES · SHOWING \(visibleMessages.count) OF \(monitor.messages.count)")
            Text(monitor.messages.count < 20
                 ? "Context: \(monitor.messages.count) / 20 loaded · model receives up to 20"
                 : "Context: 20 / 20 loaded · \(monitor.messages.count) stored; model receives latest 20")
                .font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button {
                    monitor.refresh()
                } label: {
                    Label(monitor.isSyncing ? "Refreshing…" : "Refresh",
                          systemImage: monitor.isSyncing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!monitor.canSyncNow)

                if monitor.isRunning && monitor.viewportState != .liveTail {
                    Button {
                        monitor.followLatest()
                    } label: {
                        Label(monitor.isReturningToLatest ? "Returning…" : "Follow latest",
                              systemImage: "arrow.down.to.line")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(monitor.isLoadingOlderContext || monitor.isFollowingLatest || monitor.isSyncing)
                }
                Spacer(minLength: 0)
            }
            Text(monitor.captureDetails.summary).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(monitor.captureDuration).font(.caption2).foregroundStyle(.secondary)
            if monitor.captureDetails.candidateCount > monitor.captureDetails.acceptedCount {
                Text("Unverified observations are excluded from stored messages and analysis.")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if monitor.messages.count > 5 {
                Button(displayedMessageLimit == 5 ? "Show latest 20" : "Show latest 5") {
                    displayedMessageLimit = displayedMessageLimit == 5 ? 20 : 5
                }.buttonStyle(.plain).font(.caption)
            }
            if monitor.isRunning && monitor.messages.count < 20 && monitor.canLoadOlderContext &&
                monitor.conversationIdentityState == .confirmed && monitor.acquisitionState == .ready {
                Button {
                    monitor.loadOlderContext()
                } label: {
                    Label(monitor.isLoadingOlderContext ? "Loading…" : "Load older to 20",
                          systemImage: monitor.isLoadingOlderContext ? "hourglass" : "arrow.up.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(monitor.isLoadingOlderContext || monitor.isSyncing)
            }
            if monitor.isLoadingOlderContext {
                Text(monitor.isReturningToLatest
                     ? "Returning to latest messages…"
                     : "Loading older context… \(monitor.olderContextProgress ?? "0 / 20")")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if let olderContextStatus = monitor.olderContextStatus {
                Text(olderContextStatus)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if monitor.messages.isEmpty {
                Text("No chat message text is available from this WeChat view yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            } else {
                ForEach(visibleMessages) { message in
                    recentMessageRow(message)
                }
            }
        }
    }

    private func recentMessageRow(_ message: ChatMessage) -> some View {
        let isMe = message.senderIdentified && message.isFromMe
        let sender = isMe ? "Self" : (message.senderIdentified ? "Target · \(monitor.contactName ?? "Contact")" : "Sender unclear")
        return HStack {
            if isMe { Spacer(minLength: 36) }
            VStack(alignment: isMe ? .trailing : .leading, spacing: 3) {
                Text(sender)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(message.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)
                    .background(isMe ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            }
            if !isMe { Spacer(minLength: 36) }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: auth.isSignedIn ? "checkmark.circle.fill" : "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(auth.isSignedIn ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(auth.accountLabel).font(.caption.weight(.medium)).lineLimit(1)
                    Text(auth.isSignedIn ? auth.selectedModelDisplay : auth.authStatus).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if !auth.isSignedIn {
                    Button("Sign in") { Task { await auth.signIn() } }.buttonStyle(.bordered).controlSize(.small)
                } else {
                    Button { Task { try? await auth.refreshModels() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain)
                }
            }
            HStack {
                Label("Monitor", systemImage: monitor.isRunning ? "eye.fill" : "eye.slash")
                Spacer()
                Button(monitor.isRunning ? "Deactivate" : "Activate") {
                    if monitor.isRunning { monitor.stop() } else { usageLimitReached = false; monitor.start() }
                }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            Text(monitor.isRunning
                 ? (autoAnalyze ? "Identified incoming bursts may be sent to OpenAI automatically." : "Messages stay local until you choose Analyze.")
                 : (monitor.status == "Paused" ? "Paused. No new chat is monitored or sent." : monitor.status))
                .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(12)
    }

    private func sectionLabel(_ text: String) -> some View { Text(text).font(.system(size: 10, weight: .bold)).tracking(0.8).foregroundStyle(.tertiary) }

    private func clearSession() {
        generationTask?.cancel()
        generationTask = nil
        generationID = nil
        isGenerating = false
        suggestion = nil
        errorMessage = nil
        instruction = ""
    }

    private func generate(context: [ChatMessage], model: String) {
        guard auth.isSignedIn, !isGenerating, !monitor.isLoadingOlderContext, !monitor.isSyncing, monitor.canAnalyzeManually else { return }
        guard !model.isEmpty else { errorMessage = "Choose an available model in settings."; return }
        let requestID = UUID()
        generationID = requestID
        isGenerating = true; errorMessage = nil; suggestion = nil
        let profile = profileStore.profile
        let specialInstruction = instruction
        generationTask?.cancel()
        generationTask = Task { @MainActor in
            do {
                let result = try await SuggestionEngine.shared.generate(context: context, profile: profile, instruction: specialInstruction, model: model)
                guard !Task.isCancelled, generationID == requestID else { return }
                suggestion = result
            } catch {
                guard !Task.isCancelled, generationID == requestID else { return }
                if case CopilotError.usageLimitExceeded = error {
                    usageLimitReached = true
                    autoAnalyze = false
                    monitor.stop()
                    errorMessage = "ChatGPT plan usage limit reached. Check ChatGPT Settings → Usage. Monitoring stopped to prevent repeated requests."
                } else { errorMessage = error.localizedDescription }
            }
            guard generationID == requestID else { return }
            isGenerating = false
            generationTask = nil
        }
    }
}

private extension ChatGPTAuthManager {
    var selectedModelDisplay: String { modelCatalog.first(where: { $0.slug == everydayModel })?.displayName ?? everydayModel }
}
