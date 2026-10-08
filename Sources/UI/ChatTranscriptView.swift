import SwiftUI

/// Independently scrolling, session-only transcript. Scrolling here NEVER scrolls
/// the WeChat window; the monitor keeps tracking the live conversation in parallel.
struct ChatTranscriptView: View {
    let messages: [ChatMessage]
    let contactName: String
    let canLoadEarlier: Bool
    let loadingEarlier: Bool
    let onLoadEarlier: () -> Void

    @State private var viewingLatest = true
    @State private var unseenMessages = 0
    @State private var restoreAfterPrepend: UUID?
    private let bottomID = "local-chat-timeline-bottom"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CHAT TIMELINE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(messages.count) in memory")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
                VStack(spacing: 6) {
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 12) {
                            if canLoadEarlier {
                                Button {
                                    // Preserve the previous oldest message when
                                    // verified older context is prepended.
                                    restoreAfterPrepend = messages.first?.localID
                                    onLoadEarlier()
                                } label: {
                                    Label(loadingEarlier ? "Loading earlier…" : "Load 20 earlier",
                                          systemImage: "arrow.up.circle")
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                                .disabled(loadingEarlier)
                            } else if loadingEarlier {
                                ProgressView("Loading earlier messages…")
                                    .controlSize(.small).font(.caption)
                            }
                            if messages.isEmpty {
                                Text("No verified messages are available yet.")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .padding(.vertical, 32)
                            }
                            ForEach(messages, id: \.localID) { message in
                                VStack(spacing: 7) {
                                    if let label = message.timeSeparatorBefore {
                                        Text(label)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .padding(.vertical, 3)
                                            .frame(maxWidth: .infinity)
                                    }
                                    bubble(message)
                                }
                                .id(message.localID)
                            }
                            Color.clear.frame(height: 2).id(bottomID)
                                .onAppear {
                                    viewingLatest = true
                                    unseenMessages = 0
                                }
                                .onDisappear { viewingLatest = false }
                        }
                        .padding(12)
                    }
                    .frame(height: 325)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.35),
                                in: RoundedRectangle(cornerRadius: 12))
                    .onAppear {
                        // Open each conversation at its latest locally stored row.
                        if !messages.isEmpty {
                            DispatchQueue.main.async {
                                proxy.scrollTo(bottomID, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: messages.map(\.localID)) { previous, current in
                        guard previous != current else { return }
                        if let anchor = restoreAfterPrepend, current.first != previous.first,
                           current.contains(anchor) {
                            restoreAfterPrepend = nil
                            // Wait for SwiftUI to lay out newly prepended rows.
                            DispatchQueue.main.async {
                                proxy.scrollTo(anchor, anchor: .top)
                            }
                            return
                        }
                        let appended: Int
                        if let last = previous.last, let index = current.firstIndex(of: last) {
                            appended = current.count - index - 1
                        } else {
                            appended = 0  // no reliable tail anchor; do not call it new
                        }
                        if viewingLatest {
                            unseenMessages = 0
                            DispatchQueue.main.async {
                                proxy.scrollTo(bottomID, anchor: .bottom)
                            }
                        } else if appended > 0 {
                            unseenMessages += appended
                        }
                    }
                    HStack {
                        Text("Oldest → newest · time labels only when observed in WeChat")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .lineLimit(2)
                        Spacer(minLength: 6)
                        Button {
                            viewingLatest = true
                            unseenMessages = 0
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(bottomID, anchor: .bottom)
                            }
                        } label: {
                            Label(unseenMessages > 0 ? "\(unseenMessages) new · Latest" : "Jump to latest",
                                  systemImage: "arrow.down.to.line")
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func bubble(_ message: ChatMessage) -> some View {
        let mine = message.sender == .me
        let senderLabel = mine ? "Self" : (message.sender == .other ? contactName : "Sender unclear")
        return HStack(spacing: 0) {
            if mine { Spacer(minLength: 42) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                Text(senderLabel).font(.caption2).foregroundStyle(.secondary)
                Text(message.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(mine ? Color.accentColor.opacity(0.14) :
                                Color(nsColor: .windowBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 10))
            }
            .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
            if !mine { Spacer(minLength: 42) }
        }
    }
}
