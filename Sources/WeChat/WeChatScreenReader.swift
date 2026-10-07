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
    let paneGeometry: ConversationPaneGeometry
    let messagePaneLeftX: CGFloat
    let messageCrop: CGRect
    let targetPID: pid_t
    let selectedWindowPID: pid_t?
    let selectedWindowFrame: CGRect?
    let selectedWindowOnScreen: Bool
    let windowFrameDistance: CGFloat?
    let windowDiscoveryDurationMilliseconds: Int
    let captureDurationMilliseconds: Int
    let visionDurationMilliseconds: Int
    let ocrObservationCount: Int
    let headerObservationCount: Int
    let headerCandidates: [VisionHeaderCandidate]
    let acceptedTitleBounds: CGRect?
    let acceptedTitleConfidence: Float?
    let titleIdentity: VisionConversationIdentity?
    let titleRejectedAsMessageCount: Int
    let titleRejectedAsSentenceCount: Int
    let messageObservationCount: Int
    let messageBounds: [CGRect]
    let rejectedMessageBounds: [CGRect]
    let messageFingerprint: String?
    let messageFrameUnchanged: Bool
    let headerFingerprint: String?
    let headerFrameUnchanged: Bool
    let headerOCRDurationMilliseconds: Int
    let messageOCRDurationMilliseconds: Int
    let messageRecognitionLevel: String
    let fastOCRObservationCount: Int
    let accurateFallbackAttempted: Bool
    let accurateOCRObservationCount: Int
    let plausibleTextObservationCount: Int
    let geometryRejectedMessageCount: Int
    let timestampControlRejectedMessageCount: Int
    let wideCropFallbackAttempted: Bool
    let wideCropObservationCount: Int
    let wideCropFallbackSucceeded: Bool
}

struct VisionLayoutCalibration {
    let messagePaneLeftX: CGFloat
    let headerBottomY: CGFloat
    let composerTopY: CGFloat

    static var current: VisionLayoutCalibration {
        let defaults = UserDefaults.standard
        let left = CGFloat(defaults.object(forKey: "vision_conversation_left_x") as? Double ?? 0.28)
        let header = CGFloat(defaults.object(forKey: "vision_header_bottom_y") as? Double ?? 0.90)
        let composer = CGFloat(defaults.object(forKey: "vision_composer_top_y") as? Double ?? 0.18)
        let safeHeader = min(0.96, max(0.65, header))
        let safeComposer = min(safeHeader - 0.04, max(0.05, composer))
        return VisionLayoutCalibration(
            messagePaneLeftX: min(0.70, max(0.01, left)),
            headerBottomY: safeHeader,
            composerTopY: safeComposer
        )
    }
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
    let rejection: String?
}

/// Local OCR fallback for WeChat builds that expose a collapsed Accessibility tree.
/// Captures only the WeChat window and never writes or logs the captured image/text.
final class WeChatScreenReader {
    static let shared = WeChatScreenReader()

    private var conversationCropRatio: CGRect {
        conversationCropRatio(leftX: VisionLayoutCalibration.current.messagePaneLeftX)
    }
    private func conversationCropRatio(leftX: CGFloat) -> CGRect {
        let x = min(0.70, max(0.01, leftX))
        return CGRect(x: x, y: 0, width: 1 - x, height: 1)
    }
    private var messageRegion: CGRect {
        let calibration = VisionLayoutCalibration.current
        return CGRect(x: 0.01, y: calibration.composerTopY, width: 0.98,
                      height: calibration.headerBottomY - calibration.composerTopY - 0.02)
    }

    /// Message geometry is expressed in full-window normalized coordinates.
    /// The title/header ROI remains independent of this pane crop.
    private func messageRegion(leftX: CGFloat) -> CGRect {
        VisionLayoutRegions.messagePane(leftX: leftX, verticalRegion: messageRegion)
    }

    private let cacheCondition = NSCondition()
    private var captureInProgress = false
    private var cachedKey: String?
    private var cachedAt = Date.distantPast
    private var cachedSnapshot: VisibleWeChatSnapshot?
    private var cachedSourceKey: String?
    private var cachedSourceAt = Date.distantPast
    private var cachedCapturedWindow: CapturedWindow?
    private var cachedSCWindow: SCWindow?
    private var cachedSCWindowPID: pid_t?
    private var cachedSCWindowFrame: CGRect?
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
        readFullSnapshot(pid: pid, windowFrame: windowFrame, forceFresh: forceFresh)
    }

    func readFullSnapshot(pid: pid_t, windowFrame: CGRect, forceFresh: Bool = false) -> VisibleWeChatSnapshot {
        read(pid: pid, windowFrame: windowFrame, mode: .full, forceFresh: forceFresh)
    }

    func readTitleIdentity(pid: pid_t, windowFrame: CGRect, forceFresh: Bool = false,
                           messagePaneLeftX: CGFloat? = nil,
                           paneGeometry: ConversationPaneGeometry? = nil) -> VisibleWeChatSnapshot {
        read(pid: pid, windowFrame: windowFrame, mode: .titleOnly, forceFresh: forceFresh,
             messagePaneLeftX: messagePaneLeftX, paneGeometry: paneGeometry)
    }

    func readMessages(pid: pid_t, windowFrame: CGRect, forceFresh: Bool = false,
                      accurate: Bool = false, previousFingerprint: String? = nil) -> VisibleWeChatSnapshot {
        read(pid: pid, windowFrame: windowFrame, mode: accurate ? .messagesAccurate : .messagesFast,
             forceFresh: forceFresh, previousMessageFingerprint: previousFingerprint)
    }

    func readConversationObservation(pid: pid_t, windowFrame: CGRect, includeTitle: Bool,
                                     includeMessages: Bool, forceFresh: Bool,
                                     accurateMessages: Bool = false,
                                     previousHeaderFingerprint: String? = nil,
                                     previousMessageFingerprint: String? = nil,
                                     messagePaneLeftX: CGFloat? = nil,
                                     paneGeometry: ConversationPaneGeometry? = nil) -> VisibleWeChatSnapshot {
        let mode: VisionReadMode
        switch (includeTitle, includeMessages) {
        case (true, true): mode = accurateMessages ? .full : .fullFast
        case (true, false): mode = .titleOnly
        case (false, true): mode = accurateMessages ? .messagesAccurate : .messagesFast
        case (false, false): mode = .titleOnly
        }
        return read(pid: pid, windowFrame: windowFrame, mode: mode, forceFresh: forceFresh,
                    previousHeaderFingerprint: previousHeaderFingerprint,
                    previousMessageFingerprint: previousMessageFingerprint,
                    messagePaneLeftX: messagePaneLeftX,
                    paneGeometry: paneGeometry)
    }

    private func read(pid: pid_t, windowFrame: CGRect, mode: VisionReadMode,
                      forceFresh: Bool, previousHeaderFingerprint: String? = nil,
                      previousMessageFingerprint: String? = nil,
                      messagePaneLeftX: CGFloat? = nil,
                      paneGeometry: ConversationPaneGeometry? = nil) -> VisibleWeChatSnapshot {
        let leftX = paneGeometry?.leftX ?? messagePaneLeftX ?? VisionLayoutCalibration.current.messagePaneLeftX
        let geometryKey = paneGeometry.map {
            "\($0.source.rawValue):\($0.leftX):\($0.headerRegion):\($0.messageRegion)"
        } ?? "configured:\(leftX):\(VisionLayoutCalibration.current.headerBottomY):\(VisionLayoutCalibration.current.composerTopY)"
        let key = "\(pid):\(Int(windowFrame.origin.x)): \(Int(windowFrame.origin.y)): \(Int(windowFrame.width)): \(Int(windowFrame.height)): \(geometryKey)"
        cacheCondition.lock()
        while captureInProgress { cacheCondition.wait() }
        if mode == .full, !forceFresh, cachedKey == key, Date().timeIntervalSince(cachedAt) < cacheDuration,
           let cachedSnapshot {
            cacheCondition.unlock()
            return cachedSnapshot
        }
        captureInProgress = true
        cacheCondition.unlock()

        // ScreenCaptureKit, semaphore waits, and Vision OCR all run without
        // holding the cache lock. Other readers wait on the condition and can
        // never start a duplicate capture while these mutable window caches
        // are in use.
        let result = capture(pid: pid, windowFrame: windowFrame, mode: mode, forceFresh: forceFresh,
                             previousHeaderFingerprint: previousHeaderFingerprint,
                             previousMessageFingerprint: previousMessageFingerprint,
                             messagePaneLeftX: leftX,
                             paneGeometry: paneGeometry)
        cacheCondition.lock()
        if mode == .full {
            cachedKey = key
            cachedSnapshot = result.snapshot
            cachedAt = Date()
        }
        captureInProgress = false
        cacheCondition.broadcast()
        cacheCondition.unlock()
        return result.snapshot
    }

    private func capture(pid: pid_t, windowFrame: CGRect, mode: VisionReadMode,
                         forceFresh: Bool = true,
                         previousHeaderFingerprint: String? = nil,
                         previousMessageFingerprint: String? = nil,
                         messagePaneLeftX: CGFloat? = nil,
                         paneGeometry: ConversationPaneGeometry? = nil) -> (snapshot: VisibleWeChatSnapshot, image: CGImage?) {
        let calibration = VisionLayoutCalibration.current
        let configuredLeftX = paneGeometry?.leftX ?? messagePaneLeftX ?? calibration.messagePaneLeftX
        var geometry = paneGeometry ?? VisionLayoutRegions.geometry(
            leftX: configuredLeftX, headerBottomY: calibration.headerBottomY,
            composerTopY: calibration.composerTopY, source: .configuredFallback, confidence: 0.40
        )
        let configuredCrop = conversationCropRatio(leftX: configuredLeftX)
        guard CGPreflightScreenCaptureAccess() else {
            return (emptySnapshot(pid: pid, crop: configuredCrop, state: .screenRecordingPermissionRequired), nil)
        }
        let sourceKey = "\(pid):\(Int(windowFrame.origin.x)): \(Int(windowFrame.origin.y)): \(Int(windowFrame.width)): \(Int(windowFrame.height))"
        let target: CapturedWindow?
        if !forceFresh, cachedSourceKey == sourceKey,
           Date().timeIntervalSince(cachedSourceAt) < cacheDuration,
           let cachedCapturedWindow {
            target = cachedCapturedWindow
        } else {
            target = screenCaptureKitWindow(pid: pid, matching: windowFrame, scale: mode.captureScale) ??
                legacyWindowCapture(pid: pid, matching: windowFrame)
            cachedSourceKey = sourceKey
            cachedSourceAt = Date()
            cachedCapturedWindow = target
        }
        guard let target else {
            let state: VisionCaptureState = visibleWindow(pid: pid, matching: windowFrame) == nil
                ? .windowCaptureFailed
                : .invalidWindow
            return (emptySnapshot(pid: pid, crop: configuredCrop, state: state), nil)
        }
        // Keep the one captured WeChat window as the common coordinate space.
        // Title and message OCR use separate regions of this same image, both
        // constrained by the resolved conversation pane.
        let capturedWindow = target.image
        let image = capturedWindow
        if geometry.source == .configuredFallback,
           let visualLeftX = visualConversationDivider(in: image) {
            geometry = VisionLayoutRegions.geometry(
                leftX: visualLeftX,
                headerBottomY: calibration.headerBottomY,
                composerTopY: calibration.composerTopY,
                source: .visualDivider,
                confidence: 0.74
            )
        }
        let titleRegion = geometry.headerRegion

        var headerObservations: [VNRecognizedTextObservation] = []
        var messageObservations: [VNRecognizedTextObservation] = []
        var parsedMessages = ParsedMessageCapture(messages: [], bounds: [], rejectedBounds: [],
                                                  plausibleTextCount: 0, geometryRejectedCount: 0,
                                                  timestampControlRejectedCount: 0)
        var messageFingerprint: String?
        var messageFrameUnchanged = false
        let usedLeftX = geometry.leftX
        var fastOCRObservationCount = 0
        var accurateOCRObservationCount = 0
        var accurateFallbackAttempted = false
        let wideCropFallbackAttempted = false
        let wideCropObservationCount = 0
        let wideCropFallbackSucceeded = false
        var activeMessageRecognitionLevel = mode.messageRecognitionLevel
        let effectiveMessageRegion = geometry.messageRegion
        var headerFingerprint: String?
        var headerFrameUnchanged = false
        var headerOCRDurationMilliseconds = 0
        var messageOCRDurationMilliseconds = 0
        let visionStarted = Date()
        var visionSucceeded = true
        var messageOCRSucceeded = true

        if mode.readsTitle {
            if let headerImage = crop(image, to: titleRegion) {
                headerFingerprint = perceptualFingerprint(headerImage, width: 32, height: 24)
                headerFrameUnchanged = previousHeaderFingerprint.map {
                    fingerprintDistance(headerFingerprint ?? "", $0) <= 0.003
                } ?? false
                if !headerFrameUnchanged {
                    let ocrStarted = Date()
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true
                    request.recognitionLanguages = ["zh-Hans", "en-US"]
                    request.minimumTextHeight = 0.006
                    visionSucceeded = (try? VNImageRequestHandler(cgImage: headerImage).perform([request])) != nil
                    headerObservations = request.results ?? []
                    headerOCRDurationMilliseconds = Int(Date().timeIntervalSince(ocrStarted) * 1000)
                }
            } else {
                visionSucceeded = false
            }
        }

        if mode.readsMessages {
            if let messageImage = crop(image, to: effectiveMessageRegion),
               let fingerprint = perceptualFingerprint(messageImage) {
                messageFingerprint = fingerprint
                messageFrameUnchanged = previousMessageFingerprint.map {
                    fingerprintDistance(fingerprint, $0) <= 0.015
                } ?? false
                if !messageFrameUnchanged {
                    let initial = recognizeMessageImage(messageImage, level: mode.messageRecognitionLevel)
                    messageOCRSucceeded = initial.succeeded
                    messageObservations = initial.observations
                    messageOCRDurationMilliseconds += initial.durationMilliseconds
                    if mode.messageRecognitionLevel == .fast {
                        fastOCRObservationCount = initial.observations.count
                    } else {
                        accurateOCRObservationCount = initial.observations.count
                    }
                    parsedMessages = parseMessageObservations(messageObservations, region: effectiveMessageRegion)

                    // Fast OCR is a speed path, not an empty-result authority.
                    // Retry accurate OCR against this same cropped image when
                    // fast OCR yields no accepted message bubbles.
                    if parsedMessages.messages.isEmpty && mode.messageRecognitionLevel == .fast {
                        accurateFallbackAttempted = true
                        let accurate = recognizeMessageImage(messageImage, level: .accurate)
                        messageOCRSucceeded = messageOCRSucceeded || accurate.succeeded
                        accurateOCRObservationCount = accurate.observations.count
                        messageOCRDurationMilliseconds += accurate.durationMilliseconds
                        if accurate.succeeded {
                            messageObservations = accurate.observations
                            parsedMessages = parseMessageObservations(messageObservations, region: effectiveMessageRegion)
                            activeMessageRecognitionLevel = .accurate
                        }
                    }

                }
            } else {
                visionSucceeded = false
            }
            visionSucceeded = visionSucceeded && messageOCRSucceeded
        }

        guard visionSucceeded else {
            return (makeSnapshot(
                title: nil, messages: [], state: .visionFailed, pid: pid, image: capturedWindow,
                target: target, paneGeometry: geometry,
                headerObservations: 0, headerCandidates: [], acceptedTitleBounds: nil,
                acceptedTitleConfidence: nil, titleIdentity: nil,
                titleRejectedAsMessageCount: 0, titleRejectedAsSentenceCount: 0,
                messageObservations: 0, messageBounds: [], rejectedMessageBounds: [],
                messageFingerprint: messageFingerprint, messageFrameUnchanged: messageFrameUnchanged,
                headerFingerprint: headerFingerprint, headerFrameUnchanged: headerFrameUnchanged,
                headerOCRDurationMilliseconds: headerOCRDurationMilliseconds,
                messageOCRDurationMilliseconds: messageOCRDurationMilliseconds,
                messagePaneLeftX: usedLeftX,
                messageRecognitionLevel: messageRecognitionLevelName(activeMessageRecognitionLevel),
                fastOCRObservationCount: fastOCRObservationCount,
                accurateFallbackAttempted: accurateFallbackAttempted,
                accurateOCRObservationCount: accurateOCRObservationCount,
                plausibleTextObservationCount: parsedMessages.plausibleTextCount,
                geometryRejectedMessageCount: parsedMessages.geometryRejectedCount,
                timestampControlRejectedMessageCount: parsedMessages.timestampControlRejectedCount,
                wideCropFallbackAttempted: wideCropFallbackAttempted,
                wideCropObservationCount: wideCropObservationCount,
                wideCropFallbackSucceeded: wideCropFallbackSucceeded
            ), capturedWindow)
        }

        let headerCandidates = rankHeaderCandidates(headerObservations, region: titleRegion)
        let messages = parsedMessages.messages
        let messageBounds = parsedMessages.bounds
        let rejectedMessageBounds = parsedMessages.rejectedBounds
        let rawMessageTexts = messageObservations.compactMap { $0.topCandidates(1).first?.string }
        let titleSelection = mode.readsTitle
            ? selectHeaderCandidate(headerCandidates, messageTexts: rawMessageTexts + messages.map(\.text), region: titleRegion)
            : TitleSelection(candidates: headerCandidates, rejectedAsMessageCount: 0, rejectedAsSentenceCount: 0)
        let selectedCandidates = titleSelection.candidates
        let accepted = selectedCandidates.first(where: { $0.diagnostic.accepted })
        let title = accepted?.text
        let acceptedIdentity = accepted.map { candidate in
            VisionConversationIdentity(
                normalizedTitle: WeChatParsing.conversationIdentityKey(candidate.text),
                titleCenterX: candidate.diagnostic.bounds.midX,
                titleCenterY: candidate.diagnostic.bounds.midY,
                titleWidth: candidate.diagnostic.bounds.width,
                confidence: candidate.diagnostic.confidence
            )
        }

        return (makeSnapshot(
            title: title,
            messages: Array(messages.suffix(50)),
            state: .success,
            pid: pid,
            image: capturedWindow,
            target: target,
            conversationCrop: conversationCropRatio(leftX: usedLeftX),
            messageCrop: effectiveMessageRegion,
            paneGeometry: geometry,
            headerObservations: headerObservations.count,
            headerCandidates: selectedCandidates.map(\.diagnostic),
            acceptedTitleBounds: accepted?.diagnostic.bounds,
            acceptedTitleConfidence: accepted?.diagnostic.confidence,
            titleIdentity: acceptedIdentity,
            titleRejectedAsMessageCount: titleSelection.rejectedAsMessageCount,
            titleRejectedAsSentenceCount: titleSelection.rejectedAsSentenceCount,
            messageObservations: messageObservations.count,
            messageBounds: Array(messageBounds.suffix(50)),
            rejectedMessageBounds: rejectedMessageBounds,
            messageFingerprint: messageFingerprint,
            messageFrameUnchanged: messageFrameUnchanged,
            headerFingerprint: headerFingerprint,
            headerFrameUnchanged: headerFrameUnchanged,
            headerOCRDurationMilliseconds: headerOCRDurationMilliseconds,
            messageOCRDurationMilliseconds: messageOCRDurationMilliseconds,
            visionDurationMilliseconds: Int(Date().timeIntervalSince(visionStarted) * 1000),
            messagePaneLeftX: usedLeftX,
            messageRecognitionLevel: messageRecognitionLevelName(activeMessageRecognitionLevel),
            fastOCRObservationCount: fastOCRObservationCount,
            accurateFallbackAttempted: accurateFallbackAttempted,
            accurateOCRObservationCount: accurateOCRObservationCount,
            plausibleTextObservationCount: parsedMessages.plausibleTextCount,
            geometryRejectedMessageCount: parsedMessages.geometryRejectedCount,
            timestampControlRejectedMessageCount: parsedMessages.timestampControlRejectedCount,
            wideCropFallbackAttempted: wideCropFallbackAttempted,
            wideCropObservationCount: wideCropObservationCount,
            wideCropFallbackSucceeded: wideCropFallbackSucceeded
        ), capturedWindow)
    }

    private func screenCaptureKitWindow(pid: pid_t, matching frame: CGRect, scale: CGFloat) -> CapturedWindow? {
        let maxFrameDrift = max(140, frame.width * 0.12)
        var window = cachedSCWindow
        var discoveryMilliseconds = 0
        if cachedSCWindowPID != pid || cachedSCWindowFrame.map({ frameDistance($0, frame) > maxFrameDrift }) != false ||
            window?.isOnScreen != true || window?.owningApplication?.processID != pid {
            window = nil
            cachedSCWindow = nil
            cachedSCWindowPID = nil
            cachedSCWindowFrame = nil
        }

        if window == nil {
            let discoveryStarted = Date()
            let contentResult = CallbackResult<SCShareableContent>()
            let contentSemaphore = DispatchSemaphore(value: 0)
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
                contentResult.set(content)
                contentSemaphore.signal()
            }
            guard contentSemaphore.wait(timeout: .now() + 1.0) == .success,
                  let content = contentResult.get() else { return nil }
            discoveryMilliseconds = Int(Date().timeIntervalSince(discoveryStarted) * 1000)
            let candidates = content.windows.filter {
                $0.owningApplication?.processID == pid && $0.isOnScreen &&
                    $0.frame.width >= 400 && $0.frame.height >= 300
            }
            guard let selected = candidates.min(by: { frameDistance($0.frame, frame) < frameDistance($1.frame, frame) }),
                  selected.owningApplication?.processID == pid,
                  selected.isOnScreen,
                  frameSizeIsPlausible(selected.frame, relativeTo: frame) else { return nil }
            window = selected
            cachedSCWindow = selected
            cachedSCWindowPID = pid
            cachedSCWindowFrame = selected.frame
        }

        guard let window else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((window.frame.width * scale).rounded()))
        configuration.height = max(1, Int((window.frame.height * scale).rounded()))
        let imageResult = CallbackResult<CGImage>()
        let imageSemaphore = DispatchSemaphore(value: 0)
        let screenshotStarted = Date()
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, _ in
            imageResult.set(image)
            imageSemaphore.signal()
        }
        guard imageSemaphore.wait(timeout: .now() + 1.2) == .success,
              let image = imageResult.get() else {
            cachedSCWindow = nil
            cachedSCWindowPID = nil
            cachedSCWindowFrame = nil
            return nil
        }
        return CapturedWindow(image: image, pid: window.owningApplication?.processID,
                              frame: window.frame, onScreen: window.isOnScreen,
                              distance: frameDistance(window.frame, frame),
                              captureDurationMilliseconds: Int(Date().timeIntervalSince(screenshotStarted) * 1000),
                              discoveryDurationMilliseconds: discoveryMilliseconds)
    }

    private func legacyWindowCapture(pid: pid_t, matching frame: CGRect) -> CapturedWindow? {
        let captureStarted = Date()
        guard let candidate = visibleWindow(pid: pid, matching: frame),
              candidate.pid == pid, candidate.frame.width >= 400, candidate.frame.height >= 300,
              frameSizeIsPlausible(candidate.frame, relativeTo: frame),
              let image = CGWindowListCreateImage(.null, .optionIncludingWindow, candidate.id, [.bestResolution]) else {
            return nil
        }
        return CapturedWindow(image: image, pid: candidate.pid, frame: candidate.frame,
                              onScreen: true, distance: frameDistance(candidate.frame, frame),
                              captureDurationMilliseconds: Int(Date().timeIntervalSince(captureStarted) * 1000),
                              discoveryDurationMilliseconds: 0)
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

    private func crop(_ image: CGImage, to normalizedRect: CGRect) -> CGImage? {
        let rect = CGRect(
            x: floor(normalizedRect.minX * CGFloat(image.width)),
            y: floor((1 - normalizedRect.maxY) * CGFloat(image.height)),
            width: ceil(normalizedRect.width * CGFloat(image.width)),
            height: ceil(normalizedRect.height * CGFloat(image.height))
        ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !rect.isNull, !rect.isEmpty else { return nil }
        return image.cropping(to: rect)
    }

    private func mapBounds(_ bounds: CGRect, from normalizedRegion: CGRect) -> CGRect {
        VisionLayoutRegions.windowBounds(bounds, in: normalizedRegion)
    }

    private func frameSizeIsPlausible(_ candidate: CGRect, relativeTo expected: CGRect) -> Bool {
        guard expected.width > 0, expected.height > 0 else { return false }
        let widthRatio = candidate.width / expected.width
        let heightRatio = candidate.height / expected.height
        return (0.65...1.55).contains(widthRatio) && (0.65...1.55).contains(heightRatio)
    }

    private func emptySnapshot(pid: pid_t, crop: CGRect, state: VisionCaptureState) -> VisibleWeChatSnapshot {
        return VisibleWeChatSnapshot(
            title: nil, messages: [], captureState: state, captureSucceeded: false,
            capturedSize: nil, conversationCrop: crop,
            paneGeometry: VisionLayoutRegions.geometry(
                leftX: crop.minX, headerBottomY: VisionLayoutCalibration.current.headerBottomY,
                composerTopY: VisionLayoutCalibration.current.composerTopY,
                source: .configuredFallback, confidence: 0.40
            ),
            messagePaneLeftX: crop.minX,
            messageCrop: messageRegion(leftX: crop.minX),
            targetPID: pid, selectedWindowPID: nil,
            selectedWindowFrame: nil, selectedWindowOnScreen: false, windowFrameDistance: nil,
            windowDiscoveryDurationMilliseconds: 0, captureDurationMilliseconds: 0,
            visionDurationMilliseconds: 0,
            ocrObservationCount: 0, headerObservationCount: 0, headerCandidates: [],
            acceptedTitleBounds: nil, acceptedTitleConfidence: nil,
            titleIdentity: nil, titleRejectedAsMessageCount: 0, titleRejectedAsSentenceCount: 0,
            messageObservationCount: 0, messageBounds: [], rejectedMessageBounds: [],
            messageFingerprint: nil, messageFrameUnchanged: false,
            headerFingerprint: nil, headerFrameUnchanged: false,
            headerOCRDurationMilliseconds: 0, messageOCRDurationMilliseconds: 0,
            messageRecognitionLevel: "unavailable", fastOCRObservationCount: 0,
            accurateFallbackAttempted: false, accurateOCRObservationCount: 0,
            plausibleTextObservationCount: 0, geometryRejectedMessageCount: 0,
            timestampControlRejectedMessageCount: 0,
            wideCropFallbackAttempted: false, wideCropObservationCount: 0,
            wideCropFallbackSucceeded: false
        )
    }

    private func makeSnapshot(
        title: String?, messages: [ChatMessage], state: VisionCaptureState, pid: pid_t,
        image: CGImage, target: CapturedWindow, conversationCrop: CGRect? = nil,
        messageCrop: CGRect? = nil,
        paneGeometry: ConversationPaneGeometry? = nil,
        headerObservations: Int,
        headerCandidates: [VisionHeaderCandidate], acceptedTitleBounds: CGRect?, acceptedTitleConfidence: Float?,
        titleIdentity: VisionConversationIdentity?, titleRejectedAsMessageCount: Int,
        titleRejectedAsSentenceCount: Int,
        messageObservations: Int, messageBounds: [CGRect], rejectedMessageBounds: [CGRect],
        messageFingerprint: String? = nil, messageFrameUnchanged: Bool = false,
        headerFingerprint: String? = nil, headerFrameUnchanged: Bool = false,
        headerOCRDurationMilliseconds: Int = 0, messageOCRDurationMilliseconds: Int = 0,
        visionDurationMilliseconds: Int = 0,
        messagePaneLeftX: CGFloat? = nil,
        messageRecognitionLevel: String = "unavailable",
        fastOCRObservationCount: Int = 0,
        accurateFallbackAttempted: Bool = false,
        accurateOCRObservationCount: Int = 0,
        plausibleTextObservationCount: Int = 0,
        geometryRejectedMessageCount: Int = 0,
        timestampControlRejectedMessageCount: Int = 0,
        wideCropFallbackAttempted: Bool = false,
        wideCropObservationCount: Int = 0,
        wideCropFallbackSucceeded: Bool = false
    ) -> VisibleWeChatSnapshot {
        let calibration = VisionLayoutCalibration.current
        let resolvedGeometry = paneGeometry ?? VisionLayoutRegions.geometry(
            leftX: messagePaneLeftX ?? calibration.messagePaneLeftX,
            headerBottomY: calibration.headerBottomY, composerTopY: calibration.composerTopY,
            source: .configuredFallback, confidence: 0.40
        )
        return VisibleWeChatSnapshot(
            title: title, messages: messages, captureState: state, captureSucceeded: true,
            capturedSize: CGSize(width: image.width, height: image.height),
            conversationCrop: conversationCrop ?? self.conversationCropRatio(leftX: resolvedGeometry.leftX),
            paneGeometry: resolvedGeometry,
            messagePaneLeftX: resolvedGeometry.leftX,
            messageCrop: messageCrop ?? resolvedGeometry.messageRegion,
            targetPID: pid, selectedWindowPID: target.pid, selectedWindowFrame: target.frame,
            selectedWindowOnScreen: target.onScreen, windowFrameDistance: target.distance,
            windowDiscoveryDurationMilliseconds: target.discoveryDurationMilliseconds,
            captureDurationMilliseconds: target.captureDurationMilliseconds,
            visionDurationMilliseconds: visionDurationMilliseconds,
            ocrObservationCount: headerObservations + messageObservations,
            headerObservationCount: headerObservations, headerCandidates: headerCandidates,
            acceptedTitleBounds: acceptedTitleBounds, acceptedTitleConfidence: acceptedTitleConfidence,
            titleIdentity: titleIdentity, titleRejectedAsMessageCount: titleRejectedAsMessageCount,
            titleRejectedAsSentenceCount: titleRejectedAsSentenceCount,
            messageObservationCount: messageObservations,
            messageBounds: messageBounds, rejectedMessageBounds: rejectedMessageBounds,
            messageFingerprint: messageFingerprint, messageFrameUnchanged: messageFrameUnchanged,
            headerFingerprint: headerFingerprint, headerFrameUnchanged: headerFrameUnchanged,
            headerOCRDurationMilliseconds: headerOCRDurationMilliseconds,
            messageOCRDurationMilliseconds: messageOCRDurationMilliseconds,
            messageRecognitionLevel: messageRecognitionLevel,
            fastOCRObservationCount: fastOCRObservationCount,
            accurateFallbackAttempted: accurateFallbackAttempted,
            accurateOCRObservationCount: accurateOCRObservationCount,
            plausibleTextObservationCount: plausibleTextObservationCount,
            geometryRejectedMessageCount: geometryRejectedMessageCount,
            timestampControlRejectedMessageCount: timestampControlRejectedMessageCount,
            wideCropFallbackAttempted: wideCropFallbackAttempted,
            wideCropObservationCount: wideCropObservationCount,
            wideCropFallbackSucceeded: wideCropFallbackSucceeded
        )
    }

    private func perceptualFingerprint(_ image: CGImage, width: Int = 16, height: Int = 16) -> String? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let rendered = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(
                data: storage.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }
        return Data(pixels).base64EncodedString()
    }

    private func fingerprintDistance(_ lhs: String, _ rhs: String) -> Double {
        guard let left = Data(base64Encoded: lhs), let right = Data(base64Encoded: rhs),
              left.count == right.count, !left.isEmpty else { return .infinity }
        let totalDifference = zip(left, right).reduce(0) { partial, pair in
            partial + abs(Int(pair.0) - Int(pair.1))
        }
        return Double(totalDifference) / (Double(left.count) * 255)
    }

    private func rankHeaderCandidates(_ observations: [VNRecognizedTextObservation], region: CGRect) -> [RankedHeaderCandidate] {
        var candidates: [RankedHeaderCandidate] = []
        for observation in observations {
            guard let textCandidate = observation.topCandidates(1).first else { continue }
            let text = WeChatParsing.normalizeChatTitle(textCandidate.string)
            let bounds = mapBounds(observation.boundingBox, from: region)
            // Vision has already limited this request to the resolved title ROI.
            // Avoid a second strict box filter here: it discarded valid titles
            // when glyphs touched the edge of the header or pane.
            guard !text.isEmpty, text.count <= 36 else { continue }
        let generic = isHeaderControl(text, bounds: bounds, region: region)
        let expectedY = region.minY + region.height * 0.64
        let paneX = (bounds.minX - region.minX) / max(0.01, region.width)
        let compact = text.count <= 24 && bounds.width <= min(0.48, region.width * 0.65) && paneX <= 0.65 &&
                bounds.height >= 0.008 && bounds.height <= 0.075 &&
                bounds.midY >= region.minY + region.height * 0.35
        let plausible = textCandidate.confidence >= 0.35 && compact && !generic
        let yScore = 1 - min(1, abs(bounds.midY - expectedY) / max(0.025, region.height * 0.58))
        // Rank relative to the resolved conversation pane, never the window's
        // global left edge where the session list and search control live.
        let xScore = 1 - min(1, abs(paneX - 0.08) / 0.55)
            let compactnessScore = 1 - min(1, bounds.width / 0.48)
            let sentenceLike = isLikelySentenceLikeTitle(text, bounds: bounds)
            let sentencePenalty = sentenceLike ? 3.5 : 0
            let genericPenalty = generic ? 10.0 : 0
            let score = Double(yScore) * 6 + Double(xScore) * 1.5 +
                Double(compactnessScore) + Double(textCandidate.confidence) * 0.4 -
                sentencePenalty - genericPenalty
            candidates.append(RankedHeaderCandidate(
                text: text,
                score: score,
                diagnostic: VisionHeaderCandidate(
                    bounds: bounds,
                    confidence: textCandidate.confidence,
                    characterCount: text.count,
                    accepted: false,
                    rejection: generic ? "generic control" : (plausible ? nil : "geometry/confidence")
                ),
                plausible: plausible,
                sentenceLike: sentenceLike
            ))
        }
        candidates.sort { $0.score > $1.score }
        return candidates
    }

    private func selectHeaderCandidate(_ candidates: [RankedHeaderCandidate], messageTexts: [String],
                                       region: CGRect) -> TitleSelection {
        var updated = candidates
        var rejectedAsMessage = 0
        var rejectedAsSentence = 0
        for index in updated.indices where updated[index].plausible {
            if messageTexts.contains(where: { WeChatParsing.titleMatchesMessage(updated[index].text, message: $0) }) {
                rejectedAsMessage += 1
                updated[index].diagnostic = updated[index].diagnostic.rejected("matches chat text")
                continue
            }
            let nearBottom = updated[index].diagnostic.bounds.midY <
                region.minY + region.height * 0.38
            if updated[index].sentenceLike && nearBottom {
                rejectedAsSentence += 1
                updated[index].diagnostic = updated[index].diagnostic.rejected("sentence-like / low in header")
                continue
            }
            updated[index].diagnostic = updated[index].diagnostic.acceptedCopy()
            break
        }
        return TitleSelection(candidates: updated, rejectedAsMessageCount: rejectedAsMessage,
                              rejectedAsSentenceCount: rejectedAsSentence)
    }

    private func isLikelySentenceLikeTitle(_ text: String, bounds: CGRect) -> Bool {
        let hasSentencePunctuation = text.rangeOfCharacter(from: CharacterSet(charactersIn: "?？!！。；;，,")) != nil
        let longAndWide = text.count >= 12 && bounds.width >= 0.28
        return (hasSentencePunctuation && text.count >= 5) || longAndWide
    }

    private func isHeaderControl(_ text: String, bounds: CGRect, region: CGRect) -> Bool {
        let normalized = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter { !$0.isWhitespace && !$0.isPunctuation }
        let controls = [
            "wechat", "wechat(chats)", "wechat(contacts)", "weixin", "微信", "微信聊天",
            "search", "qsearch", "搜索", "chats", "聊天", "contacts", "通讯录", "discover", "发现",
            "moments", "朋友圈", "settings", "设置", "more", "更多"
        ]
        if controls.contains(normalized) { return true }
        let paneX = (bounds.midX - region.minX) / max(0.01, region.width)
        let looksLikeSearchControl = paneX >= 0.58 && normalized.contains("search")
        return looksLikeSearchControl || (paneX >= 0.58 && normalized.contains("搜索"))
    }

    func diagnosticReport(pid: pid_t, windowFrame: CGRect) -> String {
        let snapshot = read(pid: pid, windowFrame: windowFrame, forceFresh: true)
        let size = snapshot.capturedSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "unavailable"
        let crop = snapshot.conversationCrop
        let headerRegion = snapshot.paneGeometry.headerRegion
        let messageRegion = snapshot.paneGeometry.messageRegion
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
            "Window discovery stage ms: \(snapshot.windowDiscoveryDurationMilliseconds)",
            "Screenshot stage ms: \(snapshot.captureDurationMilliseconds)",
            "Vision stage ms: \(snapshot.visionDurationMilliseconds)",
            "Captured size: \(size)",
            "Conversation crop ratio: x=\(ratio(crop.minX)) y=\(ratio(crop.minY)) width=\(ratio(crop.width)) height=\(ratio(crop.height))",
            "Pane geometry: source=\(snapshot.paneGeometry.source.rawValue) confidence=\(String(format: "%.2f", snapshot.paneGeometry.confidence)) leftX=\(ratio(snapshot.paneGeometry.leftX))",
            "Header search ratio: x=\(ratio(headerRegion.minX)) y=\(ratio(headerRegion.minY)) width=\(ratio(headerRegion.width)) height=\(ratio(headerRegion.height))",
            "Message region ratio: x=\(ratio(messageRegion.minX)) y=\(ratio(messageRegion.minY)) width=\(ratio(messageRegion.width)) height=\(ratio(messageRegion.height))",
            "Message OCR accepted inside pane: \(snapshot.messages.count)",
            "messagePaneLeftX: \(ratio(snapshot.messagePaneLeftX))",
            "Message OCR level: \(snapshot.messageRecognitionLevel)",
            "Fast OCR observations: \(snapshot.fastOCRObservationCount)",
            "Accurate fallback attempted: \(snapshot.accurateFallbackAttempted)",
            "Accurate OCR observations: \(snapshot.accurateOCRObservationCount)",
            "Plausible text observations: \(snapshot.plausibleTextObservationCount)",
            "Geometry rejected: \(snapshot.geometryRejectedMessageCount)",
            "Timestamp/control rejected: \(snapshot.timestampControlRejectedMessageCount)",
            "Wide crop fallback: attempted=\(snapshot.wideCropFallbackAttempted) observations=\(snapshot.wideCropObservationCount) succeeded=\(snapshot.wideCropFallbackSucceeded)",
            "Message fingerprint: \(snapshot.messageFingerprint == nil ? "unavailable" : (snapshot.messageFrameUnchanged ? "unchanged" : "changed"))",
            "headerBottomY: \(ratio(VisionLayoutCalibration.current.headerBottomY))",
            "composerTopY: \(ratio(VisionLayoutCalibration.current.composerTopY))",
            "Sidebar OCR observations: 0 (excluded by message-pane crop)",
            "Composer OCR observations: 0 (excluded by message ROI)",
            "OCR observations total: \(snapshot.ocrObservationCount)",
            "Header-region observations: \(snapshot.headerObservationCount)",
            "Header candidates after filtering: \(snapshot.headerCandidates.count)",
            "Title candidates rejected as chat text: \(snapshot.titleRejectedAsMessageCount)",
            "Title candidates rejected as sentence-like: \(snapshot.titleRejectedAsSentenceCount)",
            "Accepted title: \(snapshot.title == nil ? "no" : "yes")",
            "Raw OCR line count: \(snapshot.messageObservationCount)",
            "Grouped message blocks: \(snapshot.messages.count)",
            "Rejected message candidates: \(snapshot.rejectedMessageBounds.count)",
            "Grouped senders: me=\(snapshot.messages.filter { $0.sender == .me }.count) target=\(snapshot.messages.filter { $0.sender == .other }.count) unknown=\(snapshot.messages.filter { $0.sender == .unknown }.count)",
            "Header/message ROI overlap: \(!headerRegion.intersection(messageRegion).isNull && !headerRegion.intersection(messageRegion).isEmpty)",
            "Accepted title confidence: \(snapshot.acceptedTitleConfidence.map { String(format: "%.3f", $0) } ?? "unavailable")"
        ]
        if let bounds = snapshot.acceptedTitleBounds {
            lines.append("Accepted title bbox size: width=\(ratio(bounds.width)) height=\(ratio(bounds.height))")
            lines.append("Accepted title vertical position: centerY=\(ratio(bounds.midY))")
        }
        for (index, candidate) in snapshot.headerCandidates.enumerated() {
            lines.append("Header candidate \(index + 1): bbox=\(rectDescription(candidate.bounds)) confidence=\(String(format: "%.3f", candidate.confidence)) characters=\(candidate.characterCount) accepted=\(candidate.accepted) rejection=\(candidate.rejection ?? "none")")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func annotatedPreview(pid: pid_t, windowFrame: CGRect) -> NSImage? {
        let key = "\(pid):\(Int(windowFrame.origin.x)): \(Int(windowFrame.origin.y)): \(Int(windowFrame.width)): \(Int(windowFrame.height))"
        cacheCondition.lock()
        while captureInProgress { cacheCondition.wait() }
        captureInProgress = true
        cacheCondition.unlock()

        let result = capture(pid: pid, windowFrame: windowFrame, mode: .full, forceFresh: true)
        cacheCondition.lock()
        cachedKey = key
        cachedSnapshot = result.snapshot
        cachedAt = Date()
        captureInProgress = false
        cacheCondition.broadcast()
        cacheCondition.unlock()
        guard let source = result.image, result.snapshot.captureSucceeded else { return nil }

        let size = NSSize(width: source.width, height: source.height)
        let image = NSImage(cgImage: source, size: size)
        image.lockFocus()
        let cropX = size.width * result.snapshot.messagePaneLeftX
        NSColor.systemBlue.setStroke()
        let paneBoundary = NSBezierPath()
        paneBoundary.move(to: NSPoint(x: cropX, y: 0))
        paneBoundary.line(to: NSPoint(x: cropX, y: size.height))
        paneBoundary.stroke()
        NSColor.systemYellow.setStroke()
        visionRect(result.snapshot.paneGeometry.headerRegion, size: size).stroke()
        NSColor.systemGreen.setStroke()
        visionRect(result.snapshot.paneGeometry.messageRegion, size: size).stroke()
        NSColor.systemOrange.setStroke()
        visionRect(CGRect(x: 0, y: 0, width: 1, height: VisionLayoutCalibration.current.composerTopY),
                   size: size).stroke()
        NSColor.systemPurple.setStroke()
        for candidate in result.snapshot.headerCandidates where !candidate.accepted {
            visionRect(candidate.bounds, size: size).stroke()
        }
        NSColor.systemRed.setStroke()
        if let titleBounds = result.snapshot.acceptedTitleBounds {
            visionRect(titleBounds, size: size).stroke()
        }
        NSColor.systemGreen.setStroke()
        for bounds in result.snapshot.messageBounds {
            visionRect(bounds, size: size).stroke()
        }
        NSColor.gray.setStroke()
        for bounds in result.snapshot.rejectedMessageBounds {
            visionRect(bounds, size: size).stroke()
        }
        image.unlockFocus()
        return image
    }

    private func visionRect(_ rect: CGRect, size: NSSize) -> NSBezierPath {
        NSBezierPath(rect: NSRect(
            x: rect.minX * size.width,
            y: rect.minY * size.height,
            width: rect.width * size.width,
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

    private func plausibleMessageGeometry(_ bounds: CGRect, in region: CGRect) -> Bool {
        guard bounds.width >= 0.008, bounds.width <= 0.88,
              bounds.height >= 0.006, bounds.height <= 0.10 else { return false }
        let leftMargin = bounds.minX - region.minX
        let rightMargin = region.maxX - bounds.maxX
        let leftAnchored = leftMargin <= 0.25 && bounds.midX < region.midX + 0.06
        let rightAnchored = rightMargin <= 0.25 && bounds.midX > region.midX - 0.06
        return leftAnchored || rightAnchored
    }

    private func parseMessageObservations(_ observations: [VNRecognizedTextObservation],
                                         region: CGRect) -> ParsedMessageCapture {
        var rejectedBounds: [CGRect] = []
        var lines: [RecognizedMessageLine] = []
        var plausibleTextCount = 0
        var geometryRejectedCount = 0
        var timestampControlRejectedCount = 0
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else {
                rejectedBounds.append(mapBounds(observation.boundingBox, from: region))
                continue
            }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard WeChatParsing.isPlausibleChatText(text, confidence: candidate.confidence) else {
                rejectedBounds.append(mapBounds(observation.boundingBox, from: region))
                continue
            }
            plausibleTextCount += 1
            let bounds = mapBounds(observation.boundingBox, from: region)
            guard bounds.minX >= region.minX, bounds.minY >= region.minY,
                  bounds.maxY <= region.maxY, bounds.maxX <= region.maxX,
                  plausibleMessageGeometry(bounds, in: region) else {
                geometryRejectedCount += 1
                rejectedBounds.append(bounds)
                continue
            }
            guard !looksLikeTimestampOrControl(text) else {
                timestampControlRejectedCount += 1
                rejectedBounds.append(bounds)
                continue
            }
            lines.append(RecognizedMessageLine(text: text, bounds: bounds,
                                               confidence: candidate.confidence))
        }
        let (messages, bounds) = groupMessageLines(lines, region: region)
        return ParsedMessageCapture(messages: messages, bounds: bounds,
                                    rejectedBounds: rejectedBounds,
                                    plausibleTextCount: plausibleTextCount,
                                    geometryRejectedCount: geometryRejectedCount,
                                    timestampControlRejectedCount: timestampControlRejectedCount)
    }

    private func recognizeMessageImage(_ image: CGImage,
                                       level: VNRequestTextRecognitionLevel) -> MessageOCRCapture {
        let started = Date()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = level == .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.minimumTextHeight = 0.008
        let succeeded = (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil
        return MessageOCRCapture(observations: request.results ?? [], succeeded: succeeded,
                                 durationMilliseconds: Int(Date().timeIntervalSince(started) * 1000))
    }

    private func messageRecognitionLevelName(_ level: VNRequestTextRecognitionLevel) -> String {
        level == .fast ? "fast" : "accurate"
    }

    /// Main WeChat draws a steady vertical split between its conversation list
    /// and transcript. Use it only when AX did not provide pane geometry.
    private func visualConversationDivider(in image: CGImage) -> CGFloat? {
        guard let providerData = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(providerData) else { return nil }
        let bytesPerPixel = image.bitsPerPixel / 8
        guard image.bitsPerComponent == 8, bytesPerPixel >= 3,
              image.bytesPerRow >= image.width * bytesPerPixel,
              CFDataGetLength(providerData) >= image.bytesPerRow * image.height else { return nil }
        let yStart = Int(CGFloat(image.height) * 0.20)
        let yEnd = Int(CGFloat(image.height) * 0.84)
        let yStep = max(5, (yEnd - yStart) / 72)
        let minX = max(3, Int(CGFloat(image.width) * 0.18))
        let maxX = min(image.width - 3, Int(CGFloat(image.width) * 0.55))
        guard maxX > minX else { return nil }

        func brightness(_ x: Int, _ y: Int) -> CGFloat {
            let offset = y * image.bytesPerRow + x * bytesPerPixel
            return (CGFloat(bytes[offset]) + CGFloat(bytes[offset + 1]) + CGFloat(bytes[offset + 2])) / 765
        }

        var bestX = 0
        var bestScore: CGFloat = 0
        var bestSupport: CGFloat = 0
        for x in minX...maxX {
            var total: CGFloat = 0
            var supported = 0
            var samples = 0
            for y in stride(from: yStart, to: yEnd, by: yStep) {
                let contrast = abs(brightness(x - 1, y) - brightness(x + 1, y))
                total += contrast
                if contrast >= 0.12 { supported += 1 }
                samples += 1
            }
            let score = total / CGFloat(max(1, samples))
            let support = CGFloat(supported) / CGFloat(max(1, samples))
            if score > bestScore {
                bestX = x
                bestScore = score
                bestSupport = support
            }
        }
        guard bestScore >= 0.055, bestSupport >= 0.52 else { return nil }
        return CGFloat(bestX) / CGFloat(image.width)
    }

    private func groupMessageLines(_ lines: [RecognizedMessageLine], region: CGRect) -> ([ChatMessage], [CGRect]) {
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
                let previousSide = WeChatParsing.messageSide(previous.bounds, in: region)
                let lineSide = WeChatParsing.messageSide(line.bounds, in: region)
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
            let sender = WeChatParsing.messageSide(bubble.bounds, in: region)
            let normalizedText = bubble.text
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let senderKey = senderKey(for: sender)
            // Order within this transient OCR snapshot distinguishes repeated
            // identical bubbles while remaining stable as bubbles shift vertically.
            let snapshotKey = "vision:\(senderKey):\(normalizedText):order\(index)"
            let confidence = bubble.lines.map(\.confidence).reduce(0, +) / Float(max(1, bubble.lines.count))
            return ChatMessage(text: bubble.text, sender: sender, allowsAutomaticAnalysis: false,
                               id: snapshotKey, source: .vision, confidence: confidence)
        }
        return (messages, bubbles.map(\.bounds))
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

private struct ParsedMessageCapture {
    let messages: [ChatMessage]
    let bounds: [CGRect]
    let rejectedBounds: [CGRect]
    let plausibleTextCount: Int
    let geometryRejectedCount: Int
    let timestampControlRejectedCount: Int
}

private struct MessageOCRCapture {
    let observations: [VNRecognizedTextObservation]
    let succeeded: Bool
    let durationMilliseconds: Int
}

private struct CapturedWindow {
    let image: CGImage
    let pid: pid_t?
    let frame: CGRect
    let onScreen: Bool
    let distance: CGFloat
    let captureDurationMilliseconds: Int
    let discoveryDurationMilliseconds: Int
}

private enum VisionReadMode: Equatable {
    case titleOnly
    case messagesFast
    case messagesAccurate
    case full
    case fullFast

    var readsTitle: Bool { self == .titleOnly || self == .full || self == .fullFast }
    var readsMessages: Bool { self != .titleOnly }
    var messageRecognitionLevel: VNRequestTextRecognitionLevel {
        self == .messagesFast || self == .fullFast ? .fast : .accurate
    }
    var captureScale: CGFloat { self == .messagesFast ? 1.25 : 1.5 }
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
    let sentenceLike: Bool
}

private struct TitleSelection {
    let candidates: [RankedHeaderCandidate]
    let rejectedAsMessageCount: Int
    let rejectedAsSentenceCount: Int
}

private extension VisionHeaderCandidate {
    func rejected(_ reason: String) -> VisionHeaderCandidate {
        VisionHeaderCandidate(bounds: bounds, confidence: confidence, characterCount: characterCount,
                              accepted: false, rejection: reason)
    }

    func acceptedCopy() -> VisionHeaderCandidate {
        VisionHeaderCandidate(bounds: bounds, confidence: confidence, characterCount: characterCount,
                              accepted: true, rejection: nil)
    }
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
