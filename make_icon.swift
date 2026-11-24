import AppKit
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let bg = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(red: 0.10, green: 0.13, blue: 0.20, alpha: 1), NSColor(red: 0.03, green: 0.05, blue: 0.09, alpha: 1)])!.draw(in: bg, angle: -90)
bg.addClip()
// faint grid
NSColor(white: 1, alpha: 0.07).setStroke()
for i in 1...4 { let y = 100 + CGFloat(i) * 165; let l = NSBezierPath(); l.move(to: NSPoint(x: 100, y: y)); l.line(to: NSPoint(x: 924, y: y)); l.lineWidth = 3; l.stroke() }
// chart line
let pts: [(CGFloat, CGFloat)] = [(190,330),(320,430),(410,380),(540,560),(640,500),(760,700),(840,780)]
let path = NSBezierPath()
path.move(to: NSPoint(x: pts[0].0, y: pts[0].1))
for p in pts.dropFirst() { path.line(to: NSPoint(x: p.0, y: p.1)) }
// area fill
let area = path.copy() as! NSBezierPath
area.line(to: NSPoint(x: 840, y: 100)); area.line(to: NSPoint(x: 190, y: 100)); area.close()
NSGradient(colors: [NSColor(red: 0.20, green: 0.85, blue: 0.55, alpha: 0.35), NSColor(red: 0.20, green: 0.85, blue: 0.55, alpha: 0.0)])!.draw(in: area, angle: -90)
NSColor(red: 0.25, green: 0.90, blue: 0.60, alpha: 1).setStroke()
path.lineWidth = 30; path.lineCapStyle = .round; path.lineJoinStyle = .round; path.stroke()
let end = NSBezierPath(ovalIn: NSRect(x: 840-34, y: 780-34, width: 68, height: 68))
NSColor(red: 0.25, green: 0.90, blue: 0.60, alpha: 1).setFill(); end.fill()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Resources/icon_1024.png"))
