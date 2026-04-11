#if os(macOS)
import AppKit
import Foundation
import SwiftUI

/// Wrapper around an NSWindow that hosts a SwiftUI preferences form.
/// Held by `StatusBar` for its lifetime so the window survives across
/// open/close cycles.
@MainActor
final class PreferencesWindow {
    private weak var whispr: Whispr?
    private var window: NSWindow?

    init(whispr: Whispr) {
        self.whispr = whispr
    }

    func show() {
        guard let whispr else { return }

        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = PreferencesView(
            draft: whispr.config,
            onSave: { [weak whispr] new in
                whispr?.applyConfigUpdate(new)
            },
            onClose: { [weak self] in
                self?.window?.close()
            }
        )

        let host = NSHostingController(rootView: view)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "Whispr Preferences"
        w.contentViewController = host
        w.center()
        w.isReleasedWhenClosed = false
        window = w

        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

// MARK: - SwiftUI view

private struct PreferencesView: View {
    @State var draft: Config
    let onSave: (Config) -> Void
    let onClose: () -> Void

    var body: some View {
        Form {
            Section {
                Picker("Hotkey", selection: $draft.hotkey) {
                    ForEach(HotkeyModifier.allCases, id: \.self) { mod in
                        Text(mod.displayName).tag(mod)
                    }
                }
                Text("Hold the selected modifier to start recording. Release to finalize.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Output", selection: $draft.outputMode) {
                    ForEach(OutputMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Text("Type keys is per-character; clipboard is faster for long transcripts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField(
                    "Idle timeout (seconds)",
                    value: $draft.idleTimeout,
                    format: .number
                )
                Text("Unload the model after this many seconds of inactivity. 0 = never unload.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Chunk size", selection: $draft.chunkSize) {
                    ForEach(ChunkSize.allCases, id: \.self) { c in
                        Text(c.displayName).tag(c)
                    }
                }
                Text("Applies after the next model load.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(draft)
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
            .background(.bar)
        }
        .frame(width: 440, height: 420)
    }
}
#endif
