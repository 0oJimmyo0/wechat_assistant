import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var profileStore: RelationshipProfileStore
    @ObservedObject private var auth = ChatGPTAuthManager.shared
    @ObservedObject private var monitor = MessageMonitor.shared
    @AppStorage("auto_analyze_enabled") private var autoAnalyze = false
    @AppStorage("conversation_storage_enabled") private var storeConversationContext = true
    @AppStorage("vision_conversation_left_x") private var conversationLeftX = 0.28
    @AppStorage("vision_header_bottom_y") private var headerBottomY = 0.90
    @AppStorage("vision_composer_top_y") private var composerTopY = 0.18
    @State private var isInspectingWeChat = false
    @State private var diagnosticStatus: String?
    @State private var privacyStatus: String?
    @State private var confirmClearCurrent = false
    @State private var confirmClearAll = false

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
                VStack(alignment: .leading, spacing: 10) {
                    Text("Vision layout calibration").font(.subheadline)
                    calibrationSlider("Conversation pane starts", value: $conversationLeftX, range: 0.15...0.60)
                    calibrationSlider("Header bottom", value: $headerBottomY, range: 0.65...0.96)
                    calibrationSlider("Composer top", value: $composerTopY, range: 0.05...min(0.35, headerBottomY - 0.04))
                    Text("Ratios use normalized image coordinates from the bottom left. Adjust, then save an annotated preview to inspect the regions. Calibration stays on this Mac; screenshots are saved only when you choose a destination.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Button(isInspectingWeChat ? "Inspecting WeChat AX…" : "Inspect WeChat AX") {
                    saveWeChatAccessibilityDiagnostic()
                }
                .disabled(isInspectingWeChat)
                Button(isInspectingWeChat ? "Inspecting Vision Capture…" : "Inspect Vision Capture") {
                    saveVisionCaptureDiagnostic()
                }
                .disabled(isInspectingWeChat)
                Button("Re-detect WeChat reader backend") {
                    MessageMonitor.shared.stop()
                    WeChatBridge.shared.resetReaderBackend()
                    diagnosticStatus = "Reader backend will be checked again on the next activation."
                }
                Button("Save Annotated Vision Preview…") {
                    saveAnnotatedVisionPreview()
                }
                .disabled(isInspectingWeChat)
                Text(diagnosticStatus ?? "Accessibility and Vision reports contain structure, counts, and geometry only; recognized text, names, and credentials are excluded.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Vision reports contain counts and geometry only. An explicitly saved preview contains the visible WeChat window, so store it privately and delete it when debugging is complete.")
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
                Toggle("Store conversation context locally", isOn: $storeConversationContext)
                Text("When enabled, recognized message text is encrypted with AES-GCM and saved in Application Support. Its encryption key is stored in this Mac's Keychain. The archive retains up to 500 messages per conversation for 30 days. No screenshots are stored. A local identity hash is used to locate a conversation record; the record and display name are encrypted. Turning storage off stops future loads and writes but leaves existing encrypted records until you clear them.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Clear current conversation history…") { confirmClearCurrent = true }
                    .disabled(monitor.contactName == nil)
                Button("Clear all stored conversation history…") { confirmClearAll = true }
                if let privacyStatus { Text(privacyStatus).font(.caption).foregroundStyle(.secondary) }
                Text("The active working context is limited to 100 messages and the sidebar shows up to 20. ChatGPT does not access this archive directly. When you choose Analyze, the app explicitly sends at most the latest 30 messages, your local relationship profile, and any special instruction; the contact name and other conversations are excluded. Automatic analysis, if enabled, is also limited to identified incoming Accessibility messages. Deactivation cannot recall a request OpenAI has already received. Your relationship profile remains in local app preferences without separate app-level encryption. store=false is not a zero-retention guarantee. Copying a reply leaves it on the system clipboard.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Link("OpenAI data controls", destination: URL(string: "https://developers.openai.com/api/docs/guides/your-data")!)
                    .font(.caption)
            }
            }
            .formStyle(.grouped)
            .padding(8)
        }
        .confirmationDialog("Clear the stored history for the currently monitored conversation?", isPresented: $confirmClearCurrent, titleVisibility: .visible) {
            Button("Clear current history", role: .destructive) {
                do {
                    try monitor.clearCurrentStoredHistory()
                    privacyStatus = "Current conversation history cleared. Monitoring paused."
                } catch {
                    privacyStatus = "Could not clear the current conversation history."
                }
            }
        }
        .confirmationDialog("Clear all locally stored conversation history?", isPresented: $confirmClearAll, titleVisibility: .visible) {
            Button("Clear all history", role: .destructive) {
                do {
                    try monitor.clearAllStoredHistory()
                    privacyStatus = "All stored conversation history cleared. Monitoring paused."
                } catch {
                    privacyStatus = "Could not clear stored conversation history."
                }
            }
        }
    }

    private func calibrationSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                Spacer()
                Text("\(Int(value.wrappedValue * 100))%")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: 0.01)
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

    private func saveVisionCaptureDiagnostic() {
        isInspectingWeChat = true
        diagnosticStatus = nil
        let monitorState = MessageMonitor.shared.visionIdentityDiagnostic
        Task {
            var report = await Task.detached(priority: .utility) {
                WeChatBridge.shared.visionDiagnosticReport()
            }.value
            report += "\nMonitor identity state (names omitted):\n\(monitorState)\n"
            isInspectingWeChat = false

            let panel = NSSavePanel()
            panel.nameFieldStringValue = "wechat-vision-diagnostic.txt"
            panel.allowedContentTypes = [.plainText]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try report.write(to: url, atomically: true, encoding: .utf8)
                diagnosticStatus = "Vision report saved. It contains no recognized message or contact text."
            } catch {
                diagnosticStatus = "Could not save the Vision diagnostic report."
            }
        }
    }

    private func saveAnnotatedVisionPreview() {
        isInspectingWeChat = true
        diagnosticStatus = nil
        Task {
            let preview = await Task.detached(priority: .utility) {
                WeChatBridge.shared.annotatedVisionPreview()
            }.value
            isInspectingWeChat = false
            guard let preview,
                  let tiff = preview.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                diagnosticStatus = "Could not capture an annotated WeChat preview. Check Screen Recording permission and keep WeChat open."
                return
            }

            let panel = NSSavePanel()
            panel.nameFieldStringValue = "wechat-vision-preview.png"
            panel.allowedContentTypes = [.png]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try png.write(to: url, options: .atomic)
                diagnosticStatus = "Annotated preview saved to your chosen location. It contains visible WeChat content."
            } catch {
                diagnosticStatus = "Could not save the annotated Vision preview."
            }
        }
    }
}
