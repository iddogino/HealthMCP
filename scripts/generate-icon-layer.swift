import Foundation
import CoreGraphics

// Preserve the original 1024-point artwork, converting its stroke to an SVG outline.
// SVG's origin is at the top left; the original AppKit renderer's was bottom left.
let centerline = CGMutablePath()
centerline.move(to: CGPoint(x: 165, y: 519))
for point in [(340, 519), (415, 314), (545, 726), (630, 469), (691, 519), (860, 519)] {
    centerline.addLine(to: CGPoint(x: point.0, y: point.1))
}
let outline = centerline.copy(strokingWithWidth: 54, lineCap: .round, lineJoin: .round, miterLimit: 10)
func number(_ value: CGFloat) -> String {
    String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), Double(value))
}
func point(_ value: CGPoint) -> String { "\(number(value.x)) \(number(value.y))" }
var commands: [String] = []
outline.applyWithBlock { pointer in
    let element = pointer.pointee
    switch element.type {
    case .moveToPoint: commands.append("M\(point(element.points[0]))")
    case .addLineToPoint: commands.append("L\(point(element.points[0]))")
    case .addQuadCurveToPoint: commands.append("Q\(point(element.points[0])) \(point(element.points[1]))")
    case .addCurveToPoint: commands.append("C\(point(element.points[0])) \(point(element.points[1])) \(point(element.points[2]))")
    case .closeSubpath: commands.append("Z")
    @unknown default: fatalError("Unsupported path element")
    }
}
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <path fill="#75EDD9" d="\(commands.joined(separator: " "))"/>
</svg>

"""
guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift scripts/generate-icon-layer.swift path/to/Spark.svg")
}
try svg.write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
