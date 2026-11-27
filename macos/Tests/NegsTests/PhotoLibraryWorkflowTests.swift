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
        let scopedBinID = library.albums.first { $0.name == "Review" }?.id ?? binID
        let fixture = Fixture(library: library, root: root, photos: records, folderID: folderID,
                              binID: scopedBinID, projectID: projectID)
        addTeardownBlock {
            try? await library.flushPersistence()
            try? FileManager.default.removeItem(at: root)
        }
        return fixture
    }

    func testCacheHitsRetainObservationDependencies() async throws {
        let fixture = try await fixture()
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
        let library = fixture.library
        let order = fixture.photos.map(\.file.url)
        library.selectGridPhoto(order[0], in: order)
        library.pruneGridSelection(to: [])
        XCTAssertTrue(library.gridSelection.selected.isEmpty)
        XCTAssertNil(library.selectedPhotoURL)
    }

    func testWorkflowScopeActionUpdatesVisibleGroupAndClearsStalePhotoFocus() async throws {
        let fixture = try await fixture()
        let library = fixture.library
        let focusedPhoto = fixture.photos[0].file.url
        library.selectedPhotoURL = focusedPhoto
        library.gridSelection.select(focusedPhoto)

        let visible = await LibraryWorkflow.perform(.openGroup(fixture.binID), in: library)

        XCTAssertEqual(visible.title, "Review")
        XCTAssertEqual(visible.scopeLabel, "PROJECT · CLIENT · GROUP")
        XCTAssertEqual(visible.projectTitle, "Client")
        XCTAssertEqual(visible.photoCount, 2)
        XCTAssertEqual(visible.selectedCount, 0)
        XCTAssertNil(visible.emptyState)
        XCTAssertNil(library.selectedPhotoURL)
        XCTAssertTrue(library.gridSelection.selected.isEmpty)

        library.removeFromBin(fixture.photos, binID: fixture.binID)
        let emptyGroup = LibraryWorkflow.visibleState(in: library)
        XCTAssertEqual(emptyGroup.photoCount, 0)
        XCTAssertEqual(emptyGroup.emptyState?.nextStep, .browseProjectPhotos)

        library.createProject(named: "New Job")
        let emptyProjectID = try XCTUnwrap(library.projects.first { $0.name == "New Job" }?.id)
        _ = await LibraryWorkflow.perform(.openProject(fixture.projectID), in: library)
        library.selectedPhotoURL = focusedPhoto
        library.gridSelection.select(focusedPhoto)
        let emptyProject = await LibraryWorkflow.perform(.openProject(emptyProjectID), in: library)
        XCTAssertEqual(emptyProject.scopeLabel, "PROJECT · NEW JOB · ALL PHOTOS")
        XCTAssertEqual(emptyProject.photoCount, 0)
        XCTAssertEqual(emptyProject.emptyState?.nextStep, .addPhotos)
        XCTAssertNil(library.selectedPhotoURL)
        XCTAssertTrue(library.gridSelection.selected.isEmpty)
    }

    func testBrowseActionsStayInScopeAndExposeRemovableFiltersAndFocusedSelection() async throws {
        let fixture = try await fixture()
        let library = fixture.library
        library.removeFromBin([fixture.photos[0]], binID: fixture.binID)
        _ = await LibraryWorkflow.perform(.openGroup(fixture.binID), in: library)

        let searched = await LibraryWorkflow.perform(.search("png"), in: library)

        XCTAssertEqual(searched.visiblePhotoURLs, [fixture.photos[1].file.url])
        XCTAssertEqual(searched.searchText, "png")
        XCTAssertEqual(searched.photoCount, 1)

        let clearedSearch = await LibraryWorkflow.perform(.clearSearch, in: library)
        XCTAssertEqual(clearedSearch.photoCount, 1)
        _ = await LibraryWorkflow.perform(.openProject(fixture.projectID), in: library)
        let filtered = await LibraryWorkflow.perform(.setFilter(.fiveStar), in: library)
        XCTAssertEqual(filtered.visiblePhotoURLs, [fixture.photos[1].file.url])
        XCTAssertEqual(filtered.activeFilters, [.category(.fiveStar)])
        _ = await LibraryWorkflow.perform(.toggleCullFilter(.rejects), in: library)
        let filterRemoved = await LibraryWorkflow.perform(.removeFilter(.category(.fiveStar)), in: library)
        XCTAssertEqual(filterRemoved.photoCount, 0)
        XCTAssertEqual(filterRemoved.activeFilters, [.cull(.rejects)])
        let allFiltersRemoved = await LibraryWorkflow.perform(.removeFilter(.cull(.rejects)), in: library)
        XCTAssertEqual(allFiltersRemoved.photoCount, 2)
        XCTAssertTrue(allFiltersRemoved.activeFilters.isEmpty)

        let single = await LibraryWorkflow.perform(.select(fixture.photos[0].file.url, .single), in: library)
        XCTAssertEqual(single.selectedPhotoURLs, [fixture.photos[0].file.url])
        let additive = await LibraryWorkflow.perform(.select(fixture.photos[1].file.url, .additive), in: library)
        XCTAssertEqual(additive.selectedCount, 2)
        XCTAssertEqual(Set(additive.selectedPhotoURLs), Set(fixture.photos.map(\.file.url)))
        XCTAssertEqual(additive.focusedPhotoURL, fixture.photos[0].file.url)
        let ranged = await LibraryWorkflow.perform(.select(fixture.photos[1].file.url, .range), in: library)
        XCTAssertEqual(ranged.selectedCount, 2)
        XCTAssertEqual(Set(ranged.selectedPhotoURLs), Set(fixture.photos.map(\.file.url)))
        XCTAssertEqual(ranged.focusedPhotoURL, fixture.photos[1].file.url)

        let sorted = await LibraryWorkflow.perform(.setSort(.oldest), in: library)
        XCTAssertEqual(sorted.sort, .oldest)
        XCTAssertEqual(sorted.visiblePhotoURLs, library.filteredPhotos().map(\.file.url))
        let noMatches = await LibraryWorkflow.perform(.search("no-such-photo"), in: library)
        XCTAssertEqual(noMatches.emptyState?.nextStep, .clearSearch)
        XCTAssertEqual(noMatches.searchText, "no-such-photo")
        let reset = await LibraryWorkflow.perform(.clearAllFilters, in: library)
        XCTAssertEqual(reset.searchText, "")
        XCTAssertEqual(reset.sort, .oldest)
        XCTAssertEqual(reset.photoCount, 2)
        XCTAssertEqual(reset.selectedCount, 0)
        XCTAssertNil(reset.focusedPhotoURL)
    }

    func testFailedFolderImportStillPersistsItsReference() async throws {
        let fixture = try await fixture()
        let library = fixture.library
        await library.importFolders([fixture.root.appendingPathComponent("another-offline-folder")])
        try await library.flushPersistence()
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.root.appendingPathComponent("catalog.json"))) as? [String: Any]
        XCTAssertEqual((object?["folders"] as? [[String: Any]])?.count, 2)
        XCTAssertNotNil(library.error)
    }

    func testImportActionAddsPhotosToNamedProjectAndKeepsVisibleScope() async throws {
        let fixture = try await fixture()
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
        _ = await LibraryWorkflow.perform(.openProject(fixture.projectID), in: library)
        let photo = try XCTUnwrap(library.photos.first { $0.file.url.standardizedFileURL == sourceURL.standardizedFileURL })

        let adding = Task {
            await LibraryWorkflow.perform(.addSelectedPhotos([photo], to: alternateID), in: library)
        }
        await Task.yield()
        XCTAssertEqual(library.importStatus?.phase, .importing)
        XCTAssertEqual(library.importStatus?.destinationName, "Alternate Job")
        let outcome = await adding.value

        XCTAssertEqual(outcome.importStatus?.destinationName, "Alternate Job")
        XCTAssertEqual(outcome.importStatus?.phase, .completed)
        XCTAssertEqual(library.selectedProjectID, fixture.projectID)
        XCTAssertEqual(library.projects.first { $0.id == alternateID }?.photoPaths, [sourceURL.path])
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalBytes)
        XCTAssertEqual(library.selectedProjectID, fixture.projectID)
    }

    func testFailedFolderImportCanRetryIntoOriginalDestination() async throws {
        let fixture = try await fixture()
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

    func testCullActionReportsFailureAndKeepsItsLibraryScope() async throws {
        let fixture = try await fixture()
        let library = fixture.library
        _ = LibraryWorkflow.perform(.openProject(fixture.projectID), in: library)
        let photoURL = fixture.photos[0].file.url
        _ = LibraryWorkflow.perform(.select(photoURL, .single), in: library)

        let outcome = await LibraryWorkflow.perform(.analyzeCull([photoURL], replacingExisting: false), in: library)

        XCTAssertFalse(outcome.isAnalyzingCull)
        XCTAssertEqual(outcome.cullAnalysisSummary?.attempted, 1)
        XCTAssertEqual(outcome.cullAnalysisSummary?.failed, 1)
        XCTAssertEqual(outcome.focusedPhotoURL, photoURL)
        XCTAssertEqual(library.selectedProjectID, fixture.projectID)
    }

    func testTopPickSummaryUpdatesWithSearchScope() async throws {
        let fixture = try await fixture()
        let library = fixture.library
        _ = LibraryWorkflow.perform(.openProject(fixture.projectID), in: library)
        library.topPickUnit = .images
        library.topPickValue = 1
        for (index, photo) in fixture.photos.enumerated() {
            library.photos[index].cull = CullAnalysis(score: index == 0 ? 90 : 40, sharpness: 90,
                                                      aesthetics: nil, composition: nil, eyesOpen: nil,
                                                      faceCount: 0, utilityImage: false, reasons: [])
        }

        let fullScope = LibraryWorkflow.visibleState(in: library)
        XCTAssertEqual(fullScope.topPickSummary.scopePhotoCount, 2)
        XCTAssertEqual(fullScope.topPickSummary.analyzedPhotoCount, 2)
        XCTAssertEqual(fullScope.topPickSummary.pickCount, 1)

        let narrowedScope = LibraryWorkflow.perform(.search("a.png"), in: library)
        XCTAssertEqual(narrowedScope.topPickSummary.scopePhotoCount, 1)
        XCTAssertEqual(narrowedScope.topPickSummary.analyzedPhotoCount, 1)
        XCTAssertEqual(narrowedScope.topPickSummary.pickCount, 1)
    }

    func testBulkMetadataActionReportsOnlineTargetsAndSkipsOfflineSelection() async throws {
        let fixture = try await fixture()
        let library = fixture.library
        let onlineURL = fixture.photos[0].file.url
        let offlineURL = fixture.photos[1].file.url
        library.photos[0].missing = false
        library.photos[1].missing = true
        let selectedURLs: Set<URL> = [onlineURL, offlineURL]

        let result = LibraryWorkflow.perform(
            .applyBulkMetadata(.reject, selectedURLs: selectedURLs), in: library
        )

        XCTAssertEqual(result.bulkActionSummary?.selectedCount, 2)
        XCTAssertEqual(result.bulkActionSummary?.affectedCount, 1)
        XCTAssertEqual(result.bulkActionSummary?.offlineCount, 1)
        XCTAssertEqual(result.bulkActionSummary?.message,
                       "Reject: applied to 1 online of 2 selected; 1 offline skipped.")
        XCTAssertEqual(library.photos.first { $0.file.url == onlineURL }?.flag, .rejected)
        XCTAssertEqual(library.photos.first { $0.file.url == offlineURL }?.flag, .picked)
    }

    func testGroupMembershipPersistsWithoutChangingOriginalFiles() async throws {
        let fixture = try await fixture()
        let library = fixture.library
        let photoURL = fixture.photos[0].file.url
        let originalBytes = Data("original image bytes".utf8)
        try FileManager.default.createDirectory(at: photoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try originalBytes.write(to: photoURL)

        _ = LibraryWorkflow.perform(.addPhotosToGroup([photoURL], groupID: fixture.binID), in: library)
        try await library.flushPersistence()
        let afterAdd = PhotoLibrary(storeURL: fixture.root.appendingPathComponent("catalog.json"))
        await afterAdd.load()
        XCTAssertTrue(afterAdd.photos.first { $0.file.url == photoURL }?.albumIDs.contains(fixture.binID) == true)

        _ = LibraryWorkflow.perform(.removePhotosFromGroup([photoURL], groupID: fixture.binID), in: afterAdd)
        try await afterAdd.flushPersistence()
        let afterRemove = PhotoLibrary(storeURL: fixture.root.appendingPathComponent("catalog.json"))
        await afterRemove.load()

        XCTAssertFalse(afterRemove.photos.first { $0.file.url == photoURL }?.albumIDs.contains(fixture.binID) == true)
        XCTAssertEqual(try Data(contentsOf: photoURL), originalBytes)
        XCTAssertTrue(afterRemove.projects.first { $0.id == fixture.projectID }?.photoPaths.contains(photoURL.path) == true)
    }

    func testDevelopHandoffKeepsExplicitOfflineSelectionAndVisibleTargetsDistinct() async throws {
        let fixture = try await fixture()
        let library = fixture.library
        _ = LibraryWorkflow.perform(.openProject(fixture.projectID), in: library)
        let onlineURL = fixture.photos[0].file.url
        let offlineURL = fixture.photos[1].file.url
        library.photos[0].missing = false
        library.photos[1].missing = true
        let visible = library.filteredPhotos()

        _ = LibraryWorkflow.perform(.select(offlineURL, .single), in: library)
        let selected = LibraryWorkflow.handoff(.develop, in: library, displaying: visible)
        XCTAssertEqual(selected.scope, .selected)
        XCTAssertEqual(selected.targetURLs, [])
        XCTAssertEqual(selected.selectedCount, 1)
        XCTAssertEqual(selected.onlineCount, 0)
        XCTAssertEqual(selected.offlineCount, 1)

        _ = LibraryWorkflow.perform(.clearSelection, in: library)
        let allVisible = LibraryWorkflow.handoff(.develop, in: library, displaying: visible)
        XCTAssertEqual(allVisible.scope, .visible)
        XCTAssertEqual(allVisible.targetURLs, [onlineURL])
        XCTAssertEqual(allVisible.selectedCount, 0)
        XCTAssertEqual(allVisible.onlineCount, 1)
        XCTAssertEqual(allVisible.offlineCount, 1)
    }

    func testHandoffUsesSharedFocusedAndGridSelectionURLs() async throws {
        let fixture = try await fixture()
        let library = fixture.library
        let focused = fixture.photos[0].file.url
        let gridSelected = fixture.photos[1].file.url
        library.selectedPhotoURL = focused
        library.gridSelection.select(gridSelected)

        XCTAssertEqual(library.selectedURLs, [focused, gridSelected])
        XCTAssertEqual(library.selectedCount(in: [fixture.photos[1]]), 1)
        XCTAssertEqual(library.selectedCount(in: [fixture.photos[0]]), 1)
        XCTAssertEqual(library.selectedCount(in: []), 0)
    }

    func testFolderImportProgressIsPublishedBeforeImportCompletes() async throws {
        let fixture = try await fixture()
        let library = fixture.library
        let project = try XCTUnwrap(library.projects.first { $0.id == fixture.projectID })
        let source = fixture.root.appendingPathComponent("progress-source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        var reportedProgress: [(Int, Int)] = []
        _ = await library.importFolders([source], to: project.id) { progress, total in
            reportedProgress.append((progress, total))
        }

        XCTAssertFalse(reportedProgress.isEmpty)
        XCTAssertEqual(reportedProgress.last?.0, reportedProgress.last?.1)
        XCTAssertGreaterThan(reportedProgress.last?.1 ?? 0, 0)

        LibraryWorkflow.reportFolderImportProgress(1, total: 3, project: project, in: library)

        XCTAssertEqual(library.importStatus?.phase, .importing)
        XCTAssertEqual(library.importStatus?.progress, 1)
        XCTAssertEqual(library.importStatus?.total, 3)
        XCTAssertEqual(library.importStatus?.destinationName, project.name)
    }

    func testExportHandoffSeparatesQueueFromVisiblePhotos() async throws {
        let fixture = try await fixture()
        let library = fixture.library
        _ = LibraryWorkflow.perform(.openProject(fixture.projectID), in: library)
        let onlineURL = fixture.photos[0].file.url
        let offlineURL = fixture.photos[1].file.url
        library.photos[0].missing = false
        library.photos[1].missing = true
        library.setExportQueued(true, for: [offlineURL])
        let visible = library.filteredPhotos()

        let queued = LibraryWorkflow.handoff(.exportQueue, in: library, displaying: visible)
        XCTAssertEqual(queued.scope, .queue)
        XCTAssertEqual(queued.targetURLs, [])
        XCTAssertEqual(queued.offlineCount, 1)

        library.setExportQueued(true, for: [onlineURL])
        let visibleExport = LibraryWorkflow.handoff(.exportVisible, in: library, displaying: visible)
        XCTAssertEqual(visibleExport.scope, .visible)
        XCTAssertEqual(visibleExport.targetURLs, [onlineURL])
        XCTAssertEqual(visibleExport.offlineCount, 1)
        XCTAssertEqual(library.selectedProjectID, fixture.projectID)
    }
}
