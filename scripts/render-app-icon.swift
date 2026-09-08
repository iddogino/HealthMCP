import AppKit
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
NSColor(srgbRed: 0.028, green: 0.054, blue: 0.11, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()
NSColor(srgbRed: 0.46, green: 0.93, blue: 0.85, alpha: 1).setStroke()
let line = NSBezierPath()
line.move(to: NSPoint(x: 165, y: 505))
for point in [(340,505),(415,710),(545,298),(630,555),(691,505),(860,505)] { line.line(to: NSPoint(x: point.0, y: point.1)) }
line.lineWidth = 54; line.lineCapStyle = .round; line.lineJoinStyle = .round; line.stroke()
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
