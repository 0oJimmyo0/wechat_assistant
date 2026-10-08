import Foundation
@main enum AnalysisContextTests {
    static func main() throws {
        let session = UUID()
        let rows = (0..<30).map { ChatMessage(text: "public message \($0)", sender: $0 % 2 == 0 ? .me : .other) }
        expect(AnalysisContext.latest(in: rows).map(\.text) == rows.suffix(20).map(\.text),"default context is exactly the latest 20 chronological rows")
        var selection = AnalysisContextSelection()
        selection.select(rows[8].localID); selection.select(rows[3].localID)
        let selected = try selection.messages(in: rows)
        expect(selected == Array(rows[3...8]),"reverse endpoint selection retains chronological order")
        expect(AnalysisContext.isCurrent(selected,session: session,currentSession: session,retained: rows),"frozen selected context remains valid when still retained")
        expect(!AnalysisContext.isCurrent(selected,session: session,currentSession: UUID(),retained: rows),"another conversation cannot use a historical preview")
        expect(!AnalysisContext.isCurrent(selected,session: session,currentSession: session,retained: Array(rows.suffix(10))),"evicted selected context must be previewed again")
        selection.select(rows[0].localID); selection.select(rows[25].localID)
        do { _ = try selection.messages(in: rows); expect(false,"oversize selection must fail without silent truncation") } catch AnalysisContextError.tooManyMessages {}
        let timed = rows[3].withTimeSeparator("昨天 10:30")
        let serialized = try AnalysisContext.modelText([timed,ChatMessage(text: "unknown sender",sender: .unknown)])
        expect(serialized.contains("[观察到的微信时间分隔：昨天 10:30]\n对方：public message 3") && serialized.contains("说话方不确定：unknown sender"),"exact model block retains separators and sender uncertainty")
        expect(!serialized.contains(String(describing: timed.firstSeenAt)),"capture time cannot masquerade as send time")
        print("All analysis context selection and isolation checks passed.")
    }
    static func expect(_ condition: @autoclosure () -> Bool, _ label: String) { if !condition() { fputs("FAILED: \(label)\n",stderr); exit(1) } }
}
