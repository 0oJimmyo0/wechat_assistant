import SwiftUI

struct SettingsView: View {
    @ObservedObject var profileStore: RelationshipProfileStore
    @ObservedObject private var auth = ChatGPTAuthManager.shared
    @AppStorage("auto_analyze_enabled") private var autoAnalyze = false

    var body: some View {
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
                Text("Off by default. When enabled, only clearly identified incoming messages in the conversation active at activation can trigger inference. Unclear Accessibility rows stay manual-only.")
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
                Text("The conversation is locked to the chat active when you activate monitoring. Switching chats stops monitoring and clears the local session. By default, chat text stays local until you choose Analyze. An analysis sends up to 20 visible messages, your local relationship profile, and any special instruction to OpenAI; the contact name is not sent. Deactivation cannot recall a request OpenAI has already received. Chat text is not saved by this app. Your profile is saved in local app preferences without separate app-level encryption. store=false is not a zero-retention guarantee. Copying a reply leaves it on the system clipboard.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Link("OpenAI data controls", destination: URL(string: "https://developers.openai.com/api/docs/guides/your-data")!)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .padding(8)
    }
}
