#if os(macOS)
import Carbon.HIToolbox
import CoreGraphics
import Testing

@testable import WhisprLib

@Suite("KeyboardMonitor")
struct KeyboardMonitorTests {
    private func flags(_ flags: CGEventFlags, rawBits: UInt64 = 0) -> CGEventFlags {
        CGEventFlags(rawValue: flags.rawValue | rawBits)
    }

    @Test("Option press and release fire once each")
    func optionPressAndReleaseFireOnce() {
        let monitor = KeyboardMonitor(modifier: .option)
        var events: [String] = []
        monitor.onKeyDown = { events.append("down") }
        monitor.onKeyUp = { events.append("up") }

        monitor.handleFlagsChanged(keycode: CGKeyCode(kVK_Option), flags: .maskAlternate)
        monitor.handleFlagsChanged(keycode: CGKeyCode(kVK_Option), flags: .maskAlternate)
        monitor.handleFlagsChanged(keycode: CGKeyCode(kVK_Option), flags: [])
        monitor.handleFlagsChanged(keycode: CGKeyCode(kVK_Option), flags: [])

        #expect(events == ["down", "up"])
    }

    @Test("Option ignores unrelated modifier transitions while held")
    func optionIgnoresUnrelatedModifierTransitions() {
        let monitor = KeyboardMonitor(modifier: .option)
        var events: [String] = []
        monitor.onKeyDown = { events.append("down") }
        monitor.onKeyUp = { events.append("up") }

        monitor.handleFlagsChanged(keycode: CGKeyCode(kVK_Option), flags: .maskAlternate)
        monitor.handleFlagsChanged(
            keycode: CGKeyCode(kVK_Command),
            flags: [.maskAlternate, .maskCommand]
        )
        monitor.handleFlagsChanged(keycode: CGKeyCode(kVK_Command), flags: .maskAlternate)

        #expect(events == ["down"])

        monitor.handleFlagsChanged(keycode: CGKeyCode(kVK_Option), flags: [])
        #expect(events == ["down", "up"])
    }

    @Test("Generic Option stays held until the last side is released")
    func optionStaysHeldAcrossSideSwitches() {
        let monitor = KeyboardMonitor(modifier: .option)
        var events: [String] = []
        monitor.onKeyDown = { events.append("down") }
        monitor.onKeyUp = { events.append("up") }

        monitor.handleFlagsChanged(keycode: CGKeyCode(kVK_Option), flags: .maskAlternate)
        monitor.handleFlagsChanged(keycode: CGKeyCode(kVK_RightOption), flags: .maskAlternate)
        monitor.handleFlagsChanged(keycode: CGKeyCode(kVK_Option), flags: .maskAlternate)

        #expect(events == ["down"])

        monitor.handleFlagsChanged(keycode: CGKeyCode(kVK_RightOption), flags: [])
        #expect(events == ["down", "up"])
    }

    @Test("Right Option ignores left Option and releases when the right key lifts")
    func rightOptionTracksOnlyRightSide() {
        let monitor = KeyboardMonitor(modifier: .rightOption)
        var events: [String] = []
        monitor.onKeyDown = { events.append("down") }
        monitor.onKeyUp = { events.append("up") }

        monitor.handleFlagsChanged(keycode: CGKeyCode(kVK_Option), flags: .maskAlternate)
        #expect(events.isEmpty)

        monitor.handleFlagsChanged(
            keycode: CGKeyCode(kVK_RightOption),
            flags: flags(.maskAlternate, rawBits: 0x40)
        )
        monitor.handleFlagsChanged(
            keycode: CGKeyCode(kVK_Option),
            flags: flags(.maskAlternate, rawBits: 0x40)
        )

        #expect(events == ["down"])

        monitor.handleFlagsChanged(keycode: CGKeyCode(kVK_RightOption), flags: .maskAlternate)
        #expect(events == ["down", "up"])
    }

    @Test("Right Command ignores left Command and releases when the right key lifts")
    func rightCommandTracksOnlyRightSide() {
        let monitor = KeyboardMonitor(modifier: .rightCommand)
        var events: [String] = []
        monitor.onKeyDown = { events.append("down") }
        monitor.onKeyUp = { events.append("up") }

        monitor.handleFlagsChanged(keycode: CGKeyCode(kVK_Command), flags: .maskCommand)
        #expect(events.isEmpty)

        monitor.handleFlagsChanged(
            keycode: CGKeyCode(kVK_RightCommand),
            flags: flags(.maskCommand, rawBits: 0x10)
        )
        monitor.handleFlagsChanged(
            keycode: CGKeyCode(kVK_Command),
            flags: flags(.maskCommand, rawBits: 0x10)
        )

        #expect(events == ["down"])

        monitor.handleFlagsChanged(keycode: CGKeyCode(kVK_RightCommand), flags: .maskCommand)
        #expect(events == ["down", "up"])
    }
}
#endif
