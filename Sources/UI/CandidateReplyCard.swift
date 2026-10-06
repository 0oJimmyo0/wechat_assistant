import SwiftUI
import AppKit

struct CandidateReplyCard: View {
    let candidate: ReplyCandidate
    let prominent: Bool
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(candidate.style.rawValue).font(.caption.weight(.semibold)).foregroundStyle(prominent ? Color.accentColor : .secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(candidate.text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            Text(candidate.text).font(.system(size: 14)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(prominent ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(prominent ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12)))
    }
}
