import Foundation
import Combine

@MainActor
final class RelationshipProfileStore: ObservableObject {
    @Published var profile: RelationshipProfile { didSet { save() } }
    private let key = "relationship_profile_v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: key), let value = try? JSONDecoder().decode(RelationshipProfile.self, from: data) {
            profile = value
        } else {
            profile = RelationshipProfile()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
