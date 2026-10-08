import Foundation
import CoreGraphics

struct VisionMessageLine: Sendable {
    let text: String
    let bounds: CGRect
    let confidence: Float
}

struct VisionBubbleRegion: Sendable {
    let id: Int
    let bounds: CGRect
}

/// Evidence from the current transcript image, not text proximity. Components
/// must form a filled bubble-sized background completely inside the viewport.
enum VisionMessageReconstruction {
    static func bubbleRegions(in image: CGImage, region: CGRect) -> [VisionBubbleRegion] {
        let width = min(640, image.width)
        let height = max(1, Int(Double(image.height) * Double(width) / Double(image.width)))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return [] }
        let x0 = max(0, Int(ceil(region.minX * CGFloat(width))))
        let x1 = min(width - 1, Int(floor(region.maxX * CGFloat(width))) - 1)
        let y0 = max(0, Int(ceil((1 - region.maxY) * CGFloat(height))))
        let y1 = min(height - 1, Int(floor((1 - region.minY) * CGFloat(height))) - 1)
        guard x1 > x0, y1 > y0 else { return [] }
        var visited = [Bool](repeating: false, count: width * height)
        var bubbles: [VisionBubbleRegion] = []
        let deadline = Date().addingTimeInterval(0.20)
        for y in y0...y1 {
            if Date() >= deadline { return [] } // Missing evidence fails closed.
            for x in x0...x1 {
                let seed = y * width + x
                if visited[seed] { continue }
                visited[seed] = true
                let color = (Int(pixels[seed * 4]), Int(pixels[seed * 4 + 1]), Int(pixels[seed * 4 + 2]))
                var queue = [seed]
                var cursor = 0
                var minX = x, maxX = x, minY = y, maxY = y
                while cursor < queue.count {
                    let index = queue[cursor]
                    cursor += 1
                    let px = index % width, py = index / width
                    minX = min(minX, px); maxX = max(maxX, px)
                    minY = min(minY, py); maxY = max(maxY, py)
                    for (nx, ny) in [(px - 1, py), (px + 1, py), (px, py - 1), (px, py + 1)] {
                        guard nx >= x0, nx <= x1, ny >= y0, ny <= y1 else { continue }
                        let next = ny * width + nx
                        guard !visited[next],
                              abs(Int(pixels[next * 4]) - color.0) <= 10,
                              abs(Int(pixels[next * 4 + 1]) - color.1) <= 10,
                              abs(Int(pixels[next * 4 + 2]) - color.2) <= 10 else { continue }
                        visited[next] = true
                        queue.append(next)
                    }
                }
                let componentWidth = maxX - minX + 1, componentHeight = maxY - minY + 1
                let fill = Double(queue.count) / Double(componentWidth * componentHeight)
                // The large transcript background touches an edge and is never
                // a bubble. Clipped/partial bubbles also cannot become context.
                guard minX > x0, maxX < x1, minY > y0, maxY < y1,
                      componentWidth >= 18, componentHeight >= 10,
                      CGFloat(componentWidth) < region.width * CGFloat(width) * 0.82,
                      CGFloat(componentHeight) < region.height * CGFloat(height) * 0.60,
                      fill >= 0.58 else { continue }
                let bounds = CGRect(x: CGFloat(minX) / CGFloat(width),
                    y: 1 - CGFloat(maxY + 1) / CGFloat(height),
                    width: CGFloat(componentWidth) / CGFloat(width), height: CGFloat(componentHeight) / CGFloat(height))
                // Bubbles sit on one side of the pane; timestamps and centered
                // notices cannot supply message background evidence.
                let leftMargin = bounds.minX - region.minX
                let rightMargin = region.maxX - bounds.maxX
                let aligned = (region.width * 0.045...region.width * 0.16).contains(leftMargin) ||
                    (region.width * 0.035...region.width * 0.16).contains(rightMargin)
                if aligned { bubbles.append(VisionBubbleRegion(id: seed, bounds: bounds)) }
            }
        }
        return bubbles
    }

    static func region(for line: VisionMessageLine, in bubbles: [VisionBubbleRegion]) -> VisionBubbleRegion? {
        let matches = bubbles.filter { $0.bounds.contains(line.bounds.insetBy(dx: -0.002, dy: -0.001)) }
        return matches.count == 1 ? matches[0] : nil
    }

    static func reconstruct(_ lines: [VisionMessageLine], bubbles: [VisionBubbleRegion],
                            region: CGRect) -> (messages: [ChatMessage], bounds: [CGRect]) {
        var grouped: [Int: [VisionMessageLine]] = [:]
        for line in lines {
            guard let bubble = self.region(for: line, in: bubbles) else { continue }
            grouped[bubble.id, default: []].append(line)
        }
        var accepted: [(ChatMessage, CGRect)] = []
        for bubble in bubbles {
            guard let fragments = grouped[bubble.id], !fragments.isEmpty,
                  fragments.allSatisfy({ WeChatParsing.isReliableOCRText($0.text, confidence: $0.confidence) }) else { continue }
            let ordered = fragments.sorted {
                if abs($0.bounds.midY - $1.bounds.midY) > min($0.bounds.height, $1.bounds.height) * 0.5 {
                    return $0.bounds.midY > $1.bounds.midY
                }
                return $0.bounds.minX < $1.bounds.minX
            }
            var rows: [(String, CGRect)] = []
            for line in ordered {
                if let previous = rows.last,
                   abs(previous.1.midY - line.bounds.midY) <= min(previous.1.height, line.bounds.height) * 0.5 {
                    rows[rows.count - 1] = (previous.0 + " " + line.text, previous.1.union(line.bounds))
                } else { rows.append((line.text, line.bounds)) }
            }
            let text = rows.map(\.0).joined(separator: "\n")
            let confidence = fragments.map(\.confidence).min() ?? 0
            let leftMargin = bubble.bounds.minX - region.minX
            let rightMargin = region.maxX - bubble.bounds.maxX
            let sender: MessageSender
            if abs(leftMargin - rightMargin) <= region.width * 0.02 { sender = .unknown }
            else { sender = leftMargin < rightMargin ? .other : .me }
            accepted.append((ChatMessage(text: text, sender: sender, allowsAutomaticAnalysis: false,
                source: .vision, confidence: confidence), bubble.bounds))
        }
        accepted.sort { $0.1.maxY > $1.1.maxY }
        return (accepted.map(\.0), accepted.map(\.1))
    }
}
