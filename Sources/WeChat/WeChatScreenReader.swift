import AppKit
import CoreGraphics
import ScreenCaptureKit
import Vision

struct VisibleWeChatSnapshot: Sendable {
    let title: String?
    let messages: [ChatMessage]
    let captureState: VisionCaptureState
    let captureSucceeded: Bool
    let capturedSize: CGSize?
    let conversationCrop: CGRect
    let targetPID: pid_t
    let selectedWindowPID: pid_t?
    let selectedWindowFrame: CGRect?
    let selectedWindowOnScreen: Bool
    let windowFrameDistance: CGFloat?
    let ocrObservationCount: Int
    let headerObservationCount: Int
    let headerCandidates: [VisionHeaderCandidate]
    let acceptedTitleBounds: CGRect?
    let acceptedTitleConfidence: Float?
    let messageObservationCount: Int
    let messageBounds: [CGRect]
}

enum VisionCaptureState: String, Sendable {
    case success = "success"
    case screenRecordingPermissionRequired = "screen recording permission required"
    case weChatWindowNotFound = "WeChat window not found"
    case invalidWindow = "invalid or auxiliary WeChat window"
    case windowCaptureFailed = "WeChat window capture failed"
    case visionFailed = "Vision OCR failed"
}

struct VisionHeaderCandidate: Sendable {
    let bounds: CGRect
    let confidence: Float
    let characterCount: Int
    let accepted: Bool
}

/// Local OCR fallback for WeChat builds that expose a collapsed Accessibility tree.
/// Captures only the WeChat window and never writes or logs the captured image/text.
final class WeChatScreenReader {
    static let shared = WeChatScreenReader()

    private let conversationCropRatio = CGRect(x: 0.28, y: 0, width: 0.72, height: 1)
    // The title can sit close to the top edge on newer WeChat layouts. Keep a
    // little extra room and let candidate scoring distinguish the title from
    // toolbar text instead of cutting observations off at a hard Y boundary.
    private let headerSearchRegion = CGRect(x: 0.0, y: 0.82, width: 1.0, height: 0.179)
    private let messageRegion = CGRect(x: 0.01, y: 0.12, width: 0.98, height: 0.68)

    private let lock = NSLock()
    private var cachedKey: String?
    private var cachedAt = Date.distantPast
    private var cachedSnapshot: VisibleWeChatSnapshot?
    // Reuse the title-detection capture for the immediately following message
    // read, but expire quickly so a changed chat or incoming message is fresh.
    private let cacheDuration: TimeInterval = 0.5

    static var hasScreenCapturePermission: Bool { CGPreflightScreenCaptureAccess() }

    static func requestScreenCapturePermissionOnce() {
        let requestKey = "screen_capture_permission_request_attempted"
        guard !hasScreenCapturePermission,
              !UserDefaults.standard.bool(forKey: requestKey) else { return }
        UserDefaults.standard.set(true, forKey: requestKey)
        _ = CGRequestScreenCaptureAccess()
    }

    func read(pid: pid_t, windowFrame: CGRect, forceFresh: Bool = false) -> VisibleWeChatSnapshot {
        let key = "\(pid):\(Int(windowFrame.origin.x)): \(Int(windowFrame.origin.y)): \(Int(windowFrame.width)): \(Int(windowFrame.height))"
        lock.lock()
        defer { lock.unlock() }
        if !forceFresh, cachedKey == key, Date().timeIntervalSince(cachedAt) < cacheDuration,
           let cachedSnapshot {
            return cachedSnapshot
        }
        cachedKey = key
        let result = capture(pid: pid, windowFrame: windowFrame)
        cachedSnapshot = result.snapshot
        cachedAt = Date()
        return result.snapshot
    }

    private func capture(pid: pid_t, windowFrame: CGRect) -> (snapshot: VisibleWeChatSnapshot, image: CGImage?) {
        guard CGPreflightScreenCaptureAccess() else {
            return (emptySnapshot(pid: pid, crop: conversationCropRatio, state: .screenRecordingPermissionRequired), nil)
        }
        let target = screenCaptureKitWindow(pid: pid, matching: windowFrame) ??
            legacyWindowCapture(pid: pid, matching: windowFrame)
        guard let target else {
            let state: VisionCaptureState = visibleWindow(pid: pid, matching: windowFrame) == nil
                ? .windowCaptureFailed
                : .invalidWindow
            return (emptySnapshot(pid: pid, crop: conversationCropRatio, state: state), nil)
        }
        let capturedWindow = target.image
        let cropX = Int((CGFloat(capturedWindow.width) * 0.28).rounded(.down))
        let conversationCrop = CGRect(
            x: CGFloat(cropX),
            y: 0,
            width: CGFloat(capturedWindow.width - cropX),
            height: CGFloat(capturedWindow.height)
        )
        guard let image = capturedWindow.cropping(to: conversationCrop) else {
            return (emptySnapshot(pid: pid, crop: conversationCropRatio, state: .windowCaptureFailed), capturedWindow)
        }

        let headerRequest = VNRecognizeTextRequest()
        headerRequest.recognitionLevel = .accurate
        headerRequest.usesLanguageCorrection = true
        headerRequest.recognitionLanguages = ["zh-Hans", "en-US"]
        headerRequest.minimumTextHeight = 0.006
        headerRequest.regionOfInterest = headerSearchRegion

        let messageRequest = VNRecognizeTextRequest()
        messageRequest.recognitionLevel = .fast
        messageRequest.usesLanguageCorrection = false
        messageRequest.recognitionLanguages = ["zh-Hans", "en-US"]
        messageRequest.minimumTextHeight = 0.008
        messageRequest.regionOfInterest = messageRegion

        let handler = VNImageRequestHandler(cgImage: image)
        let visionSucceeded = (try? handler.perform([headerRequest, messageRequest])) != nil
        guard visionSucceeded else {
            return (makeSnapshot(
                title: nil, messages: [], state: .visionFailed, pid: pid, image: capturedWindow,
                target: target, headerObservations: 0, headerCandidates: [], acceptedTitleBounds: nil,
                acceptedTitleConfidence: nil,
                messageObservations: 0, messageBounds: []
            ), capturedWindow)
        }

        let headerObservations = headerRequest.results ?? []
        let headerCandidates = rankHeaderCandidates(headerObservations)
        let accepted = headerCandidates.first(where: { $0.diagnostic.accepted })
        let title = accepted?.text

        let messageObservations = messageRequest.results ?? []
        let messageLines = messageObservations.compactMap { observation -> RecognizedMessageLine? in
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= 0.45 else { return nil }
            let bounds = observation.boundingBox
            guard bounds.minX >= messageRegion.minX, bounds.minY >= messageRegion.minY,
                  bounds.maxY <= messageRegion.maxY,
                  !looksLikeTimestampOrControl(candidate.string) else { return nil }
            return RecognizedMessageLine(
                text: candidate.string.trimmingCharacters(in: .whitespacesAndNewlines),
                bounds: bounds,
                confidence: candidate.confidence
            )
        }
        let (messages, messageBounds) = groupMessageLines(messageLines)

        return (makeSnapshot(
            title: title,
            messages: Array(messages.suffix(50)),
            state: .success,
            pid: pid,
            image: capturedWindow,
            target: target,
            headerObservations: headerObservations.count,
            headerCandidates: headerCandidates.map(\.diagnostic),
            acceptedTitleBounds: accepted?.diagnostic.bounds,
            acceptedTitleConfidence: accepted?.diagnostic.confidence,
            messageObservations: messageObservations.count,
            messageBounds: Array(messageBounds.suffix(50))
        ), capturedWindow)
    }

    private func screenCaptureKitWindow(pid: pid_t, matching frame: CGRect) -> CapturedWindow? {
        let contentResult = CallbackResult<SCShareableContent>()
        let contentSemaphore = DispatchSemaphore(value: 0)
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
            contentResult.set(content)
            contentSemaphore.signal()
        }
        guard contentSemaphore.wait(timeout: .now() + 3) == .success,
              let content = contentResult.get() else {
            return nil
        }
        let candidates = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.isOnScreen &&
                $0.frame.width >= 400 && $0.frame.height >= 300
        }
        guard let window = candidates.min(by: { frameDistance($0.frame, frame) < frameDistance($1.frame, frame) }) else {
            return nil
        }
        guard window.owningApplication?.processID == pid,
              window.isOnScreen,
              frameSizeIsPlausible(window.frame, relativeTo: frame) else { return nil }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((window.frame.width * 2).rounded()))
        configuration.height = max(1, Int((window.frame.height * 2).rounded()))
        let imageResult = CallbackResult<CGImage>()
        let imageSemaphore = DispatchSemaphore(value: 0)
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, _ in
            imageResult.set(image)
            imageSemaphore.signal()
        }
        guard imageSemaphore.wait(timeout: .now() + 3) == .success,
              let image = imageResult.get() else { return nil }
        return CapturedWindow(image: image, pid: window.owningApplication?.processID,
                              frame: window.frame, onScreen: window.isOnScreen,
                              distance: frameDistance(window.frame, frame))
    }

    private func legacyWindowCapture(pid: pid_t, matching frame: CGRect) -> CapturedWindow? {
        guard let candidate = visibleWindow(pid: pid, matching: frame),
              candidate.pid == pid, candidate.frame.width >= 400, candidate.frame.height >= 300,
              frameSizeIsPlausible(candidate.frame, relativeTo: frame),
              let image = CGWindowListCreateImage(.null, .optionIncludingWindow, candidate.id, [.bestResolution]) else {
            return nil
        }
        return CapturedWindow(image: image, pid: candidate.pid, frame: candidate.frame,
                              onScreen: true, distance: frameDistance(candidate.frame, frame))
    }

    private func visibleWindow(pid: pid_t, matching frame: CGRect) -> LegacyWindow? {
        visibleWindows().filter { $0.pid == pid && $0.frame.width >= 400 && $0.frame.height >= 300 }
            .min(by: { frameDistance($0.frame, frame) < frameDistance($1.frame, frame) })
    }

    private func visibleWindows() -> [LegacyWindow] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { item in
            guard let pid = item[kCGWindowOwnerPID as String] as? Int32,
                  (item[kCGWindowLayer as String] as? Int) == 0,
                  let number = item[kCGWindowNumber as String] as? NSNumber,
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return LegacyWindow(id: CGWindowID(number.uint32Value), pid: pid, frame: rect)
        }
    }

    private func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.origin.x - rhs.origin.x) + abs(lhs.origin.y - rhs.origin.y) +
            abs(lhs.width - rhs.width) + abs(lhs.height - rhs.height)
    }

    private func frameSizeIsPlausible(_ candidate: CGRect, relativeTo expected: CGRect) -> Bool {
        guard expected.width > 0, expected.height > 0 else { return false }
        let widthRatio = candidate.width / expected.width
        let heightRatio = candidate.height / expected.height
        return (0.65...1.55).contains(widthRatio) && (0.65...1.55).contains(heightRatio)
    }

    private func emptySnapshot(pid: pid_t, crop: CGRect, state: VisionCaptureState) -> VisibleWeChatSnapshot {
        VisibleWeChatSnapshot(
            title: nil, messages: [], captureState: state, captureSucceeded: false,
            capturedSize: nil, conversationCrop: crop, targetPID: pid, selectedWindowPID: nil,
            selectedWindowFrame: nil, selectedWindowOnScreen: false, windowFrameDistance: nil,
            ocrObservationCount: 0, headerObservationCount: 0, headerCandidates: [],
            acceptedTitleBounds: nil, acceptedTitleConfidence: nil,
            messageObservationCount: 0, messageBounds: []
        )
    }

    private func makeSnapshot(
        title: String?, messages: [ChatMessage], state: VisionCaptureState, pid: pid_t,
        image: CGImage, target: CapturedWindow, headerObservations: Int,
        headerCandidates: [VisionHeaderCandidate], acceptedTitleBounds: CGRect?, acceptedTitleConfidence: Float?,
        messageObservations: Int, messageBounds: [CGRect]
    ) -> VisibleWeChatSnapshot {
        VisibleWeChatSnapshot(
            title: title, messages: messages, captureState: state, captureSucceeded: true,
            capturedSize: CGSize(width: image.width, height: image.height),
            conversationCrop: conversationCropRatio,
            targetPID: pid, selectedWindowPID: target.pid, selectedWindowFrame: target.frame,
            selectedWindowOnScreen: target.onScreen, windowFrameDistance: target.distance,
            ocrObservationCount: headerObservations + messageObservations,
            headerObservationCount: headerObservations, headerCandidates: headerCandidates,
            acceptedTitleBounds: acceptedTitleBounds, acceptedTitleConfidence: acceptedTitleConfidence,
            messageObservationCount: messageObservations,
            messageBounds: messageBounds
        )
    }

    private func rankHeaderCandidates(_ observations: [VNRecognizedTextObservation]) -> [RankedHeaderCandidate] {
        var candidates: [RankedHeaderCandidate] = []
        for observation in observations {
            guard let textCandidate = observation.topCandidates(1).first else { continue }
            let text = WeChatParsing.normalizeChatTitle(textCandidate.string)
            let bounds = observation.boundingBox
            // Vision has already limited this request to headerSearchRegion.
            // Avoid a second strict box filter here: it discarded valid titles
            // when glyphs touched the edge of the header or pane.
            guard !text.isEmpty, text.count <= 36 else { continue }
            let generic = isHeaderControl(text)
            let plausible = textCandidate.confidence >= 0.18 && !generic
            let yScore = 1 - min(1, abs(bounds.midY - 0.91) / 0.30)
            let xScore = 1 - min(1, abs(bounds.minX - 0.10) / 0.90)
            let lengthPenalty = text.count > 24 ? 0.7 : 0
            let genericPenalty = generic ? 10.0 : 0
            let score = Double(textCandidate.confidence) * 4 + Double(yScore) * 1.2 +
                Double(xScore) * 0.5 - lengthPenalty - genericPenalty
            candidates.append(RankedHeaderCandidate(
                text: text,
                score: score,
                diagnostic: VisionHeaderCandidate(
                    bounds: bounds,
                    confidence: textCandidate.confidence,
                    characterCount: text.count,
                    accepted: false
                ),
                plausible: plausible
            ))
        }
        candidates.sort { $0.score > $1.score }
        guard let acceptedIndex = candidates.firstIndex(where: \.plausible) else { return candidates }
        candidates[acceptedIndex].diagnostic = VisionHeaderCandidate(
            bounds: candidates[acceptedIndex].diagnostic.bounds,
            confidence: candidates[acceptedIndex].diagnostic.confidence,
            characterCount: candidates[acceptedIndex].diagnostic.characterCount,
            accepted: true
        )
        return candidates
    }

    private func isHeaderControl(_ text: String) -> Bool {
        let normalized = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter { !$0.isWhitespace && !$0.isPunctuation }
        let controls = [
            "wechat", "wechat(chats)", "wechat(contacts)", "weixin", "微信", "微信聊天",
            "search", "搜索", "chats", "聊天", "contacts", "通讯录", "discover", "发现",
            "moments", "朋友圈", "settings", "设置", "more", "更多"
        ]
        return controls.contains(normalized)
    }

    func diagnosticReport(pid: pid_t, windowFrame: CGRect) -> String {
        let snapshot = read(pid: pid, windowFrame: windowFrame, forceFresh: true)
        let size = snapshot.capturedSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "unavailable"
        let crop = snapshot.conversationCrop
        var lines = [
            "Screen Recording permission: \(Self.hasScreenCapturePermission ? "granted" : "not granted")",
            "Target WeChat PID: \(snapshot.targetPID)",
            "Selected window PID: \(snapshot.selectedWindowPID.map(String.init) ?? "unavailable")",
            "Target PID matches: \(snapshot.selectedWindowPID == snapshot.targetPID)",
            "Window on screen: \(snapshot.selectedWindowOnScreen)",
            "Window frame: \(snapshot.selectedWindowFrame.map(frameDescription) ?? "unavailable")",
            "Window dimensions realistic: \(snapshot.selectedWindowFrame.map { $0.width >= 400 && $0.height >= 300 } ?? false)",
            "Window frame distance from AX: \(snapshot.windowFrameDistance.map { String(format: "%.1f", $0) } ?? "unavailable")",
            "Window capture: \(snapshot.captureSucceeded ? "success" : snapshot.captureState.rawValue)",
            "Captured size: \(size)",
            "Conversation crop ratio: x=\(ratio(crop.minX)) y=\(ratio(crop.minY)) width=\(ratio(crop.width)) height=\(ratio(crop.height))",
            "Header search ratio: x=\(ratio(headerSearchRegion.minX)) y=\(ratio(headerSearchRegion.minY)) width=\(ratio(headerSearchRegion.width)) height=\(ratio(headerSearchRegion.height))",
            "Message region ratio: x=\(ratio(messageRegion.minX)) y=\(ratio(messageRegion.minY)) width=\(ratio(messageRegion.width)) height=\(ratio(messageRegion.height))",
            "OCR observations total: \(snapshot.ocrObservationCount)",
            "Header-region observations: \(snapshot.headerObservationCount)",
            "Header candidates after filtering: \(snapshot.headerCandidates.count)",
            "Accepted title: \(snapshot.title == nil ? "no" : "yes")",
            "Raw OCR line count: \(snapshot.messageObservationCount)",
            "Grouped message blocks: \(snapshot.messages.count)",
            "Grouped senders: me=\(snapshot.messages.filter { $0.sender == .me }.count) target=\(snapshot.messages.filter { $0.sender == .other }.count) unknown=\(snapshot.messages.filter { $0.sender == .unknown }.count)",
            "Header/message ROI overlap: \(!headerSearchRegion.intersection(messageRegion).isNull && !headerSearchRegion.intersection(messageRegion).isEmpty)",
            "Accepted title confidence: \(snapshot.acceptedTitleConfidence.map { String(format: "%.3f", $0) } ?? "unavailable")"
        ]
        for (index, candidate) in snapshot.headerCandidates.enumerated() {
            lines.append("Header candidate \(index + 1): bbox=\(rectDescription(candidate.bounds)) confidence=\(String(format: "%.3f", candidate.confidence)) characters=\(candidate.characterCount) accepted=\(candidate.accepted)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func annotatedPreview(pid: pid_t, windowFrame: CGRect) -> NSImage? {
        let key = "\(pid):\(Int(windowFrame.origin.x)): \(Int(windowFrame.origin.y)): \(Int(windowFrame.width)): \(Int(windowFrame.height))"
        lock.lock()
        let result = capture(pid: pid, windowFrame: windowFrame)
        cachedKey = key
        cachedSnapshot = result.snapshot
        cachedAt = Date()
        lock.unlock()
        guard let source = result.image, result.snapshot.captureSucceeded else { return nil }

        let size = NSSize(width: source.width, height: source.height)
        let image = NSImage(cgImage: source, size: size)
        image.lockFocus()
        let cropX = size.width * 0.28
        NSColor.systemBlue.setStroke()
        NSBezierPath(rect: NSRect(x: cropX, y: 0, width: size.width - cropX, height: size.height)).stroke()
        NSColor.systemYellow.setStroke()
        visionRect(headerSearchRegion, cropX: cropX, size: size).stroke()
        NSColor.systemGreen.setStroke()
        visionRect(messageRegion, cropX: cropX, size: size).stroke()
        NSColor.systemRed.setStroke()
        if let titleBounds = result.snapshot.acceptedTitleBounds {
            visionRect(titleBounds, cropX: cropX, size: size).stroke()
        }
        for bounds in result.snapshot.messageBounds {
            visionRect(bounds, cropX: cropX, size: size).stroke()
        }
        image.unlockFocus()
        return image
    }

    private func visionRect(_ rect: CGRect, cropX: CGFloat, size: NSSize) -> NSBezierPath {
        NSBezierPath(rect: NSRect(
            x: cropX + rect.minX * (size.width - cropX),
            y: rect.minY * size.height,
            width: rect.width * (size.width - cropX),
            height: rect.height * size.height
        ))
    }

    private func ratio(_ value: CGFloat) -> String { String(format: "%.3f", value) }
    private func rectDescription(_ rect: CGRect) -> String {
        "\(ratio(rect.minX)),\(ratio(rect.minY)),\(ratio(rect.width)),\(ratio(rect.height))"
    }
    private func frameDescription(_ rect: CGRect) -> String {
        "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"
    }

    private func looksLikeTimestampOrControl(_ text: String) -> Bool {
        if text.range(of: #"^\d{1,2}:\d{2}$|^\d{1,4}/\d{1,2}.*$|^\d{1,2}月\d{1,2}日$"#, options: .regularExpression) != nil {
            return true
        }
        return ["WeChat", "微信", "Search", "搜索", "Chats", "聊天", "Contacts", "通讯录"]
            .contains(text)
    }

    private func groupMessageLines(_ lines: [RecognizedMessageLine]) -> ([ChatMessage], [CGRect]) {
        var bubbles: [(text: String, bounds: CGRect, lines: [RecognizedMessageLine])] = []
        for line in lines.sorted(by: { $0.bounds.maxY > $1.bounds.maxY }) {
            if let previous = bubbles.last {
                let verticalGap = previous.bounds.minY - line.bounds.maxY
                let referenceHeight = max(previous.bounds.height / CGFloat(previous.lines.count), line.bounds.height)
                let verticalTolerance = max(0.010, referenceHeight * 0.75)
                let overlap = max(0, min(previous.bounds.maxX, line.bounds.maxX) - max(previous.bounds.minX, line.bounds.minX))
                let narrowerWidth = max(0.001, min(previous.bounds.width, line.bounds.width))
                let rangesOverlap = overlap / narrowerWidth >= 0.40
                let alignmentTolerance = max(0.025, referenceHeight * 1.8)
                let leftAligned = abs(previous.bounds.minX - line.bounds.minX) <= alignmentTolerance
                let rightAligned = abs(previous.bounds.maxX - line.bounds.maxX) <= alignmentTolerance
                let previousSide = messageSide(previous.bounds)
                let lineSide = messageSide(line.bounds)
                let compatibleSide = previousSide == .unknown || lineSide == .unknown || previousSide == lineSide
                let sameBubble = verticalGap >= -referenceHeight * 0.4 &&
                    verticalGap <= verticalTolerance &&
                    (rangesOverlap || leftAligned || rightAligned) && compatibleSide
                if sameBubble {
                    bubbles[bubbles.count - 1].text += "\n" + line.text
                    bubbles[bubbles.count - 1].bounds = previous.bounds.union(line.bounds)
                    bubbles[bubbles.count - 1].lines.append(line)
                    continue
                }
            }
            bubbles.append((line.text, line.bounds, [line]))
        }
        let messages = bubbles.enumerated().map { index, bubble in
            let sender = messageSide(bubble.bounds)
            let normalizedText = bubble.text
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let senderKey = senderKey(for: sender)
            // Order within this transient OCR snapshot distinguishes repeated
            // identical bubbles while remaining stable as bubbles shift vertically.
            let snapshotKey = "vision:\(senderKey):\(normalizedText):order\(index)"
            return ChatMessage(text: bubble.text, sender: sender, allowsAutomaticAnalysis: false, id: snapshotKey)
        }
        return (messages, bubbles.map(\.bounds))
    }

    private func messageSide(_ bounds: CGRect) -> MessageSender {
        if bounds.maxX >= 0.88 && bounds.minX >= 0.28 { return .me }
        if bounds.minX <= 0.12 && bounds.maxX <= 0.72 { return .other }
        return .unknown
    }

    private func senderKey(for sender: MessageSender) -> String {
        switch sender {
        case .me: return "me"
        case .other: return "other"
        case .unknown: return "unknown"
        }
    }
}

private struct RecognizedMessageLine {
    let text: String
    let bounds: CGRect
    let confidence: Float
}

private struct CapturedWindow {
    let image: CGImage
    let pid: pid_t?
    let frame: CGRect
    let onScreen: Bool
    let distance: CGFloat
}

private struct LegacyWindow {
    let id: CGWindowID
    let pid: pid_t
    let frame: CGRect
    var distance: CGFloat { 0 }
}

private struct RankedHeaderCandidate {
    let text: String
    let score: Double
    var diagnostic: VisionHeaderCandidate
    let plausible: Bool
}

private final class CallbackResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func set(_ value: Value?) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
