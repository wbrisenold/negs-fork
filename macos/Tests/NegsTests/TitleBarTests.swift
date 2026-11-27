import AppKit
import XCTest
@testable import NegsApp

/// No toolbar (§6.7): the title bar holds only the traffic lights and the
/// file name, "Negs" with no photograph, and the columns start under it.
@MainActor final class TitleBarTests: XCTestCase {
    private let frameKey = "NSWindow Frame editor"

    private func window(_ model: EditorModel) throws -> (EditorWindowController, NSWindow) {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: frameKey)
        addTeardownBlock { defaults.set(saved, forKey: self.frameKey) }
        let controller = EditorWindowController(model: model)
        let window = try XCTUnwrap(controller.window)
        controller.editorFrame.split.splitView.autosaveName = nil
        window.setFrameAutosaveName("")
        controller.refresh()
        return (controller, window)
    }

    private func workspaceSwitcher(in view: NSView) -> NSSegmentedControl? {
        if let switcher = view as? NSSegmentedControl { return switcher }
        for child in view.subviews {
            if let switcher = workspaceSwitcher(in: child) { return switcher }
        }
        return nil
    }

    private func view(identifier: NSUserInterfaceItemIdentifier, in view: NSView) -> NSView? {
        if view.identifier == identifier { return view }
        for child in view.subviews {
            if let match = self.view(identifier: identifier, in: child) { return match }
        }
        return nil
    }

    private func click(segment: Int, in control: NSSegmentedControl, window: NSWindow) throws {
        // AppKit does not expose a segment frame. Use the widths reported by
        // NSSegmentedControl, falling back to equal segments when they are
        // content-sized by the system.
        let widths = (0..<control.segmentCount).map { control.width(forSegment: $0) }
        let totalWidth = widths.reduce(0, +)
        let segmentWidth = widths[segment] > 0 ? widths[segment] : control.bounds.width / CGFloat(control.segmentCount)
        let leadingWidth = totalWidth > 0
            ? widths.prefix(segment).reduce(0, +)
            : CGFloat(segment) * segmentWidth
        let point = control.convert(NSPoint(x: control.bounds.minX + leadingWidth + segmentWidth / 2,
                                            y: control.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            NSApp.sendEvent(event)
        }
    }

    func testTitleBarWorkspaceSwitcherChangesTheVisibleWorkspace() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("negs-workspace-switcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let photo = directory.appendingPathComponent("photo.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 6, bitsPerPixel: 24))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: photo)

        let model = EditorModel(sidecars: SidecarStore())
        defer { model.shutdown() }
        model.open(photo)
        XCTAssertNotNil(model.source)
        let (controller, window) = try window(model)
        window.setContentSize(NSSize(width: 1200, height: 800))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        let switcher = try XCTUnwrap(workspaceSwitcher(in: controller.editorFrame.band),
                                    "the title bar exposes one native workspace switcher")
        XCTAssertEqual(switcher.segmentCount, 2)
        XCTAssertEqual(switcher.label(forSegment: 0), "Library")
        XCTAssertEqual(switcher.label(forSegment: 1), "Develop")
        XCTAssertEqual(switcher.selectedSegment, 1)

        try click(segment: 0, in: switcher, window: window)
        XCTAssertEqual(model.workspace, .library)
        await Task.yield()
        XCTAssertEqual(switcher.selectedSegment, 0)
        let libraryHost = view(identifier: NSUserInterfaceItemIdentifier("library-workspace"), in: controller.editorFrame.view)
        XCTAssertNotNil(libraryHost)
        XCTAssertFalse(libraryHost?.isHidden ?? true)

        try click(segment: 1, in: switcher, window: window)
        XCTAssertEqual(model.workspace, .editor)
        await Task.yield()
        XCTAssertEqual(switcher.selectedSegment, 1)
        XCTAssertTrue(libraryHost?.isHidden ?? false)
    }

    func testDevelopDoesNotSelectWhenNoPhotoOrEditCanBeOpened() throws {
        let model = EditorModel(sidecars: SidecarStore())
        defer { model.shutdown() }
        model.workspace = .library
        let (controller, window) = try window(model)
        window.setContentSize(NSSize(width: 1200, height: 800))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        let switcher = try XCTUnwrap(workspaceSwitcher(in: controller.editorFrame.band))
        let libraryHost = view(identifier: NSUserInterfaceItemIdentifier("library-workspace"), in: controller.editorFrame.view)
        XCTAssertTrue(libraryHost?.isHidden == false)

        try click(segment: 1, in: switcher, window: window)

        XCTAssertEqual(model.workspace, .library)
        XCTAssertEqual(switcher.selectedSegment, 0, "the active segment reflects the workspace that actually opened")
        XCTAssertFalse(libraryHost?.isHidden ?? true)
    }

    func testNoToolbarAndTheNameBesideTheTrafficLights() throws {
        let model = EditorModel(sidecars: SidecarStore())
        defer { model.shutdown() }
        let (controller, window) = try window(model)
        window.setContentSize(NSSize(width: 1200, height: 800))
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        XCTAssertTrue(window.toolbar?.items.isEmpty ?? true, "no toolbar items")
        XCTAssertFalse(window.toolbar?.allowsUserCustomization ?? false)
        XCTAssertEqual(window.titleVisibility, .hidden, "the band shows the name, not AppKit's title")
        XCTAssertEqual(window.title, "Negs")
        let band = controller.editorFrame.band
        XCTAssertEqual(band.title, "Negs")
        XCTAssertEqual(band.name.font?.pointSize, 15)
        let frame = controller.editorFrame.view
        // Clicks on the band reach the title bar under it, which drags and zooms.
        XCTAssertNil(frame.hitTest(NSPoint(x: 400, y: frame.bounds.height - 19)), "the window drags from the band")
        XCTAssertNotNil(frame.hitTest(NSPoint(x: 400, y: frame.bounds.height - 100)), "the columns take their clicks")
        XCTAssertEqual(band.frame, NSRect(x: 0, y: frame.bounds.height - 38, width: frame.bounds.width, height: 38))
        XCTAssertEqual(controller.editorFrame.split.view.frame,
                       NSRect(x: 0, y: 0, width: frame.bounds.width, height: frame.bounds.height - 38), "the columns start under it")

        // AppKit's title bar, which holds the traffic lights, is about the band's height.
        XCTAssertEqual(window.frame.height - window.contentLayoutRect.height, Theme.Size.titleBar, accuracy: 3)
        band.layoutSubtreeIfNeeded()
        let zoom = try XCTUnwrap(window.standardWindowButton(.zoomButton))
        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        XCTAssertEqual(band.name.frame.minX, band.convert(zoom.bounds, from: zoom).maxX + TitleBand.gap, accuracy: 1, "after the traffic lights")
        XCTAssertEqual(band.name.frame.midY, band.convert(close.bounds, from: close).midY, accuracy: 1, "level with them")

        // Resizing keeps the band on top and the columns under it.
        window.setContentSize(NSSize(width: 1000, height: 600))
        XCTAssertEqual(band.frame.minY, frame.bounds.height - 38)
        XCTAssertEqual(controller.editorFrame.split.view.frame.height, frame.bounds.height - 38)
    }

    func testTheTitleIsTheFileNameInTheGridToo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("negs-title-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let photo = directory.appendingPathComponent("DSC_2650.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 3,
                                                    hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 48 * 3, bitsPerPixel: 24))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: photo)

        let model = EditorModel(sidecars: SidecarStore())
        defer { model.shutdown() }
        let (controller, window) = try window(model)
        model.open(photo)
        controller.refresh()
        XCTAssertEqual(window.title, "DSC_2650.png")
        XCTAssertEqual(controller.editorFrame.band.title, "DSC_2650.png")

        model.showGrid()
        controller.refresh()
        XCTAssertEqual(controller.editorFrame.band.title, "DSC_2650.png", "the grid keeps the file name")
        XCTAssertEqual(window.subtitle, "")
    }

    /// The smallest window: a 640 pt canvas beside the inspector at 340 (§7).
    func testTheSmallestWindow() throws {
        let model = EditorModel(sidecars: SidecarStore())
        defer { model.shutdown() }
        let (controller, window) = try window(model)
        let split = controller.editorFrame.split
        XCTAssertEqual(split.splitViewItems[0].minimumThickness, 640)
        XCTAssertEqual(split.splitViewItems[1].minimumThickness, 340)
        XCTAssertEqual(window.contentMinSize.height, 560)
    }
}
