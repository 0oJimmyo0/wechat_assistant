import Foundation

enum ConversationMonitoringState: String {
    case paused = "Paused"
    case live = "Live"
    case viewingHistory = "Viewing WeChat history"
    case uncertain = "Monitoring uncertain"

    static func resolve(running: Bool, identityConfirmed: Bool, transcriptTrusted: Bool,
        viewport: ChatViewportState, liveEdge: Bool?) -> Self {
        guard running else { return .paused }
        guard identityConfirmed, transcriptTrusted, viewport != .uncertain else { return .uncertain }
        if viewport == .historical || liveEdge == false { return .viewingHistory }
        return liveEdge == true ? .live : .uncertain
    }
}

enum ConversationArrivalPolicy {
    static func incoming(_ result: ConversationMergeResult, liveObservation: Bool,
        previouslyObservingLive: Bool, identityConfirmed: Bool) -> [ChatMessage] {
        guard liveObservation, previouslyObservingLive, identityConfirmed,
              result.arrivalConfirmed, result.viewport == .liveTail else { return [] }
        return result.appended.filter { $0.sender == .other && $0.senderIdentified }
    }
}
