import SwiftUI
import AppKit
@MainActor final class ProbeModel: ObservableObject {
    @Published var messages: [ChatMessage]
    @Published var incoming: [UUID] = []
    var viewport = TranscriptScrollState()
    init(_ messages: [ChatMessage]) { self.messages = messages }
}
struct ProbeView: View {
    @ObservedObject var model: ProbeModel
    var body: some View {
        ChatTranscriptView(messages: model.messages, contactName: "Public fixture", canLoadEarlier: true,
            loadingEarlier: false, onLoadEarlier: {}, newIncomingIDs: model.incoming,
            onViewportChange: { model.viewport = $0 }).padding(12)
    }
}
@main @MainActor enum TranscriptUIProbe {
    static func pump(_ seconds: TimeInterval = 0.8) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    static func findScroll(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews { if let scroll = findScroll(child) { return scroll } }
        return nil
    }
    static func check(_ condition: Bool, _ label: String) { guard condition else { fputs("FAILED UI probe: \(label)\n",stderr); exit(1) }; print("Passed UI probe: \(label)") }
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let all = (0..<220).map { ChatMessage(text: "Public fixture row \($0) 中文 English.\nSecond line.",sender: $0 % 2 == 0 ? .me : .other) }
        let model = ProbeModel(Array(all[80..<180]))
        let window = NSWindow(contentRect: NSRect(x: 250,y: 200,width: 420,height: 520),styleMask: [.titled,.resizable],backing: .buffered,defer: false)
        window.title = "Copilot synthetic transcript validation"
        let host = NSHostingView(rootView: ProbeView(model: model))
        window.contentView = host
        window.orderFront(nil)
        pump(1.2)
        guard let scroll = findScroll(host), let document = scroll.documentView else { check(false,"native transcript scroll view exists"); return }
        let initialHeight = scroll.contentView.bounds.height
        window.setContentSize(NSSize(width: 420,height: 650)); pump()
        check(scroll.contentView.bounds.height > initialHeight + 100,"transcript grows when resized")
        scroll.contentView.scroll(to: NSPoint(x: 0,y: document.frame.height * 0.5)); scroll.reflectScrolledClipView(scroll.contentView); pump()
        let beforeAppend = scroll.contentView.bounds.origin.y
        model.messages.append(contentsOf: all[180..<182]); model.incoming = all[180..<182].filter { $0.sender == .other }.map(\.localID); pump()
        check(abs(scroll.contentView.bounds.origin.y - beforeAppend) < 3,"incoming rows do not move history reader")
        check(model.viewport.unreadIDs.count == 1,"incoming badge counts a confirmed unread occurrence")
        let unchanged = model.messages
        for _ in 0..<3 { model.messages = unchanged; pump(0.1) }
        check(model.viewport.unreadIDs.count == 1,"three unchanged UI refreshes preserve unread count")
        let anchor = model.viewport.anchor
        let oldOffset = model.viewport.anchorOffset
        model.messages.insert(contentsOf: all[60..<80],at: 0); pump(1.2)
        let offsetError = abs(model.viewport.anchorOffset - oldOffset)
        print("Prepend scroll-offset error: \(Int(offsetError)) px")
        check(model.viewport.anchor == anchor && offsetError < 3,"prepend preserves visible row identity and offset")
        model.messages = Array(all[0..<200]); pump()
        let started = Date()
        for fraction in stride(from: 0.0,through: 1.0,by: 0.1) {
            scroll.contentView.scroll(to: NSPoint(x: 0,y: max(0,document.frame.height - scroll.contentView.bounds.height) * fraction))
            scroll.reflectScrolledClipView(scroll.contentView); pump(0.05)
        }
        print("200-row synthetic scroll sweep duration: \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        check(model.messages.count == 200,"200 retained rows render without crash")
        window.orderOut(nil)
    }
}
