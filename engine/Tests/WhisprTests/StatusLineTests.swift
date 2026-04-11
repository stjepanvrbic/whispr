#if os(macOS)
import Foundation
import Testing

@testable import WhisprLib

@Suite("StatusLine formatting")
struct StatusLineTests {

    @Test("Ready state")
    func ready() {
        #expect(StatusLine.text(for: .ready) == "Status: Ready")
    }

    @Test("Recording state")
    func recording() {
        #expect(StatusLine.text(for: .recording) == "Status: Recording…")
    }

    @Test("Loading state")
    func loading() {
        #expect(StatusLine.text(for: .loading) == "Status: Loading model…")
    }

    @Test("Idle state mentions the model is unloaded")
    func idle() {
        let text = StatusLine.text(for: .idle)
        #expect(text.contains("Idle"))
        #expect(text.contains("unloaded"))
    }

    @Test("Disabled state")
    func disabled() {
        #expect(StatusLine.text(for: .disabled) == "Status: Disabled")
    }

    @Test("Every SessionState has a distinct status line")
    func allDistinct() {
        let all: [SessionState] = [.ready, .recording, .loading, .idle, .disabled]
        let texts = Set(all.map { StatusLine.text(for: $0) })
        #expect(texts.count == all.count)
    }
}
#endif
