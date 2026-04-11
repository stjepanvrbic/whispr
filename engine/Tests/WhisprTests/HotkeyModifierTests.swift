#if os(macOS)
import CoreGraphics
import Foundation
import Testing

@testable import WhisprLib

@Suite("HotkeyModifier")
struct HotkeyModifierTests {

    @Test("CGEventFlags mapping")
    func flagMapping() {
        #expect(HotkeyModifier.option.flag       == .maskAlternate)
        #expect(HotkeyModifier.rightOption.flag  == .maskAlternate)
        #expect(HotkeyModifier.command.flag      == .maskCommand)
        #expect(HotkeyModifier.rightCommand.flag == .maskCommand)
        #expect(HotkeyModifier.control.flag      == .maskControl)
        #expect(HotkeyModifier.shift.flag        == .maskShift)
        #expect(HotkeyModifier.fn.flag           == .maskSecondaryFn)
    }

    @Test("isRightSide is only true for explicit right-side cases")
    func rightSideFlag() {
        for mod in HotkeyModifier.allCases {
            let isRight = (mod == .rightOption || mod == .rightCommand)
            #expect(mod.isRightSide == isRight)
        }
    }

    @Test("displayName is non-empty for every case")
    func displayNameNonEmpty() {
        for mod in HotkeyModifier.allCases {
            #expect(!mod.displayName.isEmpty)
        }
    }

    @Test("JSON encoding uses snake_case for compound names")
    func snakeCaseEncoding() throws {
        let encoder = JSONEncoder()
        for (mod, expected) in [
            (HotkeyModifier.option,       #""option""#),
            (.command,                    #""command""#),
            (.control,                    #""control""#),
            (.shift,                      #""shift""#),
            (.fn,                         #""fn""#),
            (.rightOption,                #""right_option""#),
            (.rightCommand,               #""right_command""#),
        ] {
            let data = try encoder.encode(mod)
            #expect(String(data: data, encoding: .utf8) == expected)
        }
    }

    @Test("Unknown string decodes fail (caller is responsible for fallback)")
    func decodeUnknownThrows() {
        let json = Data(#""bananas""#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(HotkeyModifier.self, from: json)
        }
    }

    @Test("All cases are distinct")
    func distinctCases() {
        let raws = HotkeyModifier.allCases.map(\.rawValue)
        #expect(Set(raws).count == raws.count)
    }
}
#endif
