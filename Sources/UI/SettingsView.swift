import SwiftUI

struct SettingsView: View {
    @ObservedObject var profileStore: RelationshipProfileStore
    @ObservedObject private var auth = ChatGPTAuthManager.shared

    var body: some View {
        Form {
            Section("ChatGPT") {
                LabeledContent("Account", value: auth.accountLabel)
                if auth.isSignedIn {
                    Picker("Model", selection: $auth.selectedModel) {
                        ForEach(auth.modelCatalog) { model in Text(model.displayName).tag(model.slug) }
                    }
                }
                Button(auth.isSignedIn ? "Reconnect ChatGPT" : "Continue with ChatGPT") { Task { await auth.signIn() } }
                Text(auth.authStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
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
                Text("While monitoring, each incoming burst automatically sends up to 20 recent messages, the contact name, your local relationship profile, and any special instruction to OpenAI for suggestions. Chat text is not saved by this app. Your profile is saved in local app preferences without separate app-level encryption. store=false prevents Responses application-state storage, but is not a zero-retention guarantee; OpenAI may retain abuse-monitoring logs. Copying a reply leaves it on the system clipboard.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Link("OpenAI data controls", destination: URL(string: "https://developers.openai.com/api/docs/guides/your-data")!)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .padding(8)
        .onChange(of: auth.selectedModel) { _, model in UserDefaults.standard.set(model, forKey: "selected_chatgpt_model") }
    }
}
