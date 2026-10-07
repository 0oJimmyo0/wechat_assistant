import AppKit
import CoreGraphics
import Vision

struct VisibleWeChatSnapshot {
    let title: String?
    let messages: [ChatMessage]
}

/// Local OCR fallback for WeChat builds that expose a collapsed Accessibility tree.
/// Captures only the WeChat window and never writes or logs the captured image/text.
final class WeChatScreenReader {
    static let shared = WeChatScreenReader()

    private let lock = NSLock()
    private var cachedKey: String?
    private var cachedAt = Date.distantPast
    private var cachedSnapshot: VisibleWeChatSnapshot?
    // Reuse the title-detection capture for the immediately following message
    // read, but expire quickly so a changed chat or incoming message is fresh.
    private let cacheDuration: TimeInterval = 0.5

    static var hasScreenCapturePermission: Bool { CGPreflightScreenCaptureAccess() }

    func read(pid: pid_t, windowFrame: CGRect) -> VisibleWeChatSnapshot? {
        let key = "\(pid):\(Int(windowFrame.origin.x)): \(Int(windowFrame.origin.y)): \(Int(windowFrame.width)): \(Int(windowFrame.height))"
        lock.lock()
        defer { lock.unlock() }
        if cachedKey == key, Date().timeIntervalSince(cachedAt) < cacheDuration {
            return cachedSnapshot
        }
        cachedKey = key
        cachedSnapshot = capture(pid: pid, windowFrame: windowFrame)
        cachedAt = Date()
        return cachedSnapshot
    }

    private func capture(pid: pid_t, windowFrame: CGRect) -> VisibleWeChatSnapshot? {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess(),
              let windowID = visibleWindowID(pid: pid, matching: windowFrame),
              let capturedWindow = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.bestResolution]) else {
            return nil
        }
        let cropX = Int((CGFloat(capturedWindow.width) * 0.28).rounded(.down))
        let conversationCrop = CGRect(
            x: CGFloat(cropX),
            y: 0,
            width: CGFloat(capturedWindow.width - cropX),
            height: CGFloat(capturedWindow.height)
        )
        guard let image = capturedWindow.cropping(to: conversationCrop) else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil else { return nil }

        let lines = (request.results ?? []).compactMap { observation -> (String, CGRect, Float)? in
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= 0.45 else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return (text, observation.boundingBox, candidate.confidence)
        }

        // Crop away the left 28% conversation/sidebar rail before OCR. Only the
        // right-pane header can identify the active chat; generic chrome is rejected.
        let title = lines
            .filter { $0.1.minX >= 0.01 && $0.1.minY >= 0.80 && $0.1.maxY <= 0.965 }
            .sorted { lhs, rhs in
                if lhs.1.midY != rhs.1.midY { return lhs.1.midY > rhs.1.midY }
                return lhs.2 > rhs.2
            }
            .map(\.0)
            .map(WeChatParsing.normalizeChatTitle)
            .first { !$0.isEmpty && !WeChatParsing.isGenericWindowTitle($0) }

        // Bubble alignment provides a conservative sender hint. Ambiguous rows
        // stay unknown, and every OCR row remains manual-only regardless.
        let messageLines = lines
            .filter { $0.1.minX >= 0.01 && $0.1.minY >= 0.14 && $0.1.maxY <= 0.80 }
            .filter { !looksLikeTimestampOrControl($0.0) }
        let messages = groupMessageLines(messageLines).suffix(50)

        return VisibleWeChatSnapshot(title: title, messages: Array(messages))
    }

    private func visibleWindowID(pid: pid_t, matching frame: CGRect) -> CGWindowID? {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let candidates: [(CGWindowID, CGFloat)] = raw.compactMap { item in
            guard (item[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (item[kCGWindowLayer as String] as? Int) == 0,
                  let number = item[kCGWindowNumber as String] as? NSNumber,
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            let score = abs(rect.origin.x - frame.origin.x) + abs(rect.origin.y - frame.origin.y) +
                abs(rect.width - frame.width) + abs(rect.height - frame.height)
            return (CGWindowID(number.uint32Value), score)
        }
        return candidates.min(by: { $0.1 < $1.1 })?.0
    }

    private func looksLikeTimestampOrControl(_ text: String) -> Bool {
        if text.range(of: #"^\d{1,2}:\d{2}$|^\d{1,4}/\d{1,2}.*$|^\d{1,2}月\d{1,2}日$"#, options: .regularExpression) != nil {
            return true
        }
        return ["WeChat", "微信", "Search", "搜索", "Chats", "聊天", "Contacts", "通讯录"]
            .contains(text)
    }

    private func sender(for textBounds: CGRect) -> MessageSender {
        if textBounds.minX >= 0.55 { return .me }
        if textBounds.minX <= 0.20 && textBounds.maxX <= 0.55 { return .other }
        return .unknown
    }

    private func groupMessageLines(_ lines: [(String, CGRect, Float)]) -> [ChatMessage] {
        var bubbles: [(text: String, bounds: CGRect, sender: MessageSender)] = []
        for line in lines.sorted(by: { $0.1.maxY > $1.1.maxY }) {
            let lineSender = sender(for: line.1)
            if let previous = bubbles.last {
                let verticalGap = previous.bounds.minY - line.1.maxY
                let sameBubble = lineSender != .unknown &&
                    lineSender == previous.sender &&
                    abs(previous.bounds.minX - line.1.minX) <= 0.035 &&
                    verticalGap >= -0.004 && verticalGap <= 0.008
                if sameBubble {
                    bubbles[bubbles.count - 1].text += "\n" + line.0
                    bubbles[bubbles.count - 1].bounds = previous.bounds.union(line.1)
                    continue
                }
            }
            bubbles.append((line.0, line.1, lineSender))
        }
        return bubbles.map {
            ChatMessage(text: $0.text, sender: $0.sender, allowsAutomaticAnalysis: false)
        }
    }
}
