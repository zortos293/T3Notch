import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: AgentStore!
    private var settings: SettingsStore!
    private var panelController: NotchPanelController?
    private var settingsWindow: SettingsWindowController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        settings = SettingsStore()
        store = AgentStore(settings: settings)
        let controller = NotchPanelController(store: store)
        panelController = controller
        settingsWindow = SettingsWindowController(store: store, settings: settings)

        // Applied immediately rather than on the next poll, so a flipped switch
        // feels like it did something.
        settings.onChange = { [weak self] in
            self?.store.applySettings()
            self?.panelController?.refresh()
        }

        controller.start()
        installStatusItem()
        installMainMenu()
        store.bootstrap()

        if settings.values.needsQuickStart {
            // After bootstrap, so the connection test has a chance to pass on a
            // machine that is already set up.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                settingsWindow?.show(quickStart: true)
            }
        }

        // The window frame is fixed; this only re-syncs hit-testing after the
        // store flips presentation on its own (attention, completion, etc).
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panelController?.refresh()
            }
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.statusItemImage()
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Expand Notch", action: #selector(expand), keyEquivalent: "e"))
        menu.addItem(
            NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        )
        menu.addItem(
            NSMenuItem(title: "Quick Start…", action: #selector(openQuickStart), keyEquivalent: "")
        )
        menu.addItem(NSMenuItem(title: "Reconnect", action: #selector(reconnect), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit T3Notch", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    /// The menu bar shown while a window is open and the app is briefly a regular
    /// one. Without it that bar would be empty, and the shortcuts a window needs —
    /// ⌘C on the selectable diagnostics, ⌘W, ⌘Q — would do nothing.
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About T3Notch",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide T3Notch",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        appMenu.addItem(
            withTitle: "Quit T3Notch",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Standard editing actions travel the responder chain, so they are wired by
        // selector name rather than to any particular object.
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        let editActions: [(title: String, selector: String, key: String, shift: Bool)] = [
            ("Undo", "undo:", "z", false),
            ("Redo", "redo:", "z", true),
            ("Cut", "cut:", "x", false),
            ("Copy", "copy:", "c", false),
            ("Paste", "paste:", "v", false),
            ("Select All", "selectAll:", "a", false),
        ]
        for action in editActions {
            if action.title == "Cut" { editMenu.addItem(.separator()) }
            let item = NSMenuItem(
                title: action.title,
                action: NSSelectorFromString(action.selector),
                keyEquivalent: action.key
            )
            if action.shift {
                item.keyEquivalentModifierMask = [.command, .shift]
            }
            editMenu.addItem(item)
        }
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            withTitle: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        windowMenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    /// Menu bar glyph: the panel's own silhouette, drawn as a template image so
    /// it tints itself for light, dark, and highlighted menu bars.
    private static func statusItemImage() -> NSImage {
        let size = NSSize(width: 20, height: 11)
        // `flipped: true` keeps NotchShape's top-down geometry pointing down.
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let path = NotchShape(topRadius: 3, bottomRadius: 4.5).path(in: rect)
            context.addPath(path.cgPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "T3Notch"
        return image
    }

    @objc private func expand() {
        store.expand()
        panelController?.refresh()
    }

    @objc private func openSettings() {
        settingsWindow?.show()
    }

    @objc private func openQuickStart() {
        settingsWindow?.show(quickStart: true)
    }

    @objc private func reconnect() {
        store.bootstrap()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
