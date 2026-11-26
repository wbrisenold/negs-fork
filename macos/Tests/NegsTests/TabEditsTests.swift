import AppKit
import SwiftUI
import XCTest
@testable import NegsApp

/// The list under a tab's count lists what the count counts, and Reset on the
/// tab clears both in one undo step.
@MainActor final class TabEditsTests: XCTestCase {
    func testTaskTabsHaveStableKeyboardRoutesAndAccessibleNames() {
        XCTAssertEqual(InspectorTab.allCases.map(\.shortcutKey), ["1", "2", "3", "4", "5"])
        XCTAssertTrue(InspectorTab.allCases.allSatisfy { $0.shortcutModifiers == [.command, .option] })
        XCTAssertEqual(InspectorTab.allCases.map(\.accessibilityName), ["Light", "Color", "Film", "Masks", "Export"])
        XCTAssertEqual(InspectorTab.allCases.map(\.accessibilityHint), [
            "Show Light adjustments (Command-Option-1)",
            "Show Color adjustments (Command-Option-2)",
            "Show Film adjustments (Command-Option-3)",
            "Show Masks adjustments (Command-Option-4)",
            "Show Export adjustments (Command-Option-5)"
        ])
        XCTAssertEqual(InspectorTab.exposure.accessibilityLabel(editCount: 0), "Light")
        XCTAssertEqual(InspectorTab.exposure.accessibilityLabel(editCount: 1), "Light, 1 edit")
        XCTAssertEqual(InspectorTab.output.accessibilityLabel(editCount: 3), "Export, 3 edits")
        XCTAssertEqual(InspectorTab.color.accessibilityValue(isSelected: true, editCount: 2), "Selected, 2 edits")
        XCTAssertEqual(InspectorTab.lab.accessibilityValue(isSelected: false, editCount: 0), "Not selected")
    }

    func testTaskTabKeyboardFocusOrderMatchesVisibleTaskOrder() {
        XCTAssertEqual(InspectorTab.focusOrder, InspectorTab.allCases)
        XCTAssertEqual(InspectorTab.focusOrder.map(\.accessibilityName), ["Light", "Color", "Film", "Masks", "Export"])
    }

    func testUnavailableAdjustmentsExplainWorkflowAndRestoreSavedEdits() {
        let redGrain = Adjustment.stockSlider("Red granularity", "film_render.grain.rms_granularity", 0, 0...80, 0.1, bw: "Granularity")
        let greenGrain = Adjustment.stockSlider("Green granularity", "film_render.grain.rms_granularity", 1, 0...80, 0.1, bw: nil)
        let silver = Adjustment.silverRetention

        XCTAssertNil(redGrain.unavailableReason(filmIsBW: true, scanningFilm: false))
        XCTAssertEqual(greenGrain.unavailableReason(filmIsBW: true, scanningFilm: false), "This grain channel is only available with color film.")
        XCTAssertNil(greenGrain.unavailableReason(filmIsBW: false, scanningFilm: false))
        XCTAssertEqual(silver.unavailableReason(filmIsBW: true, scanningFilm: false), "Silver retention is unavailable with black-and-white film.")
        XCTAssertEqual(silver.unavailableReason(filmIsBW: false, scanningFilm: true), "Silver retention applies to a negative, not a scan of film.")
        XCTAssertNil(silver.unavailableReason(filmIsBW: false, scanningFilm: false))

        let model = EditorModel()
        model.set("film_render.grain.rms_granularity", .array([.number(42), .number(17), .number(23)]))
        model.set("film_render.silver_retention", .number(0.35))
        XCTAssertTrue(model.isStockModified("film_render.grain.rms_granularity", 1))
        XCTAssertTrue(model.isModified("film_render.silver_retention"))

        // A workflow switch changes availability only; returning restores the
        // same parameter values and edited indicators.
        model.set("io.scan_film", .bool(true))
        XCTAssertNotNil(silver.unavailableReason(filmIsBW: false, scanningFilm: model.value("io.scan_film").bool))
        model.set("io.scan_film", .bool(false))
        XCTAssertNil(silver.unavailableReason(filmIsBW: false, scanningFilm: model.value("io.scan_film").bool))
        XCTAssertEqual(model.value("film_render.grain.rms_granularity").array[1], .number(17))
        XCTAssertTrue(model.isStockModified("film_render.grain.rms_granularity", 1))
        XCTAssertEqual(model.value("film_render.silver_retention").double, 0.35)
        XCTAssertTrue(model.isModified("film_render.silver_retention"))
    }

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

    func testControlsAcrossTabsChangeTheirBoundValuesAndTabSelectionPreservesPhoto() throws {
        _ = NSApplication.shared
        let model = EditorModel()
        let photo = FileManager.default.temporaryDirectory.appendingPathComponent("inspector-tab-photo.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 6, bitsPerPixel: 24))
        memset(bitmap.bitmapData!, 120, bitmap.bytesPerRow * bitmap.pixelsHigh)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: photo)
        defer { try? FileManager.default.removeItem(at: photo) }
        model.open(photo)

        func changeSlider(_ control: Adjustment, to value: Double, file: StaticString = #filePath, line: UInt = #line) throws {
            let host = NSHostingView(rootView: AdjustmentControl(model: model, adjustment: control))
            _ = host.fittingSize
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let slider = try XCTUnwrap(descendants(host).compactMap { $0 as? InkSliderView }.first, file: file, line: line)
            slider.onChange(value)
        }

        var selected = InspectorTab.exposure
        let tabBinding = Binding(get: { selected }, set: { selected = $0 })
        let tabs = InspectorTabs(model: model, tab: tabBinding)
        _ = NSHostingView(rootView: tabs).fittingSize

        tabBinding.wrappedValue = .exposure
        try changeSlider(.slider("Contrast", "prep.contrast", -100...100, 1), to: 24)
        XCTAssertEqual(model.value("prep.contrast").double, 24)

        tabBinding.wrappedValue = .color
        try changeSlider(.slider("Saturation", "prep.saturation", -100...100, 1), to: 31)
        XCTAssertEqual(model.value("prep.saturation").double, 31)

        tabBinding.wrappedValue = .output
        let outputToggle = TickRow(title: "Encode with the colour space’s curve",
                                   isOn: model.toggle("io.output_cctf_encoding"))
        _ = NSHostingView(rootView: outputToggle).fittingSize
        outputToggle.isOn.wrappedValue = true
        XCTAssertTrue(model.value("io.output_cctf_encoding").bool)

        XCTAssertEqual(model.source, photo)
        XCTAssertEqual(model.value("prep.contrast").double, 24)
        XCTAssertEqual(model.value("prep.saturation").double, 31)
        XCTAssertTrue(model.value("io.output_cctf_encoding").bool)
        XCTAssertGreaterThan(InspectorEdits.count(.exposure, model), 0)
        XCTAssertGreaterThan(InspectorEdits.count(.color, model), 0)
        XCTAssertGreaterThan(InspectorEdits.count(.output, model), 0)
    }
}
