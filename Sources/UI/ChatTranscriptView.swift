import SwiftUI
import AppKit

/// A local scroll viewport, independent of WeChat capture and scrolling.
struct ChatTranscriptView: View {
    let messages: [ChatMessage]
    let contactName: String
    let canLoadEarlier: Bool
    let loadingEarlier: Bool
    let onLoadEarlier: () -> Void
    var newIncomingIDs: [UUID] = []
    var selectionEnabled = false
    var selectedIDs: Set<UUID> = []
    var onSelect: (UUID) -> Void = { _ in }
    var onViewportChange: (TranscriptScrollState) -> Void = { _ in }

    @State private var scrollState = TranscriptScrollState()
    @State private var nativeScrollView: NSScrollView?
    @State private var restoringAnchor: (id: UUID, offset: CGFloat)?
    @State private var previousIDs: [UUID] = []
    private let bottomID = "local-chat-timeline-bottom"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CHAT TIMELINE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(messages.count) / 200 retained").font(.caption2).foregroundStyle(.secondary)
            }
            GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 12) {
                            if canLoadEarlier || loadingEarlier {
                                Button(action: onLoadEarlier) {
                                    Label(loadingEarlier ? "Loading earlier…" : "Load 20 earlier", systemImage: "arrow.up.circle")
                                }.buttonStyle(.borderless).font(.caption).disabled(loadingEarlier)
                            }
                            if messages.isEmpty {
                                Text("No verified messages are available yet.").font(.caption).foregroundStyle(.secondary).padding(.vertical, 32)
                            }
                            ForEach(messages, id: \.localID) { message in
                                VStack(spacing: 7) {
                                    if let label = message.timeSeparatorBefore {
                                        Text(label).font(.caption2).foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity).padding(.vertical, 3)
                                    }
                                    HStack(spacing: 6) {
                                        if selectionEnabled {
                                            Button { onSelect(message.localID) } label: {
                                                Image(systemName: selectedIDs.contains(message.localID) ? "checkmark.circle.fill" : "circle")
                                            }.buttonStyle(.plain).accessibilityLabel("Select message for analysis")
                                        }
                                        bubble(message)
                                    }
                                }
                                .id(message.localID)
                                .background(GeometryReader { row in
                                    Color.clear.preference(key: TranscriptFrames.self,
                                        value: [message.localID: row.frame(in: .named("transcript-viewport"))])
                                })
                            }
                            Color.clear.frame(height: 2).id(bottomID)
                                .background(GeometryReader { row in
                                    Color.clear.preference(key: TranscriptBottom.self,
                                        value: row.frame(in: .named("transcript-viewport")).maxY)
                                })
                        }
                        .padding(12)
                        .background(TranscriptScrollResolver { nativeScrollView = $0 })
                    }
                    .coordinateSpace(name: "transcript-viewport")
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                    .onPreferenceChange(TranscriptFrames.self) { frames in
                        if let target = restoringAnchor {
                            guard let row = frames[target.id] else { return }
                            let delta = row.minY - target.offset
                            if abs(delta) > 1, let scroll = nativeScrollView {
                                DispatchQueue.main.async {
                                    var point = scroll.contentView.bounds.origin
                                    point.y += delta
                                    scroll.contentView.scroll(to: point)
                                    scroll.reflectScrolledClipView(scroll.contentView)
                                }
                                return
                            }
                            restoringAnchor = nil
                        }
                        scrollState.observe(frames: frames, viewportHeight: viewport.size.height,
                            latestVisible: scrollState.viewingLatest)
                        onViewportChange(scrollState)
                    }
                    .onPreferenceChange(TranscriptBottom.self) { bottom in
                        guard restoringAnchor == nil else { return }
                        scrollState.observe(frames: [:], viewportHeight: viewport.size.height,
                            latestVisible: bottom > 0 && bottom <= viewport.size.height + 3)
                        onViewportChange(scrollState)
                    }
                    .onAppear {
                        previousIDs = messages.map(\.localID)
                        DispatchQueue.main.async { proxy.scrollTo(bottomID, anchor: .bottom) }
                    }
                    .onChange(of: messages.map(\.localID)) { _, current in
                        let intent = scrollState.reconcile(previous: previousIDs, current: current, newIncoming: newIncomingIDs)
                        previousIDs = current
                        onViewportChange(scrollState)
                        switch intent {
                        case .none: break
                        case .latest:
                            DispatchQueue.main.async { proxy.scrollTo(bottomID, anchor: .bottom) }
                        case .anchor(let id, let offset):
                            restoringAnchor = (id, offset)
                            // Bring a lazily realized row into view; subsequent
                            // measured frames restore its exact previous offset.
                            DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) }
                        }
                    }
                    .onChange(of: newIncomingIDs) { previous, current in
                        _ = scrollState.reconcile(previous: previousIDs, current: messages.map(\.localID),
                            newIncoming: current)
                        onViewportChange(scrollState)
                    }
                    .onReceive(NotificationCenter.default.publisher(for: NSScrollView.willStartLiveScrollNotification)) { notification in
                        guard let scroll = notification.object as? NSScrollView, scroll === nativeScrollView else { return }
                        restoringAnchor = nil // A user's new scroll takes precedence over restoration.
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if !scrollState.viewingLatest || !scrollState.unreadIDs.isEmpty {
                            Button {
                                scrollState.jumpToLatest()
                                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomID, anchor: .bottom) }
                            } label: {
                                Label(scrollState.unreadIDs.isEmpty ? "Jump to latest" : "\(scrollState.unreadIDs.count) new · Latest",
                                    systemImage: "arrow.down.to.line")
                            }.buttonStyle(.borderedProminent).controlSize(.small).padding(10)
                        }
                    }
                }
            }
            Text(scrollState.viewingLatest ? "Latest local messages · WeChat monitoring is independent" : "Viewing local history · monitoring continues")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(minHeight: 160, maxHeight: .infinity)
    }

    private func bubble(_ message: ChatMessage) -> some View {
        let mine = message.sender == .me
        return HStack(spacing: 0) {
            if mine { Spacer(minLength: 30) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                Text(mine ? "Self" : (message.sender == .other ? contactName : "Sender unclear"))
                    .font(.caption2).foregroundStyle(.secondary)
                Text(message.text).font(.system(size: 13)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(mine ? Color.accentColor.opacity(0.14) : Color(nsColor: .windowBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 10))
            }.frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
            if !mine { Spacer(minLength: 30) }
        }
    }
}

private struct TranscriptFrames: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}
private struct TranscriptBottom: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct TranscriptScrollResolver: NSViewRepresentable {
    let resolved: (NSScrollView) -> Void
    func makeNSView(context: Context) -> ResolverView { let view = ResolverView(); view.resolved = resolved; return view }
    func updateNSView(_ view: ResolverView, context: Context) { view.resolved = resolved }
    final class ResolverView: NSView {
        var resolved: ((NSScrollView) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                if let scroll = self?.enclosingScrollView { self?.resolved?(scroll) }
            }
        }
    }
}
