#if os(macOS)
import AppKit
import CoreGraphics
import Foundation

/// Types transcribed text into the currently focused app.
///
/// Two output paths:
///   • `.keypress`  — synthesise a unicode keyDown/keyUp per character
///   • `.clipboard` — put the text on NSPasteboard and post a synthetic Cmd+V
///
/// `len` tracks the total grapheme-cluster count typed in the current
/// session — it's the single source of truth for "how much of this
/// monotonic partial have we already output" in `Whispr.onKeyDown`.
public final class TextOutput: @unchecked Sendable {
    public private(set) var mode: OutputMode
    public private(set) var len: Int = 0

    public init(mode: OutputMode) {
        self.mode = mode
    }

    public func setMode(_ mode: OutputMode) {
        self.mode = mode
    }

    public func append(_ text: String) {
        guard !text.isEmpty else { return }
        emit(text)
        len += text.count
    }

    /// Backspace all typed characters and reset `len`.
    /// Called when a session is cancelled (Escape).
    public func cancel() {
        if len > 0 { backspace(len) }
        len = 0
    }

    /// Reset `len` to zero without backspacing. Called at session start.
    public func clear() {
        len = 0
    }

    // MARK: - Emission

    private func emit(_ text: String) {
        switch mode {
        case .keypress:  type(text)
        case .clipboard: paste(text)
        }
    }

    private func type(_ text: String) {
        for ch in text {
            let str = String(ch)
            for pressed in [true, false] {
                guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: pressed)
                else { continue }
                let chars = Array(str.utf16)
                ev.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
                ev.post(tap: .cgSessionEventTap)
            }
        }
    }

    private func backspace(_ n: Int) {
        for _ in 0..<n {
            for pressed in [true, false] {
                guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: pressed)
                else { continue }
                ev.post(tap: .cgSessionEventTap)
            }
        }
    }

    private func paste(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        // Synthesise Cmd+V.
        for pressed in [true, false] {
            guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: pressed)
            else { continue }
            ev.flags = .maskCommand
            ev.post(tap: .cgSessionEventTap)
        }
    }
}
#endif
