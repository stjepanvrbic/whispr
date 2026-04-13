#if os(macOS)
import Carbon.HIToolbox
import CoreGraphics

/// The modifier key the user holds to start a recording session.
///
/// Whispr's UX is push-to-talk: hold a modifier, speak, release. This enum
/// is the set of modifier keys that work that way — keys you can hold down
/// on their own without triggering an OS action. Letter keys and
/// modifier+letter combos are intentionally not supported (they'd conflict
/// with existing app shortcuts and break the "hold to talk" feel).
public enum HotkeyModifier: String, Codable, Sendable, CaseIterable {
    case option
    case command
    case control
    case shift
    case fn
    case rightOption  = "right_option"
    case rightCommand = "right_command"

    /// CGEventFlags bit that is set while this modifier is held.
    ///
    /// Left and right variants of Option/Command share the same mask bit —
    /// they're disambiguated via device-dependent bits on the raw flags,
    /// which `KeyboardMonitor` handles separately.
    public var flag: CGEventFlags {
        switch self {
        case .option, .rightOption:   return .maskAlternate
        case .command, .rightCommand: return .maskCommand
        case .control:                return .maskControl
        case .shift:                  return .maskShift
        case .fn:                     return .maskSecondaryFn
        }
    }

    /// Physical keycodes that may legitimately change this modifier's held
    /// state. `KeyboardMonitor` ignores `flagsChanged` events from other
    /// modifiers so unrelated transitions cannot fake a release.
    var acceptedKeyCodes: Set<CGKeyCode> {
        switch self {
        case .option:
            return [CGKeyCode(kVK_Option), CGKeyCode(kVK_RightOption)]
        case .command:
            return [CGKeyCode(kVK_Command), CGKeyCode(kVK_RightCommand)]
        case .control:
            return [CGKeyCode(kVK_Control), CGKeyCode(kVK_RightControl)]
        case .shift:
            return [CGKeyCode(kVK_Shift), CGKeyCode(kVK_RightShift)]
        case .fn:
            return [CGKeyCode(kVK_Function)]
        case .rightOption:
            return [CGKeyCode(kVK_RightOption)]
        case .rightCommand:
            return [CGKeyCode(kVK_RightCommand)]
        }
    }

    /// `true` if this case targets specifically the right-hand physical key.
    public var isRightSide: Bool {
        switch self {
        case .rightOption, .rightCommand: return true
        default: return false
        }
    }

    /// Human-readable label for UI pickers.
    public var displayName: String {
        switch self {
        case .option:       return "Option"
        case .command:      return "Command"
        case .control:      return "Control"
        case .shift:        return "Shift"
        case .fn:           return "Fn"
        case .rightOption:  return "Right Option"
        case .rightCommand: return "Right Command"
        }
    }
}
#endif
