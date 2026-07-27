import AppKit
import SwiftUI

/// Holds the one control panel window.
///
/// The app is an accessory with no Dock icon, so opening this has to activate the
/// process explicitly or the window arrives behind everything and unfocused.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let store: AgentStore
    private let settings: SettingsStore
    private let updater: Updater
    private var window: NSWindow?
    /// Quick start replaces the settings list until it is dismissed.
    private var showingQuickStart = false

    init(store: AgentStore, settings: SettingsStore, updater: Updater) {
        self.store = store
        self.settings = settings
        self.updater = updater
        super.init()
    }

    func show(quickStart: Bool = false) {
        // Rebuild rather than swap the root view, so the window can be sized for
        // whichever of the two it is showing.
        if window != nil, quickStart != showingQuickStart {
            window?.close()
            window = nil
        }
        showingQuickStart = quickStart
        // The notch mirrors the quick start, and shows the agents again otherwise.
        if quickStart {
            store.beginWalkthrough()
        } else {
            store.endWalkthrough()
        }
        if window == nil {
            window = makeWindow()
        }
        guard let window else { return }
        if !window.isVisible {
            window.center()
            if quickStart {
                sitClearOfTheNotch(window)
            }
        }
        // An accessory app owns no Dock tile, no ⌘Tab entry and no menu bar, so a
        // window opened this way cannot be found again once something covers it.
        // Becoming a regular app for as long as the window is up fixes all three,
        // and `windowWillClose` hands the badge back.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 470, height: showingQuickStart ? 660 : 640),
            // Full-size content with a hidden title: the traffic lights float over
            // the app's own header instead of sitting in a grey bar.
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = showingQuickStart ? "Welcome to T3Notch" : "T3Notch Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.055, green: 0.06, blue: 0.075, alpha: 1)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = CGSize(width: 430, height: 420)

        window.contentView = NSHostingView(rootView: rootView)
        return window
    }

    @ViewBuilder private var rootView: some View {
        if showingQuickStart {
            QuickStartView(store: store) { [weak self] in
                self?.finishQuickStart()
            }
        } else {
            SettingsView(store: store, settings: settings, updater: updater) { [weak self] in
                self?.show(quickStart: true)
            }
        }
    }

    /// Drops the window below the panel's reach. Centred, its header sits under the
    /// expanded notch, and the walkthrough is meant to be read while watching it.
    private func sitClearOfTheNotch(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let clearance: CGFloat = 300
        var frame = window.frame
        let highestTop = screen.frame.maxY - clearance
        frame.origin.y = min(frame.origin.y, highestTop - frame.height)
        // Never off the bottom of a short screen; overlapping beats unreachable.
        frame.origin.y = max(frame.origin.y, screen.visibleFrame.minY + 20)
        window.setFrame(frame, display: false)
    }

    private func finishQuickStart() {
        settings.set(\.needsQuickStart, to: false)
        window?.close()
    }

    /// Closing the quick start counts as finishing it. This hook fires only for a
    /// real close; `windowWillClose` also fires while the app is terminating, which
    /// would burn the onboarding on a first launch that was merely restarted.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if showingQuickStart {
            settings.set(\.needsQuickStart, to: false)
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        // The hosted view's `onDisappear` is not guaranteed for a window that is
        // only closed rather than released, and a notch stuck in walkthrough mode
        // would never hide again.
        store.endWalkthrough()
        // Give focus back rather than leaving an iconless app activated.
        NSApp.setActivationPolicy(.accessory)
    }
}
