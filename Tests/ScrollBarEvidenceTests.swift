import Foundation
@main enum ScrollBarEvidenceTests {
    static func main() {
        func edge(_ value: Double?, _ min: Double? = nil, _ max: Double? = nil,
            _ role: String? = "AXScrollBar", _ orientation: String? = "AXVerticalOrientation") -> Bool? {
            ScrollBarEvidence.liveEdge(value: value,minimum: min,maximum: max,role: role,orientation: orientation)
        }
        expect(edge(1) == true && edge(0) == false && edge(0.5) == false,"normalized native vertical scrollbar endpoints and history")
        expect(edge(150,50,150) == true && edge(100,50,150) == false,"explicit supported range normalizes correctly")
        expect(edge(0.999) == false && edge(0.9999999) == true,"near-tail history cannot imply a genuine arrival")
        expect(edge(1,0,nil) == nil && edge(1,nil,1) == nil && edge(1,1,1) == nil,"partial or invalid explicit ranges stay uncertain")
        expect(edge(nil) == nil && edge(.nan) == nil && edge(.infinity) == nil && edge(-0.1) == nil && edge(2) == nil,"unreadable or out-of-range values stay uncertain")
        expect(edge(1,nil,nil,"AXSlider") == nil && edge(1,nil,nil,"AXScrollBar","AXHorizontalOrientation") == nil,"unrelated controls cannot establish transcript tail")
        print("All vertical scrollbar evidence checks passed.")
    }
    static func expect(_ condition: @autoclosure () -> Bool, _ label: String) { if !condition() { fputs("FAILED: \(label)\n",stderr); exit(1) } }
}
