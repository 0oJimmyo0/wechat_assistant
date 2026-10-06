import Foundation

struct AvailableModel: Identifiable, Decodable, Hashable {
    let slug: String
    let displayName: String
    let visibility: String?
    var id: String { slug }

    enum CodingKeys: String, CodingKey { case slug, displayName = "display_name", visibility }
}

struct ModelCatalog: Decodable { let models: [AvailableModel] }

struct ReplyCandidate: Identifiable, Codable, Equatable {
    enum Style: String, Codable, CaseIterable, Identifiable {
        case recommended = "Recommended", softer = "Softer", shorter = "Shorter"
        var id: String { rawValue }
    }
    let style: Style
    let text: String
    var id: Style { style }
}

struct ReplySuggestion: Codable, Equatable {
    let situation: String
    let caution: String?
    let replies: [ReplyCandidate]
}

enum CopilotError: LocalizedError {
    case notSignedIn, missingPermission, noModels, invalidResponse, streamIncomplete, usageLimitExceeded, service(String)
    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Sign in with ChatGPT to generate suggestions."
        case .missingPermission: "This ChatGPT account has not authorized plan usage. Sign in again and grant the requested access."
        case .noModels: "No models are available for this ChatGPT account."
        case .invalidResponse: "The model response did not contain three valid reply candidates. Regenerate to try again."
        case .streamIncomplete: "The response stream ended before completion. Please try again."
        case .usageLimitExceeded: "ChatGPT plan usage limit reached. Check ChatGPT Settings → Usage before trying again."
        case .service(let message): message
        }
    }
}
