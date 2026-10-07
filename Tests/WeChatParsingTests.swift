import Foundation

@main
enum WeChatParsingTests {
    static func main() {
        expect(WeChatParsing.normalizeChatTitle("  Group   Name(23)  ") == "Group Name", "normalizes whitespace and removes group count")
        expect(WeChatParsing.normalizeChatTitle("Project Room (active)") == "Project Room (active)", "preserves non-numeric suffix")
        expect(WeChatParsing.conversationIdentityKey(" Alex (23) ") == WeChatParsing.conversationIdentityKey("alex"), "normalizes conversation identity for comparison")
        expect(WeChatParsing.isPlausibleChatText("嗯", confidence: 0.46), "keeps short Chinese messages")
        expect(WeChatParsing.isPlausibleChatText("哈哈", confidence: 0.50), "keeps short Chinese laughter")
        expect(WeChatParsing.isPlausibleChatText("😂", confidence: 0.50), "keeps emoji-only messages")
        expect(!WeChatParsing.isPlausibleChatText("*FF\"ILET", confidence: 0.50), "rejects symbol-heavy OCR artifacts")
        expect(!WeChatParsing.isPlausibleChatText("?!", confidence: 0.90), "rejects punctuation-only OCR")
        expect(WeChatParsing.titleMatchesMessage("你晚上还回来吗", message: "你晚上还回来吗"), "rejects title matching exact message content")
        expect(WeChatParsing.titleMatchesMessage("你晚上还回来吗", message: "你晚上还回来吗？"), "normalizes title punctuation before message comparison")
        expect(WeChatParsing.titleMatchesMessage("你晚上还回", message: "你晚上还回来吗"), "rejects titles that are substantial message substrings")
        expect(WeChatParsing.titleMatchesMessage("Contact", message: "Contack"), "rejects nearly identical OCR text")
        expect(!WeChatParsing.titleMatchesMessage("Alex", message: "See you later"), "keeps unrelated titles distinct from messages")
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
        let repeatedOne = ChatMessage(text: "嗯", sender: .other, allowsAutomaticAnalysis: false, id: "vision:other:嗯:order0")
        let repeatedTwo = ChatMessage(text: "嗯", sender: .other, allowsAutomaticAnalysis: false, id: "vision:other:嗯:order1")
        expect(repeatedOne.id != repeatedTwo.id, "keeps identical OCR messages distinct within a snapshot")
        expect(!repeatedOne.allowsAutomaticAnalysis && !repeatedTwo.allowsAutomaticAnalysis, "OCR snapshots remain manual-only")
        expect(!WeChatParsing.canAutomaticallyAnalyze([unknown]), "unknown sender never auto-analyzes")
        expect(!WeChatParsing.canAutomaticallyAnalyze([outgoing]), "outgoing-only context never auto-analyzes")
        expect(!WeChatParsing.canAutomaticallyAnalyze([incoming, unknown]), "mixed known and unknown context never auto-analyzes")
        expect(WeChatParsing.canAutomaticallyAnalyze([incoming]), "identified incoming context may auto-analyze")

        expect(WeChatParsing.diagnosticIdentifier("session_item_Alex") == "session_item_<redacted>", "redacts names embedded in session identifiers")
        expect(WeChatParsing.genericDiagnosticWindowTitle("WeChat (Chats)") == "WeChat (Chats)", "allows generic window title in diagnostics")
        expect(WeChatParsing.genericDiagnosticWindowTitle("Alex") == "<redacted>", "redacts contact names in diagnostics")

        let titleA = identity("Alice")
        let titleB = identity("Bob")
        let titleC = identity("Carol")
        expect(consensus(titleA, titleA)?.secondIndex == 1, "A/A confirms after two captures")
        expect(consensus(titleA, nil, titleA)?.firstIndex == 0 && consensus(titleA, nil, titleA)?.secondIndex == 2,
               "A/noise/A confirms using captures one and three")
        expect(consensus(nil, titleA, titleA)?.firstIndex == 1 && consensus(nil, titleA, titleA)?.secondIndex == 2,
               "noise/A/A confirms using captures two and three")
        expect(consensus(titleA, titleB, titleA)?.firstIndex == 0 && consensus(titleA, titleB, titleA)?.secondIndex == 2,
               "A/B/A confirms the matching spatially consistent pair")
        expect(consensus(titleA, titleB, titleB)?.firstIndex == 1 && consensus(titleA, titleB, titleB)?.secondIndex == 2,
               "A/B/B confirms B only when the B pair matches")
        expect(consensus(titleA, titleB, titleC) == nil, "A/B/C fails safely")
        let displacedTitleA = identity("Alice", x: 0.70)
        expect(consensus(titleA, nil, displacedTitleA) == nil, "all-pairs recovery retains spatial constraints")

        let existing = (14...20).map { visionMessage("M\($0)", order: $0 - 14) }
        let olderViewport = (8...14).map { visionMessage("M\($0)", order: $0 - 8) }
        let loadedHistory = ChatHistoryMerger.merge(existing: existing, visible: olderViewport, limit: 100)
        expect(loadedHistory.map(\.text) == (8...20).map { "M\($0)" },
               "overlapping older OCR snapshot prepends older rows without duplicating overlap")
        expect(ChatHistoryMerger.appended(previous: existing, merged: loadedHistory).isEmpty,
               "historical prepend is not treated as appended live messages")
        expect(ChatHistoryMerger.merge(existing: existing, visible: olderViewport, limit: 10).count == 10,
               "history merge respects local context limit")
        let secondOlderViewport = (2...8).map { visionMessage("M\($0)", order: $0 - 2) }
        let thirdOlderViewport = (1...2).map { visionMessage("M\($0)", order: $0 - 1) }
        let thirteen = ChatHistoryMerger.merge(existing: existing, visible: olderViewport, limit: 100)
        let nineteen = ChatHistoryMerger.merge(existing: thirteen, visible: secondOlderViewport, limit: 100)
        let twenty = ChatHistoryMerger.merge(existing: nineteen, visible: thirdOlderViewport, limit: 100)
        expect(existing.count == 7 && twenty.count == 20 && twenty.first?.text == "M1" && twenty.last?.text == "M20",
               "simulated bounded overlap expands a 7-message viewport to 20 unique rows")
        print("All WeChat parsing checks passed.")
    }

    private static func identity(_ title: String, x: CGFloat = 0.50) -> VisionConversationIdentity {
        VisionConversationIdentity(normalizedTitle: title, titleCenterX: x, titleCenterY: 0.08,
                                   titleWidth: 0.12, confidence: 0.70)
    }

    private static func consensus(_ identities: VisionConversationIdentity?...) -> VisionTitlePair? {
        VisionTitleConsensus.evaluate(identities).bestPair
    }

    private static func visionMessage(_ text: String, order: Int) -> ChatMessage {
        ChatMessage(text: text, sender: .other, allowsAutomaticAnalysis: false, id: "vision:other:\(text):order\(order)")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
        guard condition() else {
            fputs("FAILED: \(description)\n", stderr)
            exit(1)
        }
    }
}
