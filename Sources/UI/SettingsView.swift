import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var profileStore: RelationshipProfileStore
    @ObservedObject private var auth = ChatGPTAuthManager.shared
    @AppStorage("auto_analyze_enabled") private var autoAnalyze = false
    @AppStorage("vision_conversation_left_x") private var conversationLeftX = 0.28
    @AppStorage("vision_header_bottom_y") private var headerBottomY = 0.82
    @AppStorage("vision_composer_top_y") private var composerTopY = 0.18
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
                Text("The conversation is locked to the chat active when you activate monitoring. The app accumulates up to 100 recognized message bubbles in memory for this session and clears them on deactivation or a confirmed chat change. If WeChat hides its Accessibility tree, the app uses Screen Recording permission to capture only the WeChat window for local OCR; it requests permission once, then checks preflight status without repeated prompts. Screenshots and OCR text are not saved automatically. The explicitly saved annotated debug preview contains visible chat content. OCR may label clear left/right bubble alignment as Target/Self; uncertain labels remain unclear, and OCR never triggers automatic analysis. By default, chat text stays local until you choose Analyze. A manual analysis sends up to 100 recent captured messages, your local relationship profile, and any special instruction to OpenAI; the contact name is not sent. Optional automatic analysis sends up to 50 recent captured messages when sender identity is supplied by Accessibility. Deactivation cannot recall a request OpenAI has already received. Chat text is not saved by this app. Your profile is saved in local app preferences without separate app-level encryption. store=false is not a zero-retention guarantee. Copying a reply leaves it on the system clipboard.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Link("OpenAI data controls", destination: URL(string: "https://developers.openai.com/api/docs/guides/your-data")!)
                    .font(.caption)
            }
            }
            .formStyle(.grouped)
            .padding(8)
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
