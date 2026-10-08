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
        expect(WeChatParsing.isInterfaceMessageText("Q Search") &&
               WeChatParsing.isInterfaceMessageText("按住说话") &&
               !WeChatParsing.isInterfaceMessageText("今晚一起吃饭"),
               "message parser filters known WeChat controls while keeping ordinary chat text")

        let pane = CGRect(x: 0.42, y: 0.18, width: 0.57, height: 0.70)
        expect(WeChatParsing.messageSide(CGRect(x: 0.44, y: 0.45, width: 0.20, height: 0.04), in: pane) == .other,
               "sender classification uses full-window bounds and the resolved pane")
        expect(WeChatParsing.messageSide(CGRect(x: 0.74, y: 0.45, width: 0.22, height: 0.04), in: pane) == .me,
               "right-aligned full-window bubbles map to self inside the resolved pane")
        expect(WeChatParsing.messageSide(CGRect(x: 0.10, y: 0.45, width: 0.20, height: 0.04), in: pane) == .unknown,
               "sidebar text outside the resolved message pane cannot acquire a sender")
        expect(WeChatParsing.isPlausibleMessageBubble(CGRect(x: 0.44, y: 0.45, width: 0.20, height: 0.04), in: pane),
               "left-aligned transcript text matches bubble geometry")
        expect(!WeChatParsing.isPlausibleMessageBubble(CGRect(x: 0.68, y: 0.45, width: 0.05, height: 0.04), in: pane),
               "centered narrow UI labels do not match incoming or outgoing bubble geometry")

        expect(WeChatParsing.messageText(identifier: "chat_bubble_item_view", title: "preferred", value: "fallback") == "preferred", "prefers AXTitle")
        expect(WeChatParsing.messageText(identifier: "chat_bubble_item_view", title: "  ", value: "fallback") == "fallback", "uses AXValue when title is empty")
        expect(WeChatParsing.messageText(identifier: "virtual_cell", title: "placeholder", value: nil) == nil, "ignores recycled placeholder rows")
        expect(WeChatParsing.messageText(identifier: "date_separator", title: "Today", value: nil) == nil, "ignores date separators")
        expect(WeChatParsing.messageText(identifier: "system_notice", title: "Message recalled", value: nil) == nil, "ignores system rows")

        expect(WeChatParsing.descendantMessageText(role: "AXStaticText", identifier: "", title: nil, value: "actual bubble text") == "actual bubble text",
               "confirmed bubble descendants support AXValue")
        expect(WeChatParsing.descendantMessageText(role: "AXStaticText", identifier: "timestamp", title: "10:30", value: nil) == nil,
               "identified timestamp descendants are excluded")
        expect(WeChatParsing.descendantMessageText(role: "AXStaticText", identifier: "", title: "昨天 10:30", value: nil) == nil,
               "standalone timestamp fallback is excluded")
        expect(WeChatParsing.descendantMessageText(role: "AXStaticText", identifier: "contact_name", title: "Alex", value: nil) == nil,
               "contact labels cannot supply descendant message text")
        expect(WeChatParsing.descendantMessageText(role: "AXButton", identifier: "", title: "Send", value: nil) == nil,
               "controls cannot supply descendant message text")
        expect(WeChatParsing.messageText(identifier: "chat_bubble_item_view", title: "10:30", value: nil) == "10:30",
               "an actual timestamp-shaped bubble retains its original message text")

        expect(WeChatParsing.timeSeparatorLabel("10:30") == "10:30", "recognizes an observed clock-time separator")
        expect(WeChatParsing.timeSeparatorLabel("昨天 10:30") == "昨天 10:30", "recognizes localized WeChat divider")
        expect(WeChatParsing.timeSeparatorLabel("2026年10月7日 14:35") != nil, "recognizes dated WeChat divider")
        expect(WeChatParsing.timeSeparatorLabel("Can we meet at 10:30?") == nil,
               "conversation sentences cannot masquerade as time separators")
        expect(WeChatParsing.timeSeparatorLabel("random content") == nil, "unknown metadata is not a timestamp")
        let originalTimed = ChatMessage(text: "message", sender: .other)
        let observedTimed = originalTimed.withTimeSeparator("Yesterday 10:30")
        expect(originalTimed.timeSeparatorBefore == nil && observedTimed.timeSeparatorBefore == "Yesterday 10:30",
               "time dividers remain optional evidence; never inferred from firstSeenAt")
        expect(originalTimed.localID == observedTimed.localID && originalTimed.id == observedTimed.id,
               "adding verified time metadata preserves occurrence identity")

        let unknown = ChatMessage(text: "hello", sender: .unknown)
        let incoming = ChatMessage(text: "hello", sender: .other)
        let outgoing = ChatMessage(text: "hello", sender: .me)
        let visionUnknown = ChatMessage(text: "今天去哪儿玩", sender: .unknown, source: .vision)
        let visionTarget = ChatMessage(text: "今天去哪玩", sender: .other, source: .vision)
        let visionSelf = ChatMessage(text: "今天去哪玩", sender: .me, source: .vision)
        let axTarget = ChatMessage(text: "今天去哪玩", sender: .other, source: .accessibility)
        expect(ChatHistoryMerger.messagesCompatible(visionUnknown, visionTarget),
               "Vision overlap permits unknown-versus-known sender and a small text variation")
        expect(!ChatHistoryMerger.messagesCompatible(visionSelf, visionTarget) &&
               !ChatHistoryMerger.messagesCompatible(visionUnknown, axTarget),
               "Vision fuzzy matching never crosses me/other or AX/Vision source boundaries")
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

        var titleTracker = VisionTitleTracker()
        expect(titleTracker.resolve(title: "Alice", identity: titleA) == nil,
               "lower-confidence titles wait for a second observation")
        expect(titleTracker.resolve(title: "Alice", identity: titleA) == "Alice",
               "lower-confidence title is accepted after consistent text and geometry")
        let strongTitle = identity("Bob", confidence: 0.90)
        expect(titleTracker.resolve(title: "Bob", identity: strongTitle) == "Bob",
               "strong title confidence and geometry accepts one observation")
        expect(titleTracker.resolve(title: "Carol", identity: titleC) == nil,
               "a different lower-confidence title starts a fresh consensus")

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
        let fullHistory = (1...20).map { visionMessage("M\($0)", order: $0) }
        expect(ChatHistoryMerger.classify(existing: fullHistory,
                                          visible: (15...20).map { visionMessage("M\($0)", order: $0 - 15) }).state == .liveTail,
               "a viewport overlapping the history tail is live")
        expect(ChatHistoryMerger.classify(existing: fullHistory,
                                          visible: (4...8).map { visionMessage("M\($0)", order: $0 - 4) }).state == .historical,
               "a viewport overlapping only an interior history segment is historical")
        expect(ChatHistoryMerger.classify(existing: fullHistory,
                                          visible: [visionMessage("Unrelated", order: 0)]).state == .uncertain,
               "a viewport with no reliable overlap is uncertain")
        print("All WeChat parsing checks passed.")
    }

    private static func identity(_ title: String, x: CGFloat = 0.50,
                                 confidence: Float = 0.70) -> VisionConversationIdentity {
        VisionConversationIdentity(normalizedTitle: title, titleCenterX: x, titleCenterY: 0.08,
                                   titleWidth: 0.12, confidence: confidence)
    }

    private static func consensus(_ identities: VisionConversationIdentity?...) -> VisionTitlePair? {
        VisionTitleConsensus.evaluate(identities).bestPair
    }

    private static func visionMessage(_ text: String, order: Int) -> ChatMessage {
        ChatMessage(text: text, sender: .other, allowsAutomaticAnalysis: false,
                    id: "vision:other:\(text):order\(order)", source: .vision)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
        guard condition() else {
            fputs("FAILED: \(description)\n", stderr)
            exit(1)
        }
    }
}
