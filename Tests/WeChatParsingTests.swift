import Foundation

@main
enum WeChatParsingTests {
    static func main() {
        expect(WeChatParsing.normalizeChatTitle("  Group   Name(23)  ") == "Group Name", "normalizes whitespace and removes group count")
        expect(WeChatParsing.normalizeChatTitle("Project Room (active)") == "Project Room (active)", "preserves non-numeric suffix")
        expect(WeChatParsing.isGenericWindowTitle("WeChat (Chats)"), "recognizes generic WeChat window title")
        expect(!WeChatParsing.isGenericWindowTitle("Alex"), "does not classify a contact name as generic")

        expect(WeChatParsing.selectedSessionName(from: "session_item_Alex", isSelected: false) == nil, "does not infer an unselected session")
        expect(WeChatParsing.selectedSessionName(from: "session_item_Alex", isSelected: true) == "Alex", "reads a selected session name")
        expect(WeChatParsing.selectedSessionName(from: "unrelated_Alex", isSelected: true) == nil, "ignores unrelated identifiers")

        expect(WeChatParsing.sender(from: "sent: hello") == .me, "recognizes sent description")
        expect(WeChatParsing.sender(from: "received message") == .other, "recognizes received description")
        expect(WeChatParsing.sender(from: "敏感信息") == .unknown, "does not misclassify arbitrary English prefixes")
        expect(WeChatParsing.sender(from: "") == .unknown, "leaves absent sender metadata unknown")

        expect(WeChatParsing.messageText(identifier: "chat_bubble_item_view", title: "preferred", value: "fallback") == "preferred", "prefers AXTitle")
        expect(WeChatParsing.messageText(identifier: "chat_bubble_item_view", title: "  ", value: "fallback") == "fallback", "uses AXValue when title is empty")
        expect(WeChatParsing.messageText(identifier: "virtual_cell", title: "placeholder", value: nil) == nil, "ignores recycled placeholder rows")
        expect(WeChatParsing.messageText(identifier: "date_separator", title: "Today", value: nil) == nil, "ignores date separators")
        expect(WeChatParsing.messageText(identifier: "system_notice", title: "Message recalled", value: nil) == nil, "ignores system rows")

        let unknown = ChatMessage(text: "hello", sender: .unknown)
        let incoming = ChatMessage(text: "hello", sender: .other)
        let outgoing = ChatMessage(text: "hello", sender: .me)
        expect(!WeChatParsing.canAutomaticallyAnalyze([unknown]), "unknown sender never auto-analyzes")
        expect(!WeChatParsing.canAutomaticallyAnalyze([outgoing]), "outgoing-only context never auto-analyzes")
        expect(!WeChatParsing.canAutomaticallyAnalyze([incoming, unknown]), "mixed known and unknown context never auto-analyzes")
        expect(WeChatParsing.canAutomaticallyAnalyze([incoming]), "identified incoming context may auto-analyze")

        expect(WeChatParsing.diagnosticIdentifier("session_item_Alex") == "session_item_<redacted>", "redacts names embedded in session identifiers")
        expect(WeChatParsing.genericDiagnosticWindowTitle("WeChat (Chats)") == "WeChat (Chats)", "allows generic window title in diagnostics")
        expect(WeChatParsing.genericDiagnosticWindowTitle("Alex") == "<redacted>", "redacts contact names in diagnostics")
        print("All WeChat parsing checks passed.")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
        guard condition() else {
            fputs("FAILED: \(description)\n", stderr)
            exit(1)
        }
    }
}
