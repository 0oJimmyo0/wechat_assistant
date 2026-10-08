import Foundation
@main enum ConversationMonitoringTests {
    static func main() {
        func row(_ text: String, _ sender: MessageSender = .other) -> ChatMessage { ChatMessage(text: text, sender: sender) }
        let store = ConversationStore()
        _ = store.merge([row("A"), row("B")], trust: .validated, liveEdgeState: true)
        let result = store.merge([row("A"),row("B"),row("repeat"),row("repeat"),row("self",.me),row("unknown",.unknown)], trust: .validated, liveEdgeState: true)
        let incoming = ConversationArrivalPolicy.incoming(result,liveObservation: true,previouslyObservingLive: true,identityConfirmed: true)
        expect(incoming.count == 2 && Set(incoming.map(\.localID)).count == 2,"identical incoming occurrences count separately once")
        for manual in [false] {
            expect(ConversationArrivalPolicy.incoming(result,liveObservation: manual,previouslyObservingLive: true,identityConfirmed: true).isEmpty,"Refresh and history backfill cannot emit arrival events")
        }
        expect(ConversationArrivalPolicy.incoming(result,liveObservation: true,previouslyObservingLive: false,identityConfirmed: true).isEmpty,"returning from history cannot imply arrival")
        expect(ConversationArrivalPolicy.incoming(result,liveObservation: true,previouslyObservingLive: true,identityConfirmed: false).isEmpty,"uncertain contact cannot emit arrival")
        let refresh = store.merge(store.messages,trust: .validated,liveEdgeState: true)
        expect(ConversationArrivalPolicy.incoming(refresh,liveObservation: true,previouslyObservingLive: true,identityConfirmed: true).isEmpty,"unchanged watchdog observation cannot repeat incoming occurrence")
        let scrolled = store.merge(store.messages,trust: .validated,liveEdgeState: false)
        expect(scrolled.viewport == .historical,"unchanged text still updates changed viewport evidence")
        expect(ConversationMonitoringState.resolve(running: true,identityConfirmed: true,transcriptTrusted: true,viewport: .liveTail,liveEdge: nil) == .uncertain,"missing scrollbar cannot claim observable live tail")
        expect(ConversationMonitoringState.resolve(running: true,identityConfirmed: true,transcriptTrusted: true,viewport: .historical,liveEdge: false) == .viewingHistory,"WeChat history explicitly pauses live observation")
        expect(ConversationMonitoringState.resolve(running: true,identityConfirmed: true,transcriptTrusted: true,viewport: .liveTail,liveEdge: true) == .live,"verified latest viewport reports live")
        expect(ConversationMonitoringState.resolve(running: false,identityConfirmed: true,transcriptTrusted: true,viewport: .liveTail,liveEdge: true) == .paused,"deactivation cannot show live status")
        print("All monitoring and arrival-policy checks passed.")
    }
    static func expect(_ condition: @autoclosure () -> Bool, _ label: String) { if !condition() { fputs("FAILED: \(label)\n",stderr); exit(1) } }
}
