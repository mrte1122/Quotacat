import AppKit
import SwiftUI

/// `Quotacat --snapshot <dir>`: fetch once, then render the popover (bars and radial meters)
/// and every menu-bar icon style to PNGs without touching the real status bar. Used for visual checks.
@MainActor
enum Snapshot {
    static func run(outDir: String) -> Never {
        _ = NSApplication.shared
        let store = UsageStore()
        let dir = URL(fileURLWithPath: outDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            if CommandLine.arguments.contains("--demo") {
                store.loadDemo()
            } else {
                await store.refresh(notify: false)
            }
            let d = UserDefaults.standard
            let saved = d.string(forKey: SettingsKey.iconStyle)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                for style in IconStyle.allCases {
                    d.set(style.rawValue, forKey: SettingsKey.iconStyle)
                    let icon = MenuBarIconRenderer.render(store: store)
                    write(icon, appearance: appearance, scale: 3,
                          to: dir.appendingPathComponent("icon-\(style.rawValue)-\(appearance == .aqua ? "light" : "dark").png"))
                }
            }
            d.set(saved, forKey: SettingsKey.iconStyle)

            // Render through a real NSHostingView (not ImageRenderer) so AppKit-backed
            // buttons and links draw instead of placeholder blocks.
            let savedRadial = d.object(forKey: SettingsKey.radialMeters)
            let savedTab = d.object(forKey: SettingsKey.popoverTab)
            let variants: [(name: String, appearance: NSAppearance.Name, radial: Bool, tab: String)] = [
                ("light", .aqua, false, "quotas"), ("dark", .darkAqua, false, "quotas"),
                ("radial-light", .aqua, true, "quotas"), ("radial-dark", .darkAqua, true, "quotas"),
                ("pulls-light", .aqua, false, "pulls"), ("pulls-dark", .darkAqua, false, "pulls"),
                ("actions-light", .aqua, false, "actions"), ("actions-dark", .darkAqua, false, "actions"),
            ]
            for (name, appearanceName, radial, tab) in variants {
                d.set(radial, forKey: SettingsKey.radialMeters)
                d.set(tab, forKey: SettingsKey.popoverTab)
                let view = PopoverView(store: store, updater: Updater(), openSettings: {})
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: appearanceName)
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = host.appearance
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(nanoseconds: 400_000_000)   // let SwiftUI finish its first pass
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: dir.appendingPathComponent("popover-\(name).png"))
                }
            }
            d.set(savedRadial, forKey: SettingsKey.radialMeters)
            d.set(savedTab, forKey: SettingsKey.popoverTab)
            print("Snapshots written to \(dir.path)")
            exit(0)
        }
        RunLoop.main.run()
        exit(0)
    }

    private static func write(_ image: NSImage, appearance: NSAppearance.Name, scale: CGFloat, to url: URL) {
        let size = NSSize(width: image.size.width + 8, height: max(image.size.height, 22))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            (appearance == .darkAqua ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
            NSRect(origin: .zero, size: size).fill()
            let r = NSRect(x: 4, y: (size.height - image.size.height) / 2, width: image.size.width, height: image.size.height)
            if image.isTemplate {
                // Emulate how the status bar tints template images.
                let tinted = NSImage(size: image.size, flipped: false) { rect in
                    image.draw(in: rect)
                    NSColor.labelColor.set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: r)
            } else {
                image.draw(in: r)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
