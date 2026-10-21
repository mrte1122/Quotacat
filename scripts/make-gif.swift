// Converts a screen recording into a looping GIF for the README.
// Usage: swift scripts/make-gif.swift <input.mov> <output.gif> [start-seconds] [end-seconds] [fps] [width] [crop-height-fraction]
//   crop-height-fraction keeps the top part of the frame (e.g. 0.62 = top 62%), handy for
//   menu-bar recordings where the bottom is just wallpaper.
import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

let a = CommandLine.arguments
guard a.count >= 3 else { print("usage: make-gif <in.mov> <out.gif> [start] [end] [fps] [width] [cropHeightFraction]"); exit(1) }
let asset = AVURLAsset(url: URL(fileURLWithPath: a[1]))
let duration = CMTimeGetSeconds(asset.duration)
let start = a.count > 3 ? Double(a[3])! : 0
let end = a.count > 4 ? min(Double(a[4])!, duration) : duration
let fps = a.count > 5 ? Double(a[5])! : 12
let width = a.count > 6 ? CGFloat(Double(a[6])!) : 420
let cropFraction = a.count > 7 ? CGFloat(Double(a[7])!) : 1

let gen = AVAssetImageGenerator(asset: asset)
gen.appliesPreferredTrackTransform = true
gen.requestedTimeToleranceBefore = .zero
gen.requestedTimeToleranceAfter = .zero

let frameCount = Int((end - start) * fps)
let out = URL(fileURLWithPath: a[2])
guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
    print("can't create \(out.path)"); exit(1)
}
CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary

for i in 0..<frameCount {
    let t = CMTime(seconds: start + Double(i) / fps, preferredTimescale: 600)
    guard let src = try? gen.copyCGImage(at: t, actualTime: nil) else { continue }
    // Keep the top part, then scale to the target width.
    let keepH = Int(CGFloat(src.height) * cropFraction)
    guard let cropped = src.cropping(to: CGRect(x: 0, y: 0, width: src.width, height: keepH)) else { continue }
    let scale = width / CGFloat(cropped.width)
    let w = Int(width), h = Int(CGFloat(cropped.height) * scale)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
    ctx.interpolationQuality = .high
    ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
    if let frame = ctx.makeImage() { CGImageDestinationAddImage(dest, frame, frameProps) }
}
guard CGImageDestinationFinalize(dest) else { print("failed to write GIF"); exit(1) }
let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
print(String(format: "Wrote %@: %d frames, %.1f s, %.1f MB", out.lastPathComponent, frameCount, end - start, Double(size) / 1_000_000))
