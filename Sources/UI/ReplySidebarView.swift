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

    private var latestIncoming: String { monitor.messages.last(where: { !$0.isFromMe })?.text ?? "等待对方的新消息" }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sectionLabel("LATEST MESSAGE")
                    Text(latestIncoming).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))

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
                    Button { generate(context: monitor.messages, contact: monitor.contactName ?? "WeChat") } label: {
                        Label(isGenerating ? "Generating…" : "Regenerate", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).disabled(isGenerating || !auth.isSignedIn || monitor.messages.isEmpty)
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(minWidth: 320, idealWidth: 360, maxWidth: 390, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            monitor.onBurst = { contact, context in generate(context: context, contact: contact) }
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
            generationTask?.cancel()
            generationTask = nil
            generationID = nil
            isGenerating = false
        }
        .sheet(isPresented: $showSettings) { SettingsView(profileStore: profileStore).frame(width: 390, height: 380) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill").font(.title3).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(monitor.contactName ?? "WeChat Reply Copilot").font(.headline).lineLimit(1)
                Text(monitor.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { showSettings = true } label: { Image(systemName: "gearshape") }.buttonStyle(.plain).help("Settings")
        }.padding(14)
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
                Button(monitor.isRunning ? "Pause" : "Resume") { monitor.isRunning ? monitor.stop() : monitor.start() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }.padding(12)
    }

    private func sectionLabel(_ text: String) -> some View { Text(text).font(.system(size: 10, weight: .bold)).tracking(0.8).foregroundStyle(.tertiary) }

    private func generate(context: [ChatMessage], contact: String) {
        guard auth.isSignedIn, !isGenerating else { return }
        guard !auth.selectedModel.isEmpty else { errorMessage = "Choose an available model in settings."; return }
        let requestID = UUID()
        generationID = requestID
        isGenerating = true; errorMessage = nil; suggestion = nil
        let profile = profileStore.profile
        let specialInstruction = instruction
        let model = auth.selectedModel
        generationTask?.cancel()
        generationTask = Task { @MainActor in
            do {
                let result = try await SuggestionEngine.shared.generate(contact: contact, context: context, profile: profile, instruction: specialInstruction, model: model)
                guard !Task.isCancelled, generationID == requestID,
                      monitor.contactName == nil || monitor.contactName == contact else { return }
                suggestion = result
            } catch {
                guard !Task.isCancelled, generationID == requestID else { return }
                errorMessage = error.localizedDescription
            }
            guard generationID == requestID else { return }
            isGenerating = false
            generationTask = nil
        }
    }
}

private extension ChatGPTAuthManager {
    var selectedModelDisplay: String { modelCatalog.first(where: { $0.slug == selectedModel })?.displayName ?? selectedModel }
}
