import AppKit
import Combine
import SwiftUI

/// NSStatusItem + NSPopover, like Claude Usage's `StatusBarUIManager` (rather than MenuBarExtra,
/// which forces template rendering on the label and loses the status colors).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = UsageStore()
    let updater = Updater()
    let signIn = GitHubSignIn()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.imagePosition = .imageOnly

        let host = NSHostingController(rootView: PopoverView(store: store, updater: updater, signIn: signIn) { [weak self] in self?.openSettings() })
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient

        // objectWillChange fires before the new value lands; redraw on the next runloop turn.
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon(); self?.applyTheme() }
            .store(in: &cancellables)

        applyTheme()
        if UserDefaults.standard.bool(forKey: SettingsKey.notificationsEnabled) {
            store.notifier.requestAuthorization()
        }
        updateIcon()
        signIn.onSignedIn = { [weak self] in
            Task { await self?.store.refresh(notify: false, forceActivity: true) }
        }
        store.start()
        updater.notifier = store.notifier
        updater.start()
    }

    /// Applied per window (not NSApp-wide) so the menu-bar icon keeps matching the menu bar.
    private func applyTheme() {
        let appearance = ThemeChoice.current.appearance
        popover.appearance = appearance
        settingsWindow?.appearance = appearance
    }

    private func updateIcon() {
        statusItem.button?.image = MenuBarIconRenderer.render(store: store)
        statusItem.button?.toolTip = tooltip
    }

    private var tooltip: String {
        MetricKind.allCases.compactMap { k in
            store.metrics[k].map { "\(k.title): \(Int(($0.fraction * 100).rounded()))%" }
        }.joined(separator: "\n")
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Activate first: as a menu-bar-only app Quotacat is otherwise never the active app, and
            // the popover's controls then draw in macOS's dimmed "inactive window" style.
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func openSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(store: store, updater: updater, signIn: signIn)))
            w.title = "Quotacat Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
            applyTheme()
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
