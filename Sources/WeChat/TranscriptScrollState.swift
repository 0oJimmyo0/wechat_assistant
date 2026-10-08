import Foundation
import CoreGraphics

/// Session-only local UI state. It never controls WeChat's viewport.
struct TranscriptScrollState {
    enum Intent: Equatable { case none, latest, anchor(UUID, CGFloat) }
    private(set) var viewingLatest = true
    private(set) var anchor: UUID?
    private(set) var anchorOffset: CGFloat = 0
    private(set) var unreadIDs: Set<UUID> = []
    private var handledIncomingIDs: Set<UUID> = []

    mutating func observe(frames: [UUID: CGRect], viewportHeight: CGFloat, latestVisible: Bool) {
        viewingLatest = latestVisible
        if latestVisible { unreadIDs.removeAll() }
        if let visible = frames.filter({ $0.value.maxY > 0 && $0.value.minY < viewportHeight })
            .min(by: { $0.value.minY < $1.value.minY }) {
            anchor = visible.key
            anchorOffset = visible.value.minY
        }
    }

    mutating func reconcile(previous: [UUID], current: [UUID], newIncoming: [UUID]) -> Intent {
        unreadIDs.formIntersection(current)
        handledIncomingIDs.formIntersection(current)
        let fresh = newIncoming.filter { current.contains($0) && !handledIncomingIDs.contains($0) }
        if !viewingLatest { unreadIDs.formUnion(fresh) }
        handledIncomingIDs.formUnion(fresh)
        guard previous != current else { return .none }
        if previous.isEmpty || viewingLatest { return .latest }
        // Preserve a visible row when prepending or evicting the head at the cap.
        if previous.first != current.first, let anchor, current.contains(anchor) {
            return .anchor(anchor, anchorOffset)
        }
        return .none
    }

    mutating func jumpToLatest() {
        viewingLatest = true
        unreadIDs.removeAll()
    }
}
