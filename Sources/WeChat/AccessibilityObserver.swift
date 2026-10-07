import ApplicationServices
import CoreFoundation

/// Best-effort AX change notifications. The monitor keeps a polling watchdog
/// because WeChat may omit or reject these notifications on some releases.
final class AccessibilityObserver {
    private var observer: AXObserver?
    private var source: CFRunLoopSource?
    private var targets: [AXUIElement] = []
    private var changeHandler: (() -> Void)?

    func start(pid: pid_t, targets: [AXUIElement], onChange: @escaping () -> Void) -> Bool {
        stop()
        var created: AXObserver?
        let result = AXObserverCreate(pid, Self.callback, &created)
        guard result == .success, let created else { return false }
        observer = created
        self.targets = targets
        changeHandler = onChange
        let context = Unmanaged.passUnretained(self).toOpaque()
        let notificationNames = ["AXCreated", "AXValueChanged", "AXLayoutChanged", "AXRowCountChanged"]
        var registered = false
        for target in targets {
            for name in notificationNames {
                if AXObserverAddNotification(created, target, name as CFString, context) == .success {
                    registered = true
                }
            }
        }
        let runLoopSource = AXObserverGetRunLoopSource(created)
        source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        return registered
    }

    func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        if let observer {
            let context = Unmanaged.passUnretained(self).toOpaque()
            for target in targets {
                for name in ["AXCreated", "AXValueChanged", "AXLayoutChanged", "AXRowCountChanged"] {
                    AXObserverRemoveNotification(observer, target, name as CFString)
                }
            }
            _ = context
        }
        source = nil
        observer = nil
        targets.removeAll()
        changeHandler = nil
    }

    private func notificationReceived() {
        changeHandler?()
    }

    private static let callback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        Unmanaged<AccessibilityObserver>.fromOpaque(refcon).takeUnretainedValue().notificationReceived()
    }

    deinit { stop() }
}
