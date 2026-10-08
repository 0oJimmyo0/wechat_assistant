import SwiftUI

struct AnalysisPreviewRequest: Identifiable {
    let id = UUID()
    let sessionID: UUID
    let messages: [ChatMessage]
    let model: String
    let instruction: String
    let profile: RelationshipProfile
}

struct AnalysisContextPreview: View {
    let request: AnalysisPreviewRequest
    let onAnalyze: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Analysis context · \(request.messages.count) messages").font(.headline)
            Text("Model: \(request.model)").font(.caption).foregroundStyle(.secondary)
            Text("The message block below is exactly the context sent to the model, in chronological order. Observed WeChat separators are labels; individual send times remain unknown.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text((try? AnalysisContext.modelText(request.messages)) ?? "Context unavailable")
                        .font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                    Text("Also included").font(.subheadline)
                    Text("Relationship: \(request.profile.relationship)\nCommunication notes: \(request.profile.communicationNotes)\nTone: \(request.profile.tone)\nSpecial instruction: \(request.instruction.isEmpty ? "None" : request.instruction)")
                        .font(.caption).textSelection(.enabled)
                }.padding(10)
            }
            Text("Contact names, capture times, other conversations, and unverified observations are excluded.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Send context and analyze", action: onAnalyze).buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(minWidth: 430, idealWidth: 480, minHeight: 420, idealHeight: 560)
    }
}
