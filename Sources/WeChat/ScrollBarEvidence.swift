import Foundation

/// Numeric evidence from the verified transcript's vertical scrollbar only.
enum ScrollBarEvidence {
    static func liveEdge(value: Double?, minimum: Double?, maximum: Double?,
        role: String?, orientation: String?) -> Bool? {
        guard role == "AXScrollBar", orientation == "AXVerticalOrientation",
              let value, value.isFinite else { return nil }
        let position: Double
        if minimum != nil || maximum != nil {
            guard let minimum, let maximum, minimum.isFinite, maximum.isFinite,
                  maximum > minimum else { return nil }
            position = (value - minimum) / (maximum - minimum)
        } else {
            // Native AppKit scrollers expose their normalized position without
            // AXMinValue/AXMaxValue on some WeChat builds. Role and orientation
            // are required; arbitrary numeric controls cannot establish a tail.
            position = value
        }
        guard position.isFinite, (0...1).contains(position) else { return nil }
        // Nearly at the bottom is still history. Only endpoint rounding is tolerated.
        return position >= 1 - 0.000001
    }
}
