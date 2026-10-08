import Foundation
import CoreGraphics

struct VisionTimeSeparatorObservation {
    let label: String
    let bounds: CGRect
    let confidence: Float
}

enum TimeSeparatorPlacement {
    static func associate(_ separators: [VisionTimeSeparatorObservation], messages: [ChatMessage],
        bounds: [CGRect], allBubbleBounds: [CGRect]) -> [ChatMessage] {
        guard messages.count == bounds.count else { return messages }
        var result = messages
        for separator in separators.sorted(by: { $0.bounds.midY > $1.bounds.midY }) {
            guard separator.confidence >= 0.90,
                  WeChatParsing.timeSeparatorLabel(separator.label) != nil,
                  let firstBubble = allBubbleBounds.filter({ $0.maxY <= separator.bounds.minY })
                    .max(by: { $0.maxY < $1.maxY }),
                  separator.bounds.minY - firstBubble.maxY < 0.09,
                  let index = bounds.firstIndex(of: firstBubble),
                  result[index].timeSeparatorBefore == nil else { continue }
            // Do not skip an unreadable/clipped bubble and move its divider to
            // a later readable message. The next bubble must itself be accepted.
            result[index] = result[index].withTimeSeparator(separator.label, source: .vision,
                confidence: separator.confidence)
        }
        return result
    }
}
