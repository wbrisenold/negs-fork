import CoreGraphics
import Foundation
import IOSurface
import XCTest
@testable import NegsApp

final class EngineScopeRegressionTests: XCTestCase {
    func testDenseNeutralVectorscopeBinSaturatesInsteadOfDisappearing() throws {
        // Exactly two UInt16 ranges used to wrap the only occupied bin to 0.
        let data = Data(repeating: 128, count: 512 * 256 * 4)
        let surface = try EditorModel.previewSurface(data, width: 512, height: 256, bgra: true)
        let scope = ImageScopes.of(surface, crop: CropSettings(), mode: .vectorscope)
        XCTAssertEqual(scope.vectorscope.bins.max(), UInt32.max as UInt32?)
        XCTAssertGreaterThan(scope.vectorscope.sampleCount, 0)
    }

    func testCancelledDiagnosticWorkReturnsWithoutCreatingImages() async throws {
        let surface = try EditorModel.previewSurface(Data(repeating: 128, count: 16 * 16 * 4), width: 16, height: 16)
        let result = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return ImageScopes.clippingOverlay(surface, low: 0.02, high: 0.98) == nil
                && ImageScopes.falseColorOverlay(surface) == nil
        }.value
        XCTAssertTrue(result)
    }

    func testUnsupportedSurfaceIsNotReadAsBGRA() throws {
        let surface = try XCTUnwrap(IOSurface(properties: [
            .width: 32, .height: 32, .bytesPerElement: 1, .bytesPerRow: 32
        ]))
        XCTAssertNil(ImageScopes.clippingOverlay(surface, low: 0.02, high: 0.98))
        XCTAssertNil(ImageScopes.falseColorOverlay(surface))
        XCTAssertEqual(ImageScopes.of(surface, crop: CropSettings()).histogram.red.reduce(0, +), 0)
    }

    func testFitSizeRejectsNonfiniteAndUnrepresentableGeometry() {
        XCTAssertNil(FitDownscale.targetSize(photo: CGSize(width: CGFloat.infinity, height: 200), scale: 0.5))
        XCTAssertNil(FitDownscale.targetSize(photo: CGSize(width: CGFloat.greatestFiniteMagnitude, height: 200), scale: 0.5))
        XCTAssertNil(FitDownscale.targetSize(photo: CGSize(width: 200, height: CGFloat.nan), scale: 0.5))
        XCTAssertEqual(FitDownscale.targetSize(photo: CGSize(width: 400, height: 300), scale: 0.5)?.width, 200)
    }

    func testReplacingCustomLUTInvalidatesTheSavedFrameKey() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let photo = directory.appendingPathComponent("photo"), helper = directory.appendingPathComponent("helper")
        let data = directory.appendingPathComponent("data"), lut = directory.appendingPathComponent("look.cube")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        for file in [photo, helper, lut] { try Data([1]).write(to: file) }
        var state = EditState()
        state.params["io.referent_logc3_path"] = .string(lut.path)
        let paths = EnginePaths(helper: helper, exporter: helper, data: data)
        let before = try XCTUnwrap(RenderedPreviewCache.key(source: photo, state: state, paths: paths))
        try Data([2, 3]).write(to: lut)
        XCTAssertNotEqual(RenderedPreviewCache.key(source: photo, state: state, paths: paths), before)
    }

    func testCancelledRequestDoesNotLaunchTheHelper() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let engine = try EngineClient(paths: EnginePaths(helper: missing, exporter: missing, data: missing))
        defer { engine.stop() }
        let wasCancelled = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await engine.request(["command": .string("catalog")])
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }.value
        XCTAssertTrue(wasCancelled)
        XCTAssertNil(engine.runningLaunch)
    }
}
