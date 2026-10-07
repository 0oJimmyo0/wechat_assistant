import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private let monitor = MessageMonitor.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenuBar()
        showSidebar()
        if !WeChatBridge.shared.hasAccessibilityPermission {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { WeChatBridge.shared.requestAccessibilityPermission() }
        }
    }

    private func showSidebar() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "WeChat Reply Copilot"
        window.contentView = NSHostingView(rootView: ReplySidebarView())
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("WeChatReplyCopilotSidebar")
        window.level = .floating
        window.minSize = NSSize(width: 320, height: 620)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    private func buildMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "bubble.left.and.text.bubble.right.fill", accessibilityDescription: "WeChat Reply Copilot")
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Copilot", action: #selector(showCopilot), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func showCopilot() {
        if let window { window.makeKeyAndOrderFront(nil) } else { showSidebar() }
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func quit() { monitor.stop(); NSApp.terminate(nil) }
    func windowWillClose(_ notification: Notification) {
        monitor.stop()
        window = nil
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct MainApp {
    static func main() {
        let app = NSApplication.shared
        if CommandLine.arguments.contains("--ax-diagnostic") {
            print(WeChatBridge.shared.diagnosticReport())
            return
        }
        if CommandLine.arguments.contains("--capture-benchmark") {
            let bridge = WeChatBridge.shared
            print("Accessibility trusted: \(bridge.hasAccessibilityPermission)")
            guard bridge.hasAccessibilityPermission else { return }
            bridge.beginConversationSession()
            defer { bridge.endConversationSession() }
            for index in 0..<10 {
                let result = bridge.captureConversationSnapshot(initialActivation: index == 0)
                switch result {
                case .success(let snapshot):
                    print("Sample \(index + 1): messages=\(snapshot.messages.count), validated=\(snapshot.hasTrustworthyTranscript), source=\(snapshot.messageSource.rawValue)")
                case .identityPending: print("Sample \(index + 1): identity pending")
                case .failure(let failure): print("Sample \(index + 1): \(failure.userMessage)")
                }
            }
            print(bridge.capturePerformanceSummary)
            print(bridge.conversationCaptureDiagnostic)
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
