// Draws the app icon: an original cat whose face is a usage gauge.
// Deliberately not the Octocat — no octopus arms, no Invertocat silhouette, no GitHub marks.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// macOS icon grid: 824pt tile centred on a 1024 canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Drop shadow under the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(tilePath); ctx.setFillColor(rgb(0x161A3D)); ctx.fillPath()
ctx.restoreGState()

// Tile gradient: indigo at the top to near-black navy at the bottom.
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x3A3F9E), rgb(0x0D1030)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// Soft glow behind the head.
let glow = CGGradient(colorsSpace: cs, colors: [rgb(0x7C83FF, 0.35), rgb(0x7C83FF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 520), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 520), endRadius: 420, options: [])
ctx.restoreGState()

// Cat head: a wide rounded face with two pointed ears.
let head = CGMutablePath()
head.addEllipse(in: CGRect(x: 232, y: 222, width: 560, height: 470))
func ear(_ pts: [CGPoint]) -> CGPath {
    let p = CGMutablePath()
    p.move(to: pts[0]); p.addLine(to: pts[1]); p.addLine(to: pts[2]); p.closeSubpath()
    // Round the tip slightly by stroking with a round join.
    return p.copy(strokingWithWidth: 36, lineCap: .round, lineJoin: .round, miterLimit: 10).union(p)
}

let leftEar = ear([CGPoint(x: 268, y: 560), CGPoint(x: 318, y: 805), CGPoint(x: 470, y: 665)])
let rightEar = ear([CGPoint(x: 756, y: 560), CGPoint(x: 706, y: 805), CGPoint(x: 554, y: 665)])
let headShape = CGPath(rect: .zero, transform: nil).union(head).union(leftEar).union(rightEar)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.4))
ctx.addPath(headShape); ctx.setFillColor(rgb(0xF4F6FF)); ctx.fillPath()
ctx.restoreGState()

// Inner ears.
for pts in [[CGPoint(x: 310, y: 610), CGPoint(x: 336, y: 745), CGPoint(x: 420, y: 668)],
            [CGPoint(x: 714, y: 610), CGPoint(x: 688, y: 745), CGPoint(x: 604, y: 668)]] {
    ctx.move(to: pts[0]); ctx.addLine(to: pts[1]); ctx.addLine(to: pts[2]); ctx.closePath()
    ctx.setFillColor(rgb(0xC9CCF5)); ctx.fillPath()
}

// Face = gauge. Three arc segments, green → amber → red, sweeping over the top of the face.
let pivot = CGPoint(x: 512, y: 446)
let radius: CGFloat = 165
func deg(_ d: CGFloat) -> CGFloat { d * .pi / 180 }
ctx.setLineWidth(46)
ctx.setLineCap(.round)
let segments: [(CGFloat, CGFloat, UInt32)] = [(196, 132, 0x2EA043), (124, 60, 0xE3A008), (52, -16, 0xF0503C)]
for (from, to, color) in segments {
    ctx.addArc(center: pivot, radius: radius, startAngle: deg(from), endAngle: deg(to), clockwise: true)
    ctx.setStrokeColor(rgb(color)); ctx.strokePath()
}

// Needle, pointing into the green-amber boundary: "comfortable pace".
let needleAngle = deg(118)
let tip = CGPoint(x: pivot.x + cos(needleAngle) * 150, y: pivot.y + sin(needleAngle) * 150)
ctx.setLineWidth(24)
ctx.move(to: pivot); ctx.addLine(to: tip)
ctx.setStrokeColor(rgb(0x1B1F4A)); ctx.strokePath()

// Pivot doubles as the cat's nose.
ctx.addEllipse(in: CGRect(x: pivot.x - 38, y: pivot.y - 34, width: 76, height: 68))
ctx.setFillColor(rgb(0x1B1F4A)); ctx.fillPath()
ctx.addEllipse(in: CGRect(x: pivot.x - 14, y: pivot.y + 4, width: 22, height: 16))
ctx.setFillColor(rgb(0xFFFFFF, 0.35)); ctx.fillPath()

// Small "w" mouth under the nose.
ctx.setLineWidth(14)
ctx.move(to: CGPoint(x: 472, y: 376))
ctx.addQuadCurve(to: CGPoint(x: 512, y: 384), control: CGPoint(x: 490, y: 352))
ctx.addQuadCurve(to: CGPoint(x: 552, y: 376), control: CGPoint(x: 534, y: 352))
ctx.setStrokeColor(rgb(0x1B1F4A)); ctx.strokePath()

// Whiskers: extend past the face, dark on the face and light where they cross the background.
let whiskers = CGMutablePath()
for (y0, y1) in [(334.0, 368.0), (308.0, 304.0), (282.0, 240.0)] as [(CGFloat, CGFloat)] {
    whiskers.move(to: CGPoint(x: 418, y: y0)); whiskers.addLine(to: CGPoint(x: 196, y: y1))
    whiskers.move(to: CGPoint(x: 606, y: y0)); whiskers.addLine(to: CGPoint(x: 828, y: y1))
}
let whiskerStroke = whiskers.copy(strokingWithWidth: 11, lineCap: .round, lineJoin: .round, miterLimit: 10)
ctx.saveGState()
ctx.addPath(whiskerStroke.intersection(headShape)); ctx.setFillColor(rgb(0x1B1F4A, 0.8)); ctx.fillPath()
ctx.addPath(whiskerStroke.subtracting(headShape)); ctx.setFillColor(rgb(0xF4F6FF, 0.85)); ctx.fillPath()
ctx.restoreGState()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
