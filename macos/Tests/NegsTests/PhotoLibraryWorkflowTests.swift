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
                              albums: [LibraryAlbum(id: binID, name: "Review", projectID: projectID)],
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

    func testProjectAndGroupNavigationAndMembershipSurviveRelaunchWithoutChangingSource() async throws {
        let fixture = try await fixture()
        defer { fixture.clean() }
        let source = fixture.photos[0].file.url
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let originalBytes = Data("original photograph".utf8)
        try originalBytes.write(to: source)

        fixture.library.selectProject(fixture.projectID)
        fixture.library.selectGroup(fixture.binID)
        XCTAssertEqual(fixture.library.visiblePhotos.count, 2)
        try await fixture.library.flushPersistence()

        let relaunched = PhotoLibrary(storeURL: fixture.root.appendingPathComponent("catalog.json"))
        await relaunched.load()
        XCTAssertEqual(relaunched.selectedProjectID, fixture.projectID)
        XCTAssertEqual(relaunched.selectedAlbumID, fixture.binID)
        XCTAssertEqual(relaunched.visiblePhotos.count, 2)

        relaunched.removeFromBin([fixture.photos[0]], binID: fixture.binID)
        relaunched.addToBin([fixture.photos[0]], binID: fixture.binID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        try await relaunched.flushPersistence()

        let afterAdd = PhotoLibrary(storeURL: fixture.root.appendingPathComponent("catalog.json"))
        await afterAdd.load()
        XCTAssertTrue(try XCTUnwrap(afterAdd.photos.first { $0.file.url == source }).albumIDs.contains(fixture.binID))

        afterAdd.removeFromBin([fixture.photos[0]], binID: fixture.binID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        try await afterAdd.flushPersistence()

        let afterMembershipChange = PhotoLibrary(storeURL: fixture.root.appendingPathComponent("catalog.json"))
        await afterMembershipChange.load()
        XCTAssertFalse(try XCTUnwrap(afterMembershipChange.photos.first { $0.file.url == source }).albumIDs.contains(fixture.binID))
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
    }

    func testReturningFromDevelopKeepsLibraryContextAndSelectionWhenPhotoStillBelongs() async throws {
        let fixture = try await fixture()
        defer { fixture.clean() }
        let library = fixture.library
        let firstURL = fixture.photos[0].file.url
        let secondURL = fixture.photos[1].file.url
        try FileManager.default.createDirectory(at: firstURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("photograph".utf8).write(to: firstURL)
        library.selectProject(fixture.projectID)
        library.selectGroup(fixture.binID)
        library.selectReviewFilter(.picked)
        library.selectGridPhoto(firstURL, in: [firstURL, secondURL])
        library.selectGridPhoto(secondURL, toggling: true, in: [firstURL, secondURL])

        // Develop returns through syncEditedPhoto when Library reappears. A
        // photograph already in the current view must not replace its review
        // scope or selection with the default All Photos view.
        await library.syncEditedPhoto(firstURL)

        XCTAssertEqual(library.selectedProjectID, fixture.projectID)
        XCTAssertEqual(library.selectedAlbumID, fixture.binID)
        XCTAssertEqual(library.filter, .picked)
        XCTAssertEqual(library.searchText, "")
        XCTAssertEqual(library.selectedPhotoURL, firstURL)
        XCTAssertEqual(library.gridSelection.selected, Set([firstURL, secondURL]))
        XCTAssertEqual(library.visiblePhotos.map(\.file.url), [firstURL, secondURL])
        XCTAssertNotEqual(library.selectedPhotoURL, secondURL)
    }

    func testReturningToLibraryExplainsMissingSourceAndKeepsContextUsable() async throws {
        let fixture = try await fixture()
        defer { fixture.clean() }
        let library = fixture.library
        library.selectProject(fixture.projectID)
        library.selectGroup(fixture.binID)
        library.selectReviewFilter(.picked)
        library.searchText = "b.png"

        await library.syncEditedPhoto(fixture.photos[1].file.url)

        XCTAssertEqual(library.selectedProjectID, fixture.projectID)
        XCTAssertEqual(library.selectedAlbumID, fixture.binID)
        XCTAssertEqual(library.filter, .picked)
        XCTAssertEqual(library.searchText, "b.png")
        XCTAssertTrue(try XCTUnwrap(library.photos.first { $0.file.url == fixture.photos[1].file.url }).missing)
        XCTAssertTrue(library.error?.contains("b.png") == true)
        XCTAssertEqual(library.visiblePhotos.map(\.file.url), [fixture.photos[1].file.url])
        XCTAssertEqual(library.count(for: .missing), 1)
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

    func testReviewSelectionTracksTheCurrentSearchAndFilterResults() async throws {
        let fixture = try await fixture()
        defer { fixture.clean() }
        let library = fixture.library
        library.selectProject(fixture.projectID)

        library.selectAllGridPhotos(in: library.filteredPhotos())
        XCTAssertEqual(library.selectedCount(in: library.filteredPhotos()), 2)

        library.searchText = "a.png"
        XCTAssertEqual(library.filteredPhotos().map(\.file.name), ["a.png"])
        XCTAssertEqual(library.selectedCount(in: library.filteredPhotos()), 1)
        library.pruneGridSelection(to: library.filteredPhotos().map(\.file.url))
        XCTAssertEqual(library.gridSelection.selected, [fixture.photos[0].file.url])

        library.searchText = ""
        library.filter = .fiveStar
        XCTAssertEqual(library.filteredPhotos().map(\.file.name), ["b.png"])
        XCTAssertEqual(library.selectedCount(in: library.filteredPhotos()), 0)
        library.selectAllGridPhotos(in: library.filteredPhotos())
        XCTAssertEqual(library.gridSelection.selected, [fixture.photos[1].file.url])
        XCTAssertEqual(library.selectedCount(in: library.filteredPhotos()), 1)
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

    func testReimportingSourceDoesNotDuplicateLibraryEntries() async throws {
        let fixture = try await fixture()
        defer { fixture.clean() }
        let source = fixture.root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("photo".utf8).write(to: source.appendingPathComponent("same.png"))

        await fixture.library.importFolders([source])
        await fixture.library.importFolders([source.standardizedFileURL])

        XCTAssertEqual(fixture.library.photos.filter { $0.file.url.lastPathComponent == "same.png" }.count, 1)
        XCTAssertEqual(fixture.library.refreshProgress, fixture.library.refreshTotal)
    }

    func testPartialFolderFailureKeepsSuccessfulAndCataloguedPhotosAndCanRetry() async throws {
        let fixture = try await fixture()
        defer { fixture.clean() }
        let library = fixture.library
        let goodSource = fixture.root.appendingPathComponent("good")
        try FileManager.default.createDirectory(at: goodSource, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: goodSource.appendingPathComponent("new.png"))
        let badSource = fixture.root.appendingPathComponent("offline")
        let initialCount = library.photos.count

        await library.importFolders([goodSource, badSource])

        XCTAssertEqual(library.photos.count, initialCount + 1)
        XCTAssertTrue(library.photos.contains { $0.file.url.lastPathComponent == "new.png" && !$0.missing })
        XCTAssertTrue(library.photos.contains { $0.file.url.lastPathComponent == "a.png" })
        XCTAssertNotNil(library.error)

        try FileManager.default.createDirectory(at: badSource, withIntermediateDirectories: true)
        try Data("restored".utf8).write(to: badSource.appendingPathComponent("a.png"))
        await library.refresh()

        XCTAssertNil(library.error)
        XCTAssertEqual(library.photos.filter { $0.file.url.lastPathComponent == "a.png" }.count, 1)
        XCTAssertFalse(library.photos.first { $0.file.url.lastPathComponent == "a.png" }?.missing ?? true)
    }

    func testSuccessfulScanMarksPreviouslyCataloguedMissingFile() async throws {
        let fixture = try await fixture()
        defer { fixture.clean() }
        let library = fixture.library
        let source = fixture.root.appendingPathComponent("offline")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("present".utf8).write(to: source.appendingPathComponent("a.png"))
        await library.refresh()

        XCTAssertTrue(library.photos.contains { $0.file.url.lastPathComponent == "b.png" && $0.missing })
        XCTAssertEqual(library.refreshProgress, library.refreshTotal)
        XCTAssertNil(library.error)
    }
}
