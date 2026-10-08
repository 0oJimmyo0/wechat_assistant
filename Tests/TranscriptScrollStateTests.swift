import Foundation
import CoreGraphics
@main enum TranscriptScrollStateTests {
    static func main() {
        let a = UUID(), b = UUID(), c = UUID(), older = UUID(), incoming = UUID()
        var state = TranscriptScrollState()
        state.observe(frames: [a: CGRect(x: 0, y: -30, width: 100, height: 80), b: CGRect(x: 0, y: 60, width: 100, height: 80)], viewportHeight: 200, latestVisible: false)
        expect(state.reconcile(previous: [a,b,c], current: [older,a,b,c], newIncoming: []) == .anchor(a,-30), "prepend restores actual visible anchor including partial-row offset")
        expect(state.reconcile(previous: [older,a,b,c], current: [older,a,b,c,incoming], newIncoming: [incoming]) == .none, "new tail message does not scroll history reader")
        expect(state.unreadIDs == [incoming], "new incoming occurrence counted once")
        _ = state.reconcile(previous: [older,a,b,c,incoming], current: [older,a,b,c,incoming], newIncoming: [incoming])
        expect(state.unreadIDs.count == 1, "unchanged Refresh cannot duplicate unread occurrence")
        state.jumpToLatest()
        expect(state.unreadIDs.isEmpty && state.viewingLatest, "jump clears local unread indicator")
        state.observe(frames: [a: CGRect(x: 0,y: -15,width: 100,height: 50)], viewportHeight: 200, latestVisible: false)
        _ = state.reconcile(previous: [a,b,c,incoming], current: [a,b,c,incoming], newIncoming: [incoming])
        expect(state.unreadIDs.isEmpty, "returning to history cannot resurrect an already-read incoming badge")
        state.jumpToLatest()
        expect(state.reconcile(previous: [a,b], current: [a,b,c], newIncoming: [c]) == .latest, "latest reader follows growing tail")
        state.observe(frames: [a: CGRect(x: 0,y: -15,width: 100,height: 50)], viewportHeight: 200, latestVisible: false)
        expect(state.reconcile(previous: [older,a,b], current: [a,b,c], newIncoming: []) == .anchor(a,-15), "memory cap preserves still-retained visible anchor")
        let delayed = UUID()
        _ = state.reconcile(previous: [a,b], current: [a,b], newIncoming: [delayed])
        _ = state.reconcile(previous: [a,b], current: [a,b,delayed], newIncoming: [delayed])
        expect(state.unreadIDs == [delayed], "arrival publication preceding row publication is counted when row becomes available")
        print("All local transcript scroll-state checks passed.")
    }
    static func expect(_ condition: @autoclosure () -> Bool, _ label: String) { if !condition() { fputs("FAILED: \(label)\n",stderr); exit(1) } }
}
