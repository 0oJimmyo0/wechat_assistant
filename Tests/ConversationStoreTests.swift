import Foundation
import Security

@main
enum ConversationStoreTests {
    static func main() throws {
        let defaults = UserDefaults.standard
        let previousEnabled = defaults.object(forKey: ConversationStore.storageEnabledKey)
        defaults.set(true, forKey: ConversationStore.storageEnabledKey)
        defer {
            if let previousEnabled { defaults.set(previousEnabled, forKey: ConversationStore.storageEnabledKey) }
            else { defaults.removeObject(forKey: ConversationStore.storageEnabledKey) }
        }

        let suiteID = UUID().uuidString
        let service = "com.wechatreplycopilot.tests.\(suiteID)"
        let account = "archive-key"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteID, isDirectory: true)
        let archiveURL = directory.appendingPathComponent("conversations.enc")
        defer {
            try? FileManager.default.removeItem(at: directory)
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ] as CFDictionary)
        }

        let firstStore = ConversationStore(archiveURL: archiveURL, keychainService: service, keychainAccount: account)
        let aliceKey = firstStore.identityKey(for: "Alice Example")
        let otherKey = firstStore.identityKey(for: "Bob Example")
        defaults.set(false, forKey: ConversationStore.storageEnabledKey)
        try firstStore.save(messages: [ChatMessage(text: "do not persist", sender: .other)],
                            identityKey: aliceKey, displayName: "Alice Example")
        expect(!FileManager.default.fileExists(atPath: archiveURL.path), "disabled storage does not write an archive")
        defaults.set(true, forKey: ConversationStore.storageEnabledKey)
        let messages = (1...501).map { index in
            ChatMessage(text: "private message \(index)", sender: .other, allowsAutomaticAnalysis: false,
                        id: "test-\(index)", source: .vision, confidence: 0.91)
        }
        try firstStore.save(messages: messages, identityKey: aliceKey, displayName: "Alice Example")

        let encryptedBytes = try Data(contentsOf: archiveURL)
        expect(!String(decoding: encryptedBytes, as: UTF8.self).contains("private message"), "archive does not contain plaintext message text")
        expect(!String(decoding: encryptedBytes, as: UTF8.self).contains("Alice Example"), "archive does not contain plaintext contact name")

        // A second store object models a new app launch reading the same archive and Keychain key.
        let relaunchedStore = ConversationStore(archiveURL: archiveURL, keychainService: service, keychainAccount: account)
        let restored = try relaunchedStore.load(identityKey: aliceKey)
        expect(restored.count == 500, "retains at most 500 messages per conversation")
        expect(restored.last?.text == "private message 501", "restores the newest stored message")
        expect(restored.last?.source == .vision && restored.last?.confidence == 0.91, "restores message source and OCR confidence")
        let otherConversation = try relaunchedStore.load(identityKey: otherKey)
        expect(otherConversation.isEmpty, "conversation identity keys isolate different contacts")

        let expired = ChatMessage(text: "expired", sender: .other, id: "expired",
                                  capturedAt: Date().addingTimeInterval(-31 * 24 * 60 * 60))
        let expiredKey = relaunchedStore.identityKey(for: "Expired Contact")
        try relaunchedStore.save(messages: [expired], identityKey: expiredKey, displayName: "Expired Contact")
        let expiredMessages = try relaunchedStore.load(identityKey: expiredKey)
        expect(expiredMessages.isEmpty, "does not restore messages older than 30 days")

        try relaunchedStore.clear(identityKey: aliceKey)
        let clearedConversation = try relaunchedStore.load(identityKey: aliceKey)
        expect(clearedConversation.isEmpty, "clears one conversation history")
        try relaunchedStore.clearAll()
        expect(!FileManager.default.fileExists(atPath: archiveURL.path), "clear all removes the encrypted archive")
        print("All encrypted conversation-store checks passed.")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
        guard condition() else {
            fputs("FAILED: \(description)\n", stderr)
            exit(1)
        }
    }
}
