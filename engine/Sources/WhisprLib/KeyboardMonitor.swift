#if os(macOS)
import CoreGraphics
import Foundation

/// Watches a single modifier key and fires onKeyDown when the user starts
/// holding it and onKeyUp when they release it. Also surfaces Escape so
/// the daemon can cancel an in-flight session.
///
/// The watched modifier can be swapped at runtime via `setModifier(_:)`
/// without rebuilding the CGEventTap — the callback just reads the
/// current `watchedFlag` on every event.
final class KeyboardMonitor: @unchecked Sendable {
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    var onEscape: (() -> Void)?

    fileprivate var tapPort: CFMachPort?
    fileprivate var isHeld = false

    // Watched modifier state. Mutated by setModifier on the main thread,
    // read by keyboardCallback which also runs on the main thread (the
    // tap's run loop source is attached to CFRunLoopGetCurrent).
    fileprivate var watchedFlag: CGEventFlags = .maskAlternate
    fileprivate var watchedSideMask: UInt64 = 0

    init(modifier: HotkeyModifier = .option) {
        setModifier(modifier)
    }

    /// Swap which modifier key is watched. Safe to call at any time; if
    /// the old modifier is currently held, a synthetic onKeyUp fires first
    /// so the session cleanly ends before the switch.
    func setModifier(_ mod: HotkeyModifier) {
        if isHeld {
            isHeld = false
            onKeyUp?()
        }
        watchedFlag = mod.flag
        watchedSideMask = Self.deviceBit(for: mod)
    }

    /// Device-dependent bit that distinguishes left-side from right-side
    /// for the modifiers that have distinct sides. Zero means "either side
    /// is fine" — the default for most HotkeyModifier cases.
    ///
    /// Constants from `<IOKit/hidsystem/ev_keymap.h>`; they're not exposed
    /// in CoreGraphics so we inline them here.
    private static func deviceBit(for mod: HotkeyModifier) -> UInt64 {
        switch mod {
        case .rightOption:  return 0x40     // NX_DEVICERALTKEYMASK
        case .rightCommand: return 0x10     // NX_DEVICERCMDKEYMASK
        default:            return 0
        }
    }

    func install() {
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        var tap = makeTap(mask: mask, refcon: refcon)
        if tap == nil {
            log("""
                Accessibility permission required to detect keyboard events.
                  1. Open System Settings > Privacy & Security > Accessibility
                  2. Find 'Whispr' in the list and toggle it ON
                     (if it's not there, click +, navigate to ~/.whispr, and add Whispr.app)
                whispr will start automatically once permission is granted.
                """)
            while tap == nil {
                Thread.sleep(forTimeInterval: 2)
                tap = makeTap(mask: mask, refcon: refcon)
            }
            log("Accessibility ✓")
        }

        tapPort = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    }

    private func makeTap(mask: CGEventMask, refcon: UnsafeMutableRawPointer) -> CFMachPort? {
        CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: keyboardCallback,
            userInfo: refcon
        )
    }
}

private func keyboardCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passRetained(event) }
    let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(refcon).takeUnretainedValue()

    // Event taps can be disabled by the system if a callback takes too
    // long — re-enable and keep going.
    if type == .tapDisabledByTimeout {
        if let tap = monitor.tapPort {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passRetained(event)
    }

    if type == .keyDown {
        // Escape = cancel current session, regardless of modifier state.
        if event.getIntegerValueField(.keyboardEventKeycode) == 53 {
            monitor.onEscape?()
        }
        return Unmanaged.passRetained(event)
    }

    if type == .flagsChanged {
        let flags = event.flags
        let maskHeld = flags.contains(monitor.watchedFlag)
        let sideOK = monitor.watchedSideMask == 0
            || (flags.rawValue & monitor.watchedSideMask) != 0
        let held = maskHeld && sideOK

        if held && !monitor.isHeld {
            monitor.isHeld = true
            monitor.onKeyDown?()
        } else if !held && monitor.isHeld {
            monitor.isHeld = false
            monitor.onKeyUp?()
        }
    }

    return Unmanaged.passRetained(event)
}
#endif
