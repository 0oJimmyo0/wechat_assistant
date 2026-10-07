import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var profileStore: RelationshipProfileStore
    @ObservedObject private var auth = ChatGPTAuthManager.shared
    @AppStorage("auto_analyze_enabled") private var autoAnalyze = false
    @State private var isInspectingWeChat = false
    @State private var diagnosticStatus: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            Form {
            Section("ChatGPT") {
                LabeledContent("Account", value: auth.accountLabel)
                if auth.isSignedIn {
                    Picker("Everyday", selection: $auth.everydayModel) {
                        ForEach(auth.modelCatalog) { model in Text(model.displayName).tag(model.slug) }
                    }
                    Picker("Careful", selection: $auth.carefulModel) {
                        Text("Choose when needed").tag("")
                        ForEach(auth.modelCatalog) { model in Text(model.displayName).tag(model.slug) }
                    }
                    Button("Sign out and disconnect") {
                        MessageMonitor.shared.stop()
                        Task { await auth.signOut() }
                    }
                }
                Button(auth.isSignedIn ? "Reconnect ChatGPT" : "Continue with ChatGPT") { Task { await auth.signIn() } }
                Text(auth.authStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Section("Monitoring") {
                Toggle("Automatically analyze identified messages", isOn: $autoAnalyze)
                Text("Off by default. When enabled, only clearly identified incoming Accessibility messages in the conversation active at activation can trigger inference. OCR uses bubble alignment for cautious Self/Target labels, leaves ambiguous rows unclear, and always stays manual-only.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Developer diagnostics") {
                Button(isInspectingWeChat ? "Inspecting WeChat AX…" : "Inspect WeChat AX") {
                    saveWeChatAccessibilityDiagnostic()
                }
                .disabled(isInspectingWeChat)
                Text(diagnosticStatus ?? "Saves structural Accessibility metadata only. Message text, contact names, notes, and credentials are excluded.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Relationship profile") {
                TextField("Relationship", text: $profileStore.profile.relationship)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Communication notes").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $profileStore.profile.communicationNotes).frame(height: 68)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Preferred tone").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $profileStore.profile.tone).frame(height: 54)
                }
            }
            Section("Privacy") {
                Text("The conversation is locked to the chat active when you activate monitoring. The app accumulates up to 100 recognized message bubbles in memory for this session and clears them on deactivation or a confirmed chat change. If WeChat hides its Accessibility tree, the app can request Screen Recording to capture only the visible WeChat window for local OCR; screenshots and OCR text are not saved. OCR may label clear left/right bubble alignment as Target/Self; uncertain labels remain unclear, and OCR never triggers automatic analysis. By default, chat text stays local until you choose Analyze. A manual analysis sends up to 100 recent captured messages, your local relationship profile, and any special instruction to OpenAI; the contact name is not sent. Optional automatic analysis sends up to 50 recent captured messages when sender identity is supplied by Accessibility. Deactivation cannot recall a request OpenAI has already received. Chat text is not saved by this app. Your profile is saved in local app preferences without separate app-level encryption. store=false is not a zero-retention guarantee. Copying a reply leaves it on the system clipboard.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Link("OpenAI data controls", destination: URL(string: "https://developers.openai.com/api/docs/guides/your-data")!)
                    .font(.caption)
            }
            }
            .formStyle(.grouped)
            .padding(8)
        }
    }

    private func saveWeChatAccessibilityDiagnostic() {
        isInspectingWeChat = true
        diagnosticStatus = nil
        Task {
            let report = await Task.detached(priority: .utility) {
                WeChatBridge.shared.diagnosticReport()
            }.value
            isInspectingWeChat = false

            let panel = NSSavePanel()
            panel.nameFieldStringValue = "wechat-ax-diagnostic.txt"
            panel.allowedContentTypes = [.plainText]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try report.write(to: url, atomically: true, encoding: .utf8)
                diagnosticStatus = "Structural report saved. It contains no message or contact text."
            } catch {
                diagnosticStatus = "Could not save the diagnostic report."
            }
        }
    }
}
