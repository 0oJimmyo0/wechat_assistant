import Foundation

struct VisionConversationIdentity: Sendable, Equatable {
    let normalizedTitle: String
    let titleCenterX: CGFloat
    let titleCenterY: CGFloat
    let titleWidth: CGFloat
    let confidence: Float

    func textMatches(_ other: VisionConversationIdentity) -> Bool {
        normalizedTitle == other.normalizedTitle
    }

    func geometryError(with other: VisionConversationIdentity) -> CGFloat {
        abs(titleCenterX - other.titleCenterX) / 0.025 +
            abs(titleCenterY - other.titleCenterY) / 0.025 +
            abs(titleWidth - other.titleWidth) / 0.05
    }

    func geometryIsConsistent(with other: VisionConversationIdentity) -> Bool {
        abs(titleCenterX - other.titleCenterX) <= 0.025 &&
            abs(titleCenterY - other.titleCenterY) <= 0.025 &&
            abs(titleWidth - other.titleWidth) <= 0.05
    }

    func isSpatiallyConsistent(with other: VisionConversationIdentity) -> Bool {
        textMatches(other) && geometryIsConsistent(with: other) &&
            confidence >= 0.35 && other.confidence >= 0.35
    }
}

struct VisionTitlePair: Sendable {
    let firstIndex: Int
    let secondIndex: Int
    let combinedConfidence: Float
    let geometryError: CGFloat
    let score: Double
}

struct VisionTitlePairEvaluation: Sendable {
    let firstIndex: Int
    let secondIndex: Int
    let hasBothIdentities: Bool
    let textMatches: Bool
    let geometryMatches: Bool
    let confidenceEligible: Bool
    let combinedConfidence: Float
    let geometryError: CGFloat
    let pair: VisionTitlePair?

    var diagnosticResult: String {
        guard hasBothIdentities else { return "missing identity" }
        var reasons: [String] = []
        if !textMatches { reasons.append("text mismatch") }
        if !geometryMatches { reasons.append("geometry mismatch") }
        if !confidenceEligible { reasons.append("confidence below threshold") }
        return reasons.isEmpty ? "match" : reasons.joined(separator: ", ")
    }
}

struct VisionTitleConsensusResult: Sendable {
    let evaluations: [VisionTitlePairEvaluation]
    let bestPair: VisionTitlePair?
    let diagnostic: String
}

enum VisionTitleConsensus {
    static func evaluate(_ identities: [VisionConversationIdentity?],
                         minimumConfidence: Float = 0.35) -> VisionTitleConsensusResult {
        var evaluations: [VisionTitlePairEvaluation] = []
        for firstIndex in identities.indices {
            for secondIndex in identities.indices where secondIndex > firstIndex {
                let first = identities[firstIndex]
                let second = identities[secondIndex]
                guard let first, let second else {
                    evaluations.append(VisionTitlePairEvaluation(
                        firstIndex: firstIndex, secondIndex: secondIndex,
                        hasBothIdentities: false, textMatches: false, geometryMatches: false,
                        confidenceEligible: false, combinedConfidence: 0, geometryError: .greatestFiniteMagnitude,
                        pair: nil
                    ))
                    continue
                }
                let textMatches = first.textMatches(second)
                let geometryMatches = first.geometryIsConsistent(with: second)
                let confidenceEligible = first.confidence >= minimumConfidence && second.confidence >= minimumConfidence
                let combinedConfidence = first.confidence + second.confidence
                let geometryError = first.geometryError(with: second)
                let pair: VisionTitlePair? = textMatches && geometryMatches && confidenceEligible
                    ? VisionTitlePair(firstIndex: firstIndex, secondIndex: secondIndex,
                                      combinedConfidence: combinedConfidence, geometryError: geometryError,
                                      score: Double(combinedConfidence) - Double(geometryError) * 0.05)
                    : nil
                evaluations.append(VisionTitlePairEvaluation(
                    firstIndex: firstIndex, secondIndex: secondIndex, hasBothIdentities: true,
                    textMatches: textMatches, geometryMatches: geometryMatches,
                    confidenceEligible: confidenceEligible, combinedConfidence: combinedConfidence,
                    geometryError: geometryError, pair: pair
                ))
            }
        }

        let bestPair = evaluations.compactMap(\.pair).max { lhs, rhs in
            if abs(lhs.score - rhs.score) > 0.000001 { return lhs.score < rhs.score }
            if abs(lhs.geometryError - rhs.geometryError) > 0.000001 { return lhs.geometryError > rhs.geometryError }
            return lhs.secondIndex < rhs.secondIndex
        }
        let confidenceValues = identities.compactMap { $0?.confidence }
        let confidenceRange: String
        if let minimum = confidenceValues.min(), let maximum = confidenceValues.max() {
            confidenceRange = String(format: "%.3f–%.3f", minimum, maximum)
        } else {
            confidenceRange = "unavailable"
        }
        let validIdentityCount = identities.compactMap { $0 }.filter { $0.confidence >= minimumConfidence }.count
        let pairLines = evaluations.map {
            "Pair \($0.firstIndex + 1)-\($0.secondIndex + 1): \($0.diagnosticResult)"
        }
        let geometryMismatchCount = evaluations.filter { $0.hasBothIdentities && !$0.geometryMatches }.count
        let textMismatchCount = evaluations.filter { $0.hasBothIdentities && !$0.textMatches }.count
        let diagnostic = ([
            "Title observations: \(identities.count)",
            "Valid identities: \(validIdentityCount)",
            "Confidence range: \(confidenceRange)"
        ] + pairLines + [
            "Geometry mismatch count: \(geometryMismatchCount)",
            "Text mismatch count: \(textMismatchCount)"
        ]).joined(separator: "\n")
        return VisionTitleConsensusResult(evaluations: evaluations, bestPair: bestPair, diagnostic: diagnostic)
    }
}
