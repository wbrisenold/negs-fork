import XCTest
@testable import NegsApp

@MainActor final class ColorSeparationPresetTests: XCTestCase {
    func testToneStylesAreStableIdentifiersAndRYBPresetsWrapAround() {
        XCTAssertEqual(ColorSeparationPreset.matching(rule: "split_complementary"), .splitComplementary)
        XCTAssertEqual(ColorSeparationPreset.matching(rule: "unknown_old_value"), .manual)
        XCTAssertEqual(ColorSeparationPreset.complementary.complementaryHue(target: 350), 170, accuracy: 0.01)
        XCTAssertEqual(ColorSeparationPreset.triadic.complementaryHue(target: 350), 55, accuracy: 0.1)
    }

    func testApplyingPresetPreservesAnchorAndStrengthAndStoresRule() {
        let model = EditorModel(sidecars: nil)
        defer { model.shutdown() }
        model.set("post.color_separation.target_hue", .number(350))
        model.set("post.color_separation.strength", .number(42))
        model.set("post.color_separation.neutral_protection", .number(25))

        model.applyColorSeparationPreset(.splitComplementary)

        XCTAssertEqual(model.value("post.color_separation.target_hue"), .number(350))
        XCTAssertEqual(model.value("post.color_separation.harmony_rule"), .string("split_complementary"))
        XCTAssertEqual(model.value("post.color_separation.strength"), .number(42))
        XCTAssertEqual(model.value("post.color_separation.neutral_protection"), .number(25))
    }

    func testSelectingTonePresetActivatesTheGradeWhenStrengthIsZero() {
        let model = EditorModel(sidecars: nil)
        defer { model.shutdown() }
        model.set("post.color_separation.strength", .number(0))

        model.applyColorSeparationPreset(.complementary)

        XCTAssertEqual(model.value("post.color_separation.strength"), .number(72))
    }
}
