import Foundation
import CryptoKit
import Security

private struct ConversationArchive: Codable {
    var conversations: [StoredConversation]
}

private struct StoredConversation: Codable {
    let id: UUID
    let localIdentityKey: String
    var displayName: String?
    var messages: [StoredMessage]
    var updatedAt: Date
}

private struct StoredMessage: Codable {
    let id: String
    let text: String
    let sender: String
    let capturedAt: Date
    let source: MessageSource
    let confidence: Float?

    init(_ message: ChatMessage) {
        id = message.id
        text = message.text
        switch message.sender {
        case .me: sender = "me"
        case .other: sender = "other"
        case .unknown: sender = "unknown"
        }
        capturedAt = message.capturedAt
        source = message.source
        confidence = message.confidence
    }

    var chatMessage: ChatMessage {
        let messageSender: MessageSender
        switch sender {
        case "me": messageSender = .me
        case "other": messageSender = .other
        default: messageSender = .unknown
        }
        return ChatMessage(text: text, sender: messageSender, allowsAutomaticAnalysis: source == .accessibility,
                           id: id, capturedAt: capturedAt, source: source, confidence: confidence)
    }
}

/// Encrypts one bounded archive with an AES-GCM key kept in this Mac's Keychain.
/// No screenshots, plaintext sidecars, or contact names are used in filesystem paths.
final class ConversationStore {
    static let shared = ConversationStore()
    static let storageEnabledKey = "conversation_storage_enabled"

    private let lock = NSLock()
    private let keychainService: String
    private let keychainAccount: String
    private let maxMessagesPerConversation = 500
    private let retentionInterval: TimeInterval = 30 * 24 * 60 * 60

    private let archiveURL: URL

    private static var defaultArchiveURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WeChatReplyCopilot", isDirectory: true)
            .appendingPathComponent("conversations.enc", isDirectory: false)
    }

    private convenience init() {
        self.init(archiveURL: Self.defaultArchiveURL,
                  keychainService: "com.wechatreplycopilot.conversation-storage",
                  keychainAccount: "archive-aes-key-v1")
    }

    init(archiveURL: URL, keychainService: String, keychainAccount: String) {
        self.archiveURL = archiveURL
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
    }

    var isEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.storageEnabledKey) != nil else { return true }
        return defaults.bool(forKey: Self.storageEnabledKey)
    }

    /// Hashes the confirmed display identity so contact names never appear in the archive index.
    func identityKey(for displayName: String) -> String {
        let normalized = WeChatParsing.conversationIdentityKey(displayName)
        return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func load(identityKey: String) throws -> [ChatMessage] {
        lock.lock(); defer { lock.unlock() }
        var archive = try readArchive()
        let cutoff = Date().addingTimeInterval(-retentionInterval)
        var didPrune = false
        for index in archive.conversations.indices {
            let previousCount = archive.conversations[index].messages.count
            archive.conversations[index].messages.removeAll { $0.capturedAt < cutoff }
            didPrune = didPrune || previousCount != archive.conversations[index].messages.count
        }
        let previousConversationCount = archive.conversations.count
        archive.conversations.removeAll { $0.updatedAt < cutoff || $0.messages.isEmpty }
        didPrune = didPrune || previousConversationCount != archive.conversations.count
        if didPrune { try writeArchive(archive) }
        guard let conversation = archive.conversations.first(where: { $0.localIdentityKey == identityKey }) else {
            return []
        }
        return conversation.messages.map(\.chatMessage)
    }

    func save(messages: [ChatMessage], identityKey: String, displayName: String) throws {
        guard isEnabled, !messages.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var archive = try readArchive()
        let now = Date()
        let cutoff = now.addingTimeInterval(-retentionInterval)
        for index in archive.conversations.indices {
            archive.conversations[index].messages.removeAll { $0.capturedAt < cutoff }
        }
        archive.conversations.removeAll { $0.updatedAt < cutoff || $0.messages.isEmpty }
        if let index = archive.conversations.firstIndex(where: { $0.localIdentityKey == identityKey }) {
            var record = archive.conversations[index]
            let oldMessages = record.messages.map(\.chatMessage)
            let merged = ChatHistoryMerger.merge(existing: oldMessages, visible: messages,
                                                 limit: maxMessagesPerConversation)
            record.messages = merged
                .filter { $0.capturedAt >= now.addingTimeInterval(-retentionInterval) }
                .suffix(maxMessagesPerConversation)
                .map(StoredMessage.init)
            record.displayName = displayName
            record.updatedAt = now
            archive.conversations[index] = record
        } else {
            let retained = messages
                .filter { $0.capturedAt >= now.addingTimeInterval(-retentionInterval) }
                .suffix(maxMessagesPerConversation)
                .map(StoredMessage.init)
            archive.conversations.append(StoredConversation(
                id: UUID(), localIdentityKey: identityKey, displayName: displayName,
                messages: Array(retained), updatedAt: now
            ))
        }
        try writeArchive(archive)
    }

    func clear(identityKey: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: archiveURL.path) else { return }
        var archive = try readArchive()
        archive.conversations.removeAll { $0.localIdentityKey == identityKey }
        try writeArchive(archive)
    }

    func clearAll() throws {
        lock.lock(); defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            try FileManager.default.removeItem(at: archiveURL)
        }
    }

    private func readArchive() throws -> ConversationArchive {
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            return ConversationArchive(conversations: [])
        }
        let encrypted = try Data(contentsOf: archiveURL)
        guard let box = try? AES.GCM.SealedBox(combined: encrypted) else {
            throw StoreError.unreadable
        }
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(box, using: encryptionKey())
        } catch {
            throw StoreError.unreadable
        }
        do {
            return try JSONDecoder().decode(ConversationArchive.self, from: plaintext)
        } catch {
            throw StoreError.unreadable
        }
    }

    private func writeArchive(_ archive: ConversationArchive) throws {
        let directory = archiveURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let plaintext = try JSONEncoder().encode(archive)
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(plaintext, using: encryptionKey())
        } catch {
            throw StoreError.encryptionFailed
        }
        guard let combined = sealed.combined else { throw StoreError.encryptionFailed }
        try combined.write(to: archiveURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archiveURL.path)
    }

    private func encryptionKey() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound else { throw StoreError.keyUnavailable }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        var add = query
        add.removeValue(forKey: kSecReturnData as String)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw StoreError.keyUnavailable }
        return key
    }

    private enum StoreError: Error {
        case unreadable
        case encryptionFailed
        case keyUnavailable
    }
}
