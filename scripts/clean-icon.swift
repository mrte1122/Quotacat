// Turns an icon rendered on a white background into a transparent macOS icon PNG.
// The squircle tile stays opaque; the soft shadow around it becomes a translucent black shadow.
// Usage: swift scripts/clean-icon.swift <input image> <output.png>
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let src = NSImage(contentsOfFile: args[1]),
      let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("usage: clean-icon <input> <output.png>"); exit(1)
}
let n = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(.white)
ctx.fill(CGRect(x: 0, y: 0, width: n, height: n))
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
let px = ctx.data!.bindMemory(to: UInt8.self, capacity: n * n * 4)

func lum(_ x: Int, _ y: Int) -> Int {
    let i = (y * n + x) * 4
    return (Int(px[i]) * 299 + Int(px[i + 1]) * 587 + Int(px[i + 2]) * 114) / 1000
}

// Find the dark tile's edges along the centre row and column.
let mid = n / 2
let left = (0..<n).first { lum($0, mid) < 110 }!
let right = (0..<n).last { lum($0, mid) < 110 }!
let bottom = (0..<n).first { lum(mid, $0) < 110 }!
let top = (0..<n).last { lum(mid, $0) < 110 }!
let tile = CGRect(x: left, y: bottom, width: right - left + 1, height: top - bottom + 1)
print("tile:", tile)

// Two masks: a "core" safely inside the tile, and an "outer" band just beyond its edge.
// The artwork's continuous-corner curve doesn't match a geometric rounded rect exactly, so in the
// band between them the edge is recovered from the pixels themselves by un-blending the white.
func coverage(inset: CGFloat, radiusRatio: CGFloat) -> UnsafeMutablePointer<UInt8> {
    let r = tile.insetBy(dx: inset, dy: inset)
    let c = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    c.setFillColor(gray: 1, alpha: 1)
    c.addPath(CGPath(roundedRect: r, cornerWidth: r.width * radiusRatio, cornerHeight: r.width * radiusRatio, transform: nil))
    c.fillPath()
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: n * n)
    buf.initialize(from: c.data!.bindMemory(to: UInt8.self, capacity: n * n), count: n * n)
    return buf
}
let core = coverage(inset: 12, radiusRatio: 0.26)
let outer = coverage(inset: -3, radiusRatio: 0.21)
let white = 248, tileLum = 70

for y in 0..<n {
    for x in 0..<n {
        let i = (y * n + x) * 4, k = y * n + x
        let c = Int(core[k]), o = Int(outer[k]), l = lum(x, y)
        if c == 255 { px[i + 3] = 255; continue }
        if o > 0 {
            // Pixel = tile * a + white * (1 - a). Solve for a, then remove the white contribution.
            let a = max(0, min(255, (white - l) * 255 / (white - tileLum)))
            for ch in 0..<3 {
                let orig = Int(px[i + ch])
                let unblended = max(0, min(a, orig - (255 - a)))
                px[i + ch] = UInt8((orig * c + unblended * (255 - c)) / 255)
            }
            px[i + 3] = UInt8(max(a, c))
        } else {
            // Shadow on white -> translucent black (premultiplied, so colour channels are 0).
            px[i] = 0; px[i + 1] = 0; px[i + 2] = 0
            px[i + 3] = UInt8(min(255, max(0, 255 - l) * 7 / 10))
        }
    }
}
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("Wrote \(args[2])")
