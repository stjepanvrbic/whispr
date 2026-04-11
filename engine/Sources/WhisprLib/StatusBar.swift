#if os(macOS)
import AppKit
import Foundation

/// Owns the menu bar NSStatusItem and its menu. Updates icon and labels
/// in response to `Whispr.onStateChange`.
///
/// Click (left or right) opens the menu — the macOS convention for status
/// items that aren't plain buttons.
@MainActor
public final class StatusBar: NSObject {
    private let statusItem: NSStatusItem
    private weak var whispr: Whispr?
    private var currentState: SessionState = .ready

    // Strong refs so these don't get released while open or running.
    private var prefsController: PreferencesWindow?
    private var updater: Updater?

    public init(whispr: Whispr) {
        self.whispr = whispr
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        rebuildMenu()
        refreshIcon()
    }

    public func setState(_ state: SessionState) {
        currentState = state
        rebuildMenu()
        refreshIcon()
    }

    // MARK: - Icon

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        let symbolName: String
        switch currentState {
        case .recording:              symbolName = "waveform.circle.fill"
        case .disabled:               symbolName = "waveform.slash"
        case .loading, .idle, .ready: symbolName = "waveform"
        }
        if let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "Whispr"
        ) {
            image.isTemplate = true
            button.image = image
        } else {
            button.title = "W"
        }
        button.toolTip = "Whispr — \(StatusLine.text(for: currentState))"
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()

        let header = NSMenuItem(title: "Whispr", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let status = NSMenuItem(
            title: StatusLine.text(for: currentState),
            action: nil,
            keyEquivalent: ""
        )
        status.isEnabled = false
        menu.addItem(status)

        menu.addItem(NSMenuItem.separator())

        let enableItem = NSMenuItem(
            title: "Enabled",
            action: #selector(toggleEnabled),
            keyEquivalent: ""
        )
        enableItem.target = self
        enableItem.state = (whispr?.config.enabled ?? true) ? .on : .off
        menu.addItem(enableItem)

        menu.addItem(NSMenuItem.separator())

        let prefs = NSMenuItem(
            title: "Preferences…",
            action: #selector(openPreferences),
            keyEquivalent: ","
        )
        prefs.target = self
        menu.addItem(prefs)

        let update = NSMenuItem(
            title: "Update Whispr…",
            action: #selector(runUpdate),
            keyEquivalent: ""
        )
        update.target = self
        menu.addItem(update)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(
            title: "Quit Whispr",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        self.statusItem.menu = menu
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        guard let whispr else { return }
        whispr.setEnabled(!whispr.config.enabled)
    }

    @objc private func openPreferences() {
        guard let whispr else { return }
        if prefsController == nil {
            prefsController = PreferencesWindow(whispr: whispr)
        }
        prefsController?.show()
    }

    @objc private func runUpdate() {
        if updater == nil {
            updater = Updater()
        }
        updater?.run()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// Pure text formatting for the status line — separated so it can be
/// unit-tested without instantiating AppKit.
public enum StatusLine {
    public static func text(for state: SessionState) -> String {
        switch state {
        case .ready:     return "Status: Ready"
        case .recording: return "Status: Recording…"
        case .loading:   return "Status: Loading model…"
        case .idle:      return "Status: Idle (model unloaded)"
        case .disabled:  return "Status: Disabled"
        }
    }
}
#endif
