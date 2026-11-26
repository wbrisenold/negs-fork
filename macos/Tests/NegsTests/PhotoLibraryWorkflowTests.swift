import Foundation
import Observation
import XCTest
@testable import NegsApp

/// Persistent Media Pool behavior, isolated from the user's catalog.
@MainActor final class PhotoLibraryWorkflowTests: XCTestCase {
    private struct Catalog: Encodable {
        var schema = 1
        var folders: [LibraryFolder]
        var photos: [LibraryPhoto]
        var albums: [LibraryAlbum]
        var smartCollections: [SmartLibraryCollection]
        var projects: [LibraryProject]
    }

    @MainActor private struct Fixture {
        var library: PhotoLibrary
        var root: URL
        var photos: [LibraryPhoto]
        var folderID: UUID
        var binID: UUID
        var projectID: UUID

        func clean() {
            library.flushPersistence()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("negs-media-pool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // The source stays offline so loading exercises catalog preservation.
        let source = root.appendingPathComponent("offline")
        let folderID = UUID(), binID = UUID(), projectID = UUID()
        var first = LibraryPhoto(file: PhotoFile(url: source.appendingPathComponent("a.png")), folderID: folderID)
        first.flag = .picked
        first.albumIDs = [binID]
        var second = LibraryPhoto(file: PhotoFile(url: source.appendingPathComponent("b.png")), folderID: folderID)
        second.flag = .picked
        second.rating = 5
        second.missing = true
        second.albumIDs = [binID]
        let records = [first, second]
        let catalog = Catalog(folders: [LibraryFolder(id: folderID, path: source.path)], photos: records,
                              albums: [LibraryAlbum(id: binID, name: "Review")],
                              smartCollections: [SmartLibraryCollection(id: UUID(), name: "Picked", filter: .picked)],
                              projects: [LibraryProject(id: projectID, name: "Client", photoPaths: Set(records.map { $0.file.url.path }))])
        let store = root.appendingPathComponent("catalog.json")
        try JSONEncoder().encode(catalog).write(to: store)
        let library = PhotoLibrary(storeURL: store)
        await library.load()
        return Fixture(library: library, root: root, photos: records, folderID: folderID, binID: binID, projectID: projectID)
    }

    func testCacheHitsRetainObservationDependencies() async throws {
        let fixture = try await fixture()
        defer { fixture.clean() }
        let library = fixture.library
        library.selectedFolderID = fixture.folderID
        library.selectedPhotoURL = fixture.photos[0].file.url
        // Warm every cache, then register a fresh view read on the hit path.
        _ = library.scopePhotos; _ = library.sidebarCounts
        _ = library.selectedPhoto; _ = library.count(for: .fiveStar)
        let scope = expectation(description: "cached scope observes changes")
        let counts = expectation(description: "cached counts observe changes")
        let selected = expectation(description: "cached inspector observes changes")
        let filters = expectation(description: "cached filters observe changes")
        withObservationTracking { _ = library.scopePhotos } onChange: { scope.fulfill() }
        withObservationTracking { _ = library.sidebarCounts } onChange: { counts.fulfill() }
        withObservationTracking { _ = library.selectedPhoto } onChange: { selected.fulfill() }
        withObservationTracking { _ = library.count(for: .fiveStar) } onChange: { filters.fulfill() }
        library.setRating(5, for: fixture.photos[0].file.url)
        await fulfillment(of: [scope, counts, selected, filters], timeout: 1)
        XCTAssertEqual(library.selectedPhoto?.rating, 5)
    }

    func testScopedFilterCountsMatchOfflinePhotoVisibility() async throws {
        let fixture = try await fixture()
        defer { fixture.clean() }
        let library = fixture.library
        library.selectedProjectID = fixture.projectID
        for filter in LibraryFilter.allCases {
            library.filter = filter
            XCTAssertEqual(library.count(for: filter), library.visiblePhotos.count, "\(filter)")
        }
        library.selectedProjectID = nil
        library.filter = .all
        XCTAssertEqual(library.count(for: .all), 1)
        XCTAssertEqual(library.sidebarCounts.smartCollections[LibraryFilter.picked.rawValue], 1)
    }

    func testCommandSelectionAndBinRemovalLeaveOriginalReferences() async throws {
        let fixture = try await fixture()
        defer { fixture.clean() }
        let library = fixture.library
        let order = fixture.photos.map(\.file.url)
        library.selectGridPhoto(order[0], in: order)
        library.selectGridPhoto(order[1], toggling: true, in: order)
        XCTAssertEqual(library.gridSelection.selected, Set(order))
        library.selectGridPhoto(order[0], toggling: true, in: order)
        XCTAssertEqual(library.gridSelection.selected, [order[1]])
        XCTAssertEqual(library.selectedPhotoURL, order[1])
        library.removeFromBin([fixture.photos[1]], binID: fixture.binID)
        XCTAssertEqual(library.photos.count, 2)
        XCTAssertFalse(library.photos[1].albumIDs.contains(fixture.binID))
        XCTAssertEqual(library.projects.first?.photoPaths.count, 2)
        XCTAssertEqual(library.folders.count, 1)
    }

    func testAnEmptyScopeClearsInspectorAndSelection() async throws {
        let fixture = try await fixture()
        defer { fixture.clean() }
        let library = fixture.library
        let order = fixture.photos.map(\.file.url)
        library.selectGridPhoto(order[0], in: order)
        library.pruneGridSelection(to: [])
        XCTAssertTrue(library.gridSelection.selected.isEmpty)
        XCTAssertNil(library.selectedPhotoURL)
    }

    func testWorkflowScopeActionUpdatesVisibleGroupAndClearsStalePhotoFocus() async throws {
        let fixture = try await fixture()
        defer { fixture.clean() }
        let library = fixture.library
        let focusedPhoto = fixture.photos[0].file.url
        library.selectedPhotoURL = focusedPhoto
        library.gridSelection.select(focusedPhoto)

        let visible = LibraryWorkflow.perform(.openGroup(fixture.binID), in: library)

        XCTAssertEqual(visible.title, "Review")
        XCTAssertEqual(visible.projectTitle, "Client")
        XCTAssertEqual(visible.photoCount, 2)
        XCTAssertNil(visible.emptyState)
        XCTAssertNil(library.selectedPhotoURL)
        XCTAssertTrue(library.gridSelection.selected.isEmpty)

        library.createProject(named: "New Job")
        let emptyProjectID = try XCTUnwrap(library.projects.first { $0.name == "New Job" }?.id)
        _ = LibraryWorkflow.perform(.openProject(fixture.projectID), in: library)
        library.selectedPhotoURL = focusedPhoto
        library.gridSelection.select(focusedPhoto)
        let emptyProject = LibraryWorkflow.perform(.openProject(emptyProjectID), in: library)
        XCTAssertEqual(emptyProject.scopeLabel, "PROJECT · NEW JOB · ALL PHOTOS")
        XCTAssertEqual(emptyProject.photoCount, 0)
        XCTAssertEqual(emptyProject.emptyState?.nextStep, .addPhotos)
        XCTAssertNil(library.selectedPhotoURL)
        XCTAssertTrue(library.gridSelection.selected.isEmpty)
    }

    func testFailedFolderImportStillPersistsItsReference() async throws {
        let fixture = try await fixture()
        defer { fixture.clean() }
        let library = fixture.library
        await library.importFolders([fixture.root.appendingPathComponent("another-offline-folder")])
        library.flushPersistence()
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.root.appendingPathComponent("catalog.json"))) as? [String: Any]
        XCTAssertEqual((object?["folders"] as? [[String: Any]])?.count, 2)
        XCTAssertNotNil(library.error)
    }

    func testImportActionAddsPhotosToNamedProjectAndKeepsVisibleScope() async throws {
        let fixture = try await fixture()
        defer { fixture.clean() }
        let library = fixture.library
        let sourceFolder = fixture.root.appendingPathComponent("selected-source")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        let sourceURL = sourceFolder.appendingPathComponent("selected.jpg")
        let originalBytes = Data("original image bytes".utf8)
        try originalBytes.write(to: sourceURL)

        let priorVisibleCount = LibraryWorkflow.visibleState(in: library).photoCount
        let folderOutcome = await LibraryWorkflow.perform(.importFolders([sourceFolder], to: fixture.projectID), in: library)
        XCTAssertEqual(folderOutcome.importStatus?.phase, .completed)
        XCTAssertEqual(folderOutcome.importStatus?.importedCount, 1)
        XCTAssertEqual(folderOutcome.photoCount, priorVisibleCount + 1)
        XCTAssertEqual(library.selectedProjectID, fixture.projectID)

        library.createProject(named: "Alternate Job")
        let alternateID = try XCTUnwrap(library.projects.first { $0.name == "Alternate Job" }?.id)
        _ = LibraryWorkflow.perform(.openProject(fixture.projectID), in: library)
        let photo = try XCTUnwrap(library.photos.first { $0.file.url.standardizedFileURL == sourceURL.standardizedFileURL })

        let outcome = await LibraryWorkflow.perform(.addSelectedPhotos([photo], to: alternateID), in: library)

        XCTAssertEqual(outcome.importStatus?.destinationName, "Alternate Job")
        XCTAssertEqual(outcome.importStatus?.phase, .completed)
        XCTAssertEqual(library.selectedProjectID, fixture.projectID)
        XCTAssertEqual(library.projects.first { $0.id == alternateID }?.photoPaths, [sourceURL.path])
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalBytes)
        XCTAssertEqual(library.selectedProjectID, fixture.projectID)
    }

    func testFailedFolderImportCanRetryIntoOriginalDestination() async throws {
        let fixture = try await fixture()
        defer { fixture.clean() }
        let library = fixture.library
        let destinationID = try XCTUnwrap(library.projects.first?.id)
        let missingFolder = fixture.root.appendingPathComponent("camera-card")

        let failed = await LibraryWorkflow.perform(.importFolders([missingFolder], to: destinationID), in: library)

        XCTAssertEqual(failed.importStatus?.phase, .failed)
        XCTAssertTrue(failed.importStatus?.canRetry == true)
        XCTAssertEqual(library.selectedProjectID, destinationID)
        try FileManager.default.createDirectory(at: missingFolder, withIntermediateDirectories: true)
        try Data("untouched original".utf8).write(to: missingFolder.appendingPathComponent("frame.jpg"))
        library.createProject(named: "Other Project")
        XCTAssertNotEqual(library.selectedProjectID, destinationID)

        let completed = await LibraryWorkflow.retryImport(in: library)

        XCTAssertEqual(completed.importStatus?.phase, .completed)
        XCTAssertEqual(completed.importStatus?.destinationName, "Client")
        XCTAssertEqual(library.projects.first { $0.id == library.selectedProjectID }?.name, "Other Project")
        XCTAssertEqual(library.projects.first { $0.id == destinationID }?.folderIDs.count, 1)
        XCTAssertEqual(try Data(contentsOf: missingFolder.appendingPathComponent("frame.jpg")), Data("untouched original".utf8))
    }
}
