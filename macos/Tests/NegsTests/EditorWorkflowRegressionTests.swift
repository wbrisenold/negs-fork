import AppKit
import XCTest
@testable import NegsApp

@MainActor final class EditorWorkflowRegressionTests: XCTestCase {
    func testRawScaleRejectsInvalidGeometryAndRequests() {
        for request in [CGFloat.nan, .infinity, 0, -0.2] {
            let scale = EditorModel.rawPreviewScale(requested: request)
            XCTAssertTrue(scale.isFinite && scale > 0 && scale <= 0.38)
        }
        for size in [CGSize(width: .infinity, height: 200), CGSize(width: 200, height: .nan), .zero] {
            XCTAssertEqual(EditorModel.rawPreviewScale(requested: nil, photoSize: size), 0.27)
        }
        XCTAssertEqual(EditorModel.rawPreviewScale(requested: 0.1, photoSize: CGSize(width: 6000, height: 4000)), 0.1)
    }

    func testComparisonReloadsAfterSlotReplacementAndClearsWhenPhotoChanges() async throws {
        let (model, root, photo) = try await fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.saveVersion(1); model.saveVersion(2)
        model.comparisonMode = .threeUp
        // Replace the same slot while its first request can still be queued.
        model.saveVersion(1)
        try await waitUntil { model.versionImages.count == 2 && model.comparisonOriginal != nil }
        XCTAssertTrue(model.versionImages.values.allSatisfy { max($0.width, $0.height) <= 1600 })
        let second = root.appendingPathComponent("second.png")
        try FileManager.default.copyItem(at: photo, to: second)
        model.open(second)
        XCTAssertNil(model.comparisonOriginal)
        XCTAssertTrue(model.versionImages.isEmpty)
        XCTAssertTrue(model.savedVersions.isEmpty)
    }

    func testUndoAndRedoShowTheSelectedSettledEdit() async throws {
        let (model, root, _) = try await fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        let path = "prep.contrast"
        let initial = model.value(path)

        undo.beginUndoGrouping()
        model.set(path, .number(18))
        undo.endUndoGrouping()
        try await waitUntil { model.frameStatus == .current(model.currentFrame) }
        XCTAssertEqual(model.shownFrame?.frame, model.currentFrame)
        XCTAssertEqual(model.value(path), .number(18))

        undo.undo()
        XCTAssertEqual(model.frameStatus, .pending(model.currentFrame))
        try await waitUntil { model.frameStatus == .current(model.currentFrame) && model.value(path) == initial }
        XCTAssertEqual(model.shownFrame?.frame, model.currentFrame, "Undo must show the frame for its selected history state")

        undo.redo()
        XCTAssertEqual(model.frameStatus, .pending(model.currentFrame))
        try await waitUntil { model.frameStatus == .current(model.currentFrame) && model.value(path) == .number(18) }
        XCTAssertEqual(model.shownFrame?.frame, model.currentFrame, "Redo must show the frame for its selected history state")
    }

    func testCropAndMaskEditsStayWithTheVisibleHistoryAndSavedPhoto() async throws {
        let previousSidecarsPreference = UserDefaults.standard.object(forKey: "sidecars")
        let sidecars = SidecarStore()
        let (model, root, photo) = try await fixture(sidecars: sidecars)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        defer {
            model.sidecarsEnabled = previousSidecarsPreference as? Bool ?? true
            if let previousSidecarsPreference { UserDefaults.standard.set(previousSidecarsPreference, forKey: "sidecars") }
            else { UserDefaults.standard.removeObject(forKey: "sidecars") }
        }
        let originalContrast = model.value("prep.contrast")
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo

        // A crop changes the canvas frame immediately without requiring a
        // redundant develop; its history state and sidecar remain selectable.
        model.beginCrop()
        try XCTUnwrap(model.cropSession).choose(.square)
        undo.beginUndoGrouping(); model.endCrop(apply: true); undo.endUndoGrouping()
        XCTAssertEqual(model.photoSize, CGSize(width: 64, height: 64))
        XCTAssertTrue(model.previewCurrent)
        XCTAssertEqual(model.shownFrame?.frame, model.currentFrame)
        undo.undo()
        XCTAssertFalse(model.state.crop.cropped)
        XCTAssertEqual(model.photoSize, CGSize(width: 96, height: 64))
        undo.redo()
        XCTAssertEqual(model.photoSize, CGSize(width: 64, height: 64))

        // A painted mask is a rendered edit and must refresh the settled frame
        // while retaining unrelated adjustments.
        undo.beginUndoGrouping(); model.set("prep.contrast", .number(23)); undo.endUndoGrouping()
        try await waitUntil { model.frameStatus == .current(model.currentFrame) }
        undo.beginUndoGrouping()
        model.createBrushBackgroundMask()
        undo.endUndoGrouping()
        model.backgroundMaskBrushSize = 12
        undo.beginUndoGrouping()
        model.beginBackgroundMaskStroke(at: CGPoint(x: 0.5, y: 0.5))
        model.endBackgroundMaskStroke()
        undo.endUndoGrouping()
        try await waitUntil { model.frameStatus == .current(model.currentFrame) }
        XCTAssertEqual(model.shownFrame?.frame, model.currentFrame)
        XCTAssertEqual(model.value("prep.contrast"), .number(23))
        XCTAssertFalse(model.state.params["post.background_masks"].array.isEmpty)

        undo.undo()
        try await waitUntil { model.frameStatus == .current(model.currentFrame) }
        XCTAssertEqual(model.value("prep.contrast"), .number(23))
        XCTAssertFalse(model.state.params["post.background_masks"].array.isEmpty)
        undo.undo()
        try await waitUntil { model.frameStatus == .current(model.currentFrame) }
        XCTAssertTrue(model.state.params["post.background_masks"].array.isEmpty)
        XCTAssertNil(model.backgroundMaskOverlay, "Undoing the last mask must remove its overlay from the current frame")
        undo.redo()
        undo.redo()
        try await waitUntil { model.frameStatus == .current(model.currentFrame) }
        XCTAssertFalse(model.state.params["post.background_masks"].array.isEmpty)
        XCTAssertNotNil(model.backgroundMaskOverlay)

        await model.flushSidecars()
        let saved = try XCTUnwrap(sidecars.read(photo: photo)?.variants.first?.edits)
        XCTAssertEqual(saved["crop"]["rect"].array.count, 2)
        XCTAssertEqual(saved["params"]["prep"]["contrast"].double, 23, accuracy: 1e-9)

        // Reopening through the editor restores the selected crop and mask
        // together with the independent adjustment.
        model.open(photo)
        try await waitUntil { model.previewCurrent || model.error != nil }
        XCTAssertNil(model.error)
        XCTAssertTrue(model.state.crop.cropped)
        XCTAssertEqual(model.value("prep.contrast"), .number(23))
        XCTAssertFalse(model.state.params["post.background_masks"].array.isEmpty)
        XCTAssertEqual(model.photoSize, CGSize(width: 64, height: 64))
        XCTAssertNotEqual(originalContrast, model.value("prep.contrast"))
    }

    func testExportRefusesOriginalAndEmptyBatchCreatesNoRun() async throws {
        let (model, root, photo) = try await fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let before = try Data(contentsOf: photo)
        await model.export(to: photo, engine: .fast)
        XCTAssertEqual(try Data(contentsOf: photo), before)
        XCTAssertTrue(model.error?.contains("preserve the original") == true)
        let run = await model.exportBatch([], to: root, options: BatchOptions())
        XCTAssertNil(run)
        XCTAssertFalse(model.batchRunning)
    }

    private func fixture(sidecars: SidecarStore? = nil) async throws -> (EditorModel, URL, URL) {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let binaries = repo.appendingPathComponent("target/macos-app/x86_64-apple-darwin/release")
        let helper = binaries.appendingPathComponent("spektrafilm-native")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw XCTSkip("Build the Intel helper first") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("negs-editor-regression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let photo = root.appendingPathComponent("first.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 96, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 96 * 3, bitsPerPixel: 24))
        for y in 0..<64 {
            for x in 0..<96 {
                let offset = y * bitmap.bytesPerRow + x * 3
                bitmap.bitmapData![offset] = UInt8(x * 255 / 96)
                bitmap.bitmapData![offset + 1] = UInt8(y * 255 / 64)
                bitmap.bitmapData![offset + 2] = 100
            }
        }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: photo)
        let model = EditorModel(sidecars: sidecars ?? SidecarStore(writes: false))
        if sidecars != nil { model.sidecarsEnabled = true }
        await model.start(paths: EnginePaths(helper: helper, exporter: binaries.appendingPathComponent("spektrafilm-f64"),
                                          data: repo.appendingPathComponent("data")), restoration: Task { nil })
        model.open(photo)
        do { try await waitUntil { model.previewCurrent || model.error != nil } }
        catch { model.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
        XCTAssertTrue(model.previewCurrent, model.error ?? model.status)
        return (model, root, photo)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate(), "Timed out waiting for the preview")
    }
}
