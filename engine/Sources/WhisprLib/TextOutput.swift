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
    private struct PasteboardItemSnapshot: Sendable {
        let dataByType: [String: Data]
    }

    private struct ClipboardSession: Sendable {
        let token: String
        let snapshot: [PasteboardItemSnapshot]
    }

    private static let sessionTokenType = NSPasteboard.PasteboardType("com.whispr.session-token")

    public private(set) var mode: OutputMode
    public private(set) var typed: String = ""
    public var len: Int { typed.count }
    private let eventPoster: @Sendable (CGEvent) -> Void
    private var clipboardSession: ClipboardSession?
    private var clipboardDidWrite = false
    private var clipboardLostOwnership = false

    public init(
        mode: OutputMode,
        eventPoster: @escaping @Sendable (CGEvent) -> Void = { $0.post(tap: .cgSessionEventTap) }
    ) {
        self.mode = mode
        self.eventPoster = eventPoster
    }

    public func setMode(_ mode: OutputMode) {
        if self.mode != mode {
            restoreClipboardIfOwned()
        }
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
        restoreClipboardIfOwned()
    }

    /// Reset state to zero without backspacing. Called at session start.
    public func clear() {
        restoreClipboardIfOwned()
        typed = ""
    }

    /// End the current output session without mutating the text that has
    /// already been inserted into the focused app.
    public func finishSession() {
        restoreClipboardIfOwned()
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
                guard let ev = makeKeyboardEvent(
                    virtualKey: 0,
                    keyDown: pressed
                )
                else { continue }
                let chars = Array(str.utf16)
                ev.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
                post(ev)
            }
        }
    }

    private func backspace(_ n: Int) {
        for _ in 0..<n {
            for pressed in [true, false] {
                guard let ev = makeKeyboardEvent(
                    virtualKey: 51,
                    keyDown: pressed
                )
                else { continue }
                post(ev)
            }
        }
    }

    private func paste(_ text: String) {
        ensureClipboardSession()

        if clipboardLostOwnership {
            type(text)
            return
        }

        if clipboardDidWrite,
           NSPasteboard.general.string(forType: Self.sessionTokenType) != currentSessionToken() {
            clipboardLostOwnership = true
            type(text)
            return
        }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setString(currentSessionToken(), forType: Self.sessionTokenType)
        clipboardDidWrite = true

        // Synthesise Cmd+V.
        for pressed in [true, false] {
            guard let ev = makeKeyboardEvent(
                virtualKey: 9,
                keyDown: pressed,
                flags: .maskCommand
            )
            else { continue }
            post(ev)
        }
    }

    private func ensureClipboardSession() {
        guard clipboardSession == nil else { return }
        clipboardSession = ClipboardSession(
            token: UUID().uuidString,
            snapshot: snapshot(NSPasteboard.general)
        )
        clipboardDidWrite = false
        clipboardLostOwnership = false
    }

    private func currentSessionToken() -> String {
        clipboardSession?.token ?? ""
    }

    private func restoreClipboardIfOwned() {
        guard let session = clipboardSession else { return }
        defer {
            clipboardSession = nil
            clipboardDidWrite = false
            clipboardLostOwnership = false
        }

        let pasteboard = NSPasteboard.general
        guard !clipboardLostOwnership,
              pasteboard.string(forType: Self.sessionTokenType) == session.token else {
            return
        }

        pasteboard.clearContents()
        guard !session.snapshot.isEmpty else { return }

        let items = session.snapshot.map { snapshot -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in snapshot.dataByType {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        pasteboard.writeObjects(items)
    }

    private func snapshot(_ pasteboard: NSPasteboard) -> [PasteboardItemSnapshot] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var dataByType: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dataByType[type.rawValue] = data
                }
            }
            return PasteboardItemSnapshot(dataByType: dataByType)
        }
    }

    private func makeKeyboardEvent(
        virtualKey: CGKeyCode,
        keyDown: Bool,
        flags: CGEventFlags = []
    ) -> CGEvent? {
        let source = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: keyDown)
        event?.flags = flags
        return event
    }

    private func post(_ event: CGEvent) {
        eventPoster(event)
    }
}
#endif
