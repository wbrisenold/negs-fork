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

    private func fixture() async throws -> (EditorModel, URL, URL) {
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
        let model = EditorModel(sidecars: SidecarStore(writes: false))
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
