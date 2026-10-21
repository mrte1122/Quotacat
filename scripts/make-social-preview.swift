// Renders docs/social-preview.png (1280×640), the card GitHub shows when the repo link is shared.
// Usage: swift scripts/make-social-preview.swift   (then upload it in the repo's Settings → Social preview)
import AppKit

let W: CGFloat = 1280, H: CGFloat = 640, scale: CGFloat = 1   // GitHub caps the upload at 1 MB
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
guard let icon = NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.png")),
      let shot = NSImage(contentsOf: root.appendingPathComponent("docs/popover-dark.png")) else {
    print("run from the repo root"); exit(1)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Background: the icon's indigo → midnight gradient.
NSGradient(starting: NSColor(srgbRed: 0.21, green: 0.25, blue: 0.55, alpha: 1),
           ending: NSColor(srgbRed: 0.05, green: 0.06, blue: 0.17, alpha: 1))!
    .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -60)

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat = 1, at p: NSPoint, width: CGFloat = 640) {
    let style = NSMutableParagraphStyle(); style.lineSpacing = 4
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                .foregroundColor: NSColor.white.withAlphaComponent(alpha),
                                                .paragraphStyle: style]
    let r = (s as NSString).boundingRect(with: NSSize(width: width, height: 400), options: .usesLineFragmentOrigin, attributes: attrs)
    (s as NSString).draw(with: NSRect(x: p.x, y: p.y - r.height, width: width, height: r.height),
                         options: .usesLineFragmentOrigin, attributes: attrs)
}

// Left column: icon, name, pitch.
icon.draw(in: NSRect(x: 72, y: H - 72 - 150, width: 150, height: 150))
text("Quotacat", size: 76, weight: .bold, at: NSPoint(x: 236, y: H - 104))
text("Know before GitHub bills you.", size: 40, weight: .semibold, at: NSPoint(x: 84, y: H - 270))
text("Actions minutes (macOS counts 10×), Copilot AI Credits, API rate limits, pull requests and failing workflows, in your Mac's menu bar.",
     size: 25, weight: .regular, alpha: 0.78, at: NSPoint(x: 84, y: H - 340), width: 620)
text("Free and open source  ·  Notarized  ·  github.com/mrte1122/Quotacat", size: 20, weight: .medium, alpha: 0.6,
     at: NSPoint(x: 84, y: 92), width: 700)

// Right: the popover, with a soft shadow.
let shotH: CGFloat = 600
let shotW = shot.size.width / shot.size.height * shotH
let frame = NSRect(x: W - shotW - 70, y: (H - shotH) / 2, width: shotW, height: shotH)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow(); shadow.shadowBlurRadius = 30; shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.shadowColor = NSColor.black.withAlphaComponent(0.5); shadow.set()
shot.draw(in: frame)
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()
let out = root.appendingPathComponent("docs/social-preview.png")
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("Wrote \(out.path)")
