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
                Text("Paste via clipboard is recommended: it streams faster, preserves the clipboard, and is more reliable in apps like Chrome. Type keys remains as a legacy fallback.")
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

            Section {
                Toggle("Custom vocabulary", isOn: $draft.vocabularyEnabled)
                Button("Open vocabulary file…") {
                    openVocabularyFile()
                }
                Text("""
                    Canonical word first, then misheard variants separated by \
                    `|`, one entry per line. Lines starting with `#` are \
                    comments. Click "Reload vocabulary" in the menu bar after \
                    editing.
                    """)
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
        .frame(width: 440, height: 520)
    }

    /// Ensure `~/.whispr/vocabulary.txt` exists (creating an empty
    /// commented skeleton if missing) and open it in the user's default
    /// text editor.
    private func openVocabularyFile() {
        let url = Vocabulary.vocabularyFile
        if !FileManager.default.fileExists(atPath: url.path) {
            let header = """
                # Whispr custom vocabulary
                #
                # Format: canonical|alias1|alias2|...
                #   - Canonical form comes first; aliases after pipes.
                #   - Matching is case-insensitive and word-boundary aware.
                #   - Lines starting with # and blank lines are ignored.
                #
                # Click "Reload vocabulary" in the menu bar after editing.

                """
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? header.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }
}
#endif
