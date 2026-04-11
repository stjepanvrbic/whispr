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
/// `typed` is the full grapheme-cluster string already emitted in the
/// current session — it's the single source of truth for "what is on
/// screen right now" so that `sync(to:)` can compute which prefix needs
/// rewinding when vocabulary substitution changes an earlier character.
/// `len` is a convenience for the append-only fast path and equals
/// `typed.count` at all times.
public final class TextOutput: @unchecked Sendable {
    public private(set) var mode: OutputMode
    public private(set) var typed: String = ""
    public var len: Int { typed.count }

    public init(mode: OutputMode) {
        self.mode = mode
    }

    public func setMode(_ mode: OutputMode) {
        self.mode = mode
    }

    public func append(_ text: String) {
        guard !text.isEmpty else { return }
        emit(text)
        typed += text
    }

    /// Rewind any divergent suffix of `typed` and emit whatever part of
    /// `desired` extends beyond the common prefix, so the on-screen text
    /// ends up matching `desired`. When `desired` is a pure extension of
    /// `typed` this degenerates to a plain append — the rewind branch is
    /// only taken when vocabulary substitution changed a character that
    /// was already typed.
    public func sync(to desired: String) {
        let tc = Array(typed)
        let dc = Array(desired)
        var common = 0
        while common < tc.count, common < dc.count, tc[common] == dc[common] {
            common += 1
        }

        if common < tc.count {
            backspace(tc.count - common)
            typed = String(tc.prefix(common))
        }

        if common < dc.count {
            let addition = String(dc.suffix(dc.count - common))
            emit(addition)
            typed += addition
        }
    }

    /// Backspace all typed characters and reset state.
    /// Called when a session is cancelled (Escape).
    public func cancel() {
        if !typed.isEmpty { backspace(typed.count) }
        typed = ""
    }

    /// Reset state to zero without backspacing. Called at session start.
    public func clear() {
        typed = ""
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
