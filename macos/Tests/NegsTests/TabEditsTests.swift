import XCTest
@testable import NegsApp

/// The list under a tab's count lists what the count counts, and Reset on the
/// tab clears both in one undo step.
@MainActor final class TabEditsTests: XCTestCase {
    func testTheListHasAsManyEditsAsTheCount() {
        let model = EditorModel()
        for tab in InspectorTab.allCases {
            XCTAssertEqual(InspectorEdits.edits(tab, model).count, InspectorEdits.count(tab, model), "\(tab)")
        }
        model.set("prep.contrast", .number(12))
        model.set("prep.shadows", .number(-30))
        model.set("film_render.halation.strength", .number(2))
        for tab in InspectorTab.allCases {
            XCTAssertEqual(InspectorEdits.edits(tab, model).count, InspectorEdits.count(tab, model), "\(tab)")
        }
    }

    func testFinalScanAndOutputEditsAreGroupedWithExport() {
        let model = EditorModel()
        model.set("io.render_look", .string("hasselblad_hncs"))
        model.set("io.output_cctf_encoding", .bool(true))
        model.set("prep.saturation", .number(18))

        let colorEdits = InspectorEdits.edits(.color, model)
        let exportEdits = InspectorEdits.edits(.output, model)
        XCTAssertTrue(colorEdits.contains { $0.title == "Saturation" })
        XCTAssertFalse(colorEdits.contains { $0.title == "Rendering" })
        XCTAssertFalse(colorEdits.contains { $0.title == "Encode with the colour space’s curve" })
        XCTAssertTrue(exportEdits.contains { $0.title == "Rendering" })
        XCTAssertTrue(exportEdits.contains { $0.title == "Encode with the colour space’s curve" })
        XCTAssertEqual(exportEdits.count, InspectorEdits.count(.output, model))

        model.resetEdits(tab: .output)
        XCTAssertFalse(model.isModified("io.render_look"))
        XCTAssertFalse(model.isModified("io.output_cctf_encoding"))
        XCTAssertTrue(model.isModified("prep.saturation"), "Resetting Export keeps the Color edit")
    }

    func testResettingATabLeavesTheOthers() {
        let model = EditorModel()
        model.set("prep.contrast", .number(12))
        model.set("film_render.halation.strength", .number(2))
        let lab = InspectorEdits.count(.lab, model)
        XCTAssertGreaterThan(InspectorEdits.count(.prep, model), 0)
        model.resetEdits(tab: .prep)
        XCTAssertEqual(InspectorEdits.count(.prep, model), 0)
        XCTAssertEqual(InspectorEdits.count(.lab, model), lab)
    }

    func testOneEditResetsAlone() {
        let model = EditorModel()
        model.set("prep.contrast", .number(12))
        model.set("prep.shadows", .number(-30))
        model.resetEdits([.param("prep.contrast")], action: "Reset Contrast")
        XCTAssertFalse(model.isModified("prep.contrast"))
        XCTAssertTrue(model.isModified("prep.shadows"))
    }
}
