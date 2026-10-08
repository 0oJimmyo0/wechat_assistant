/// Pending captures are candidates, never replacements for a locked chat's history.
enum PendingIdentityPolicy {
    static func displayedMessages<Message>(validated: [Message], pending: [Message],
        hasLockedContact: Bool) -> [Message] {
        hasLockedContact ? validated : Array(pending.suffix(50))
    }
}
