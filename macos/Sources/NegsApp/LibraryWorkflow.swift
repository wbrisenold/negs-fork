import Foundation

enum LibraryWorkflowIntent {
    case openProject(UUID)
    case openReview(LibraryFilter)
    case openGroup(UUID)
    case search(String)
    case clearSearch
    case setFilter(LibraryFilter)
    case removeFilter(LibraryActiveFilter)
    case toggleCullFilter(CullFilterChip)
    case clearAllFilters
    case setSort(LibrarySort)
    case select(URL, LibrarySelectionMode)
    case clearSelection
    case importFolders([URL], to: UUID)
    case addSelectedPhotos([LibraryPhoto], to: UUID)
    case analyzeCull(Set<URL>, replacingExisting: Bool)
    case applyBulkMetadata(LibraryBulkMetadataAction, selectedURLs: Set<URL>)
    case addPhotosToGroup(Set<URL>, groupID: UUID)
    case removePhotosFromGroup(Set<URL>, groupID: UUID)
}

enum LibraryBulkMetadataAction: Equatable {
    case pick
    case reject
    case clearMarks
    case rate(Int)
    case clearRatings

    var title: String {
        switch self {
        case .pick: "Pick"
        case .reject: "Reject"
        case .clearMarks: "Clear marks"
        case .rate(let rating): "Rate \(rating) stars"
        case .clearRatings: "Clear ratings"
        }
    }
}

enum LibraryHandoffAction {
    case develop
    case exportVisible
    case exportQueue
}

enum LibraryHandoffScope: Equatable {
    case selected
    case visible
    case queue
}

struct LibraryHandoffResult: Equatable {
    let scope: LibraryHandoffScope
    let targetURLs: [URL]
    let selectedCount: Int
    let onlineCount: Int
    let offlineCount: Int

    var summary: String {
        let source = switch scope {
        case .selected: "selected"
        case .visible: "visible"
        case .queue: "queued"
        }
        return "\(onlineCount) online \(source) photos · \(offlineCount) offline skipped"
    }
}

struct LibraryBulkActionSummary: Equatable {
    let action: String
    let selectedCount: Int
    let affectedCount: Int
    let offlineCount: Int

    var message: String {
        if affectedCount == 0 {
            return "\(action): no online photos updated; \(selectedCount) selected, \(offlineCount) offline."
        }
        let skipped = offlineCount == 0 ? "" : "; \(offlineCount) offline skipped"
        return "\(action): applied to \(affectedCount) online of \(selectedCount) selected\(skipped)."
    }
}

enum LibrarySelectionMode: Equatable {
    case single
    case range
    case additive
}

enum LibraryActiveFilter: Hashable {
    case category(LibraryFilter)
    case cull(CullFilterChip)
}

enum LibraryImportPhase: Equatable {
    case importing
    case completed
    case failed
}

struct LibraryImportStatus: Equatable {
    let projectID: UUID
    let destinationName: String
    let phase: LibraryImportPhase
    let importedCount: Int
    let progress: Int
    let total: Int
    let message: String?
    let canRetry: Bool
}

enum LibraryImportRequest {
    case folders([URL], UUID)
    case photos([URL], UUID)
}

enum LibraryWorkflowNextStep: Equatable {
    case createProject
    case addPhotos
    case browseProjectPhotos
    case clearSearch
    case clearFilters
    case refreshSources
}

struct LibraryWorkflowEmptyState: Equatable {
    let title: String
    let explanation: String
    let nextStep: LibraryWorkflowNextStep
}

struct LibraryTopPickSummary: Equatable {
    let scopePhotoCount: Int
    let analyzedPhotoCount: Int
    let pickCount: Int
    let unit: TopPickUnit
    let value: Int

    var label: String {
        guard analyzedPhotoCount > 0 else {
            return "Top Picks · Not analyzed · 0 of \(scopePhotoCount) photos"
        }
        let analyzedDetail = analyzedPhotoCount < scopePhotoCount ? " · \(analyzedPhotoCount) analyzed" : ""
        let quota = unit == .percent ? " · Top \(value)%" : ""
        return "Top Picks · \(pickCount) of \(scopePhotoCount) photos\(analyzedDetail)\(quota)"
    }
}

struct LibraryWorkflowVisibleState: Equatable {
    let scopeLabel: String
    let title: String
    let projectTitle: String?
    let photoCount: Int
    let selectedCount: Int
    let emptyState: LibraryWorkflowEmptyState?
    let importStatus: LibraryImportStatus?
    let visiblePhotoURLs: [URL]
    let selectedPhotoURLs: [URL]
    let focusedPhotoURL: URL?
    let searchText: String
    let activeFilters: Set<LibraryActiveFilter>
    let sort: LibrarySort
    let isAnalyzingCull: Bool
    let cullProgress: Int
    let cullTotal: Int
    let cullAnalysisSummary: CullAnalysisSummary?
    let topPickSummary: LibraryTopPickSummary
    let bulkActionSummary: LibraryBulkActionSummary?
}

/// The single app-level route for Library scope intents and their visible result.
@MainActor enum LibraryWorkflow {
    static func handoff(
        _ action: LibraryHandoffAction,
        in library: PhotoLibrary,
        displaying displayedPhotos: [LibraryPhoto]
    ) -> LibraryHandoffResult {
        let selectedURLs = library.selectedURLs
        let scope: LibraryHandoffScope
        let requested: [LibraryPhoto]
        switch action {
        case .develop:
            if selectedURLs.isEmpty {
                scope = .visible
                requested = displayedPhotos
            } else {
                scope = .selected
                requested = displayedPhotos.filter { selectedURLs.contains($0.file.url) }
            }
        case .exportVisible:
            scope = .visible
            requested = displayedPhotos
        case .exportQueue:
            scope = .queue
            requested = displayedPhotos.filter(\.selectedForExport)
        }
        let online = requested.filter { !$0.missing }
        return LibraryHandoffResult(
            scope: scope,
            targetURLs: online.map { $0.file.url },
            selectedCount: requested.count,
            onlineCount: online.count,
            offlineCount: requested.count - online.count
        )
    }

    @discardableResult
    static func perform(_ intent: LibraryWorkflowIntent, in library: PhotoLibrary) -> LibraryWorkflowVisibleState {
        let previousScope = ScopeIdentity(library)
        var bulkActionSummary: LibraryBulkActionSummary?
        switch intent {
        case .openProject(let id): library.selectProject(id)
        case .openReview(let filter): library.selectReviewFilter(filter)
        case .openGroup(let id): library.selectGroup(id)
        case .search(let query): library.searchText = query
        case .clearSearch: library.searchText = ""
        case .setFilter(let filter):
            library.filter = filter
            library.selectedSmartCollectionID = nil
        case .removeFilter(let filter):
            switch filter {
            case .category: library.filter = .all; library.selectedSmartCollectionID = nil
            case .cull(let value): library.cullFilters.remove(value)
            }
        case .toggleCullFilter(let filter):
            if library.cullFilters.contains(filter) { library.cullFilters.remove(filter) }
            else { library.cullFilters.insert(filter) }
        case .clearAllFilters:
            library.searchText = ""
            library.filter = .all
            library.selectedSmartCollectionID = nil
            library.cullFilters.removeAll()
        case .setSort(let sort): library.sort = sort
        case .select(let url, let mode):
            let order = library.filteredPhotos().map(\.file.url)
            guard order.contains(url) else { break }
            library.selectGridPhoto(url, extending: mode == .range, toggling: mode == .additive, in: order)
        case .clearSelection: library.gridSelection.deselectAll()
        case .applyBulkMetadata(let action, let selectedURLs):
            let selectedPhotos = library.photos.filter { selectedURLs.contains($0.file.url) }
            let onlinePhotos = selectedPhotos.filter { !$0.missing }
            switch action {
            case .pick: library.setFlag(.picked, for: onlinePhotos.map(\.file.url))
            case .reject: library.setFlag(.rejected, for: onlinePhotos.map(\.file.url))
            case .clearMarks: library.setFlag(.none, for: onlinePhotos.map(\.file.url))
            case .rate(let rating): library.setRating(rating, for: onlinePhotos.map(\.file.url))
            case .clearRatings: library.setRating(0, for: onlinePhotos.map(\.file.url))
            }
            bulkActionSummary = LibraryBulkActionSummary(
                action: action.title,
                selectedCount: selectedPhotos.count,
                affectedCount: onlinePhotos.count,
                offlineCount: selectedPhotos.count - onlinePhotos.count
            )
        case .addPhotosToGroup(let urls, let groupID):
            library.addToBin(library.photos.filter { urls.contains($0.file.url) }, binID: groupID)
        case .removePhotosFromGroup(let urls, let groupID):
            library.removeFromBin(library.photos.filter { urls.contains($0.file.url) }, binID: groupID)
        case .importFolders, .addSelectedPhotos, .analyzeCull: break
        }

        switch intent {
        case .search, .clearSearch, .setFilter, .removeFilter, .toggleCullFilter, .clearAllFilters, .setSort:
            library.pruneGridSelection(to: library.filteredPhotos().map(\.file.url))
        default: break
        }

        // Selection and photo-specific details belong to the previous scope.
        if previousScope != ScopeIdentity(library) { library.clearPhotoSelection() }
        return visibleState(in: library, bulkActionSummary: bulkActionSummary)
    }

    static func visibleState(
        in library: PhotoLibrary,
        displaying displayedPhotos: [LibraryPhoto]? = nil,
        bulkActionSummary: LibraryBulkActionSummary? = nil
    ) -> LibraryWorkflowVisibleState {
        let photos = displayedPhotos ?? library.filteredPhotos()
        let project = library.projects.first { $0.id == library.selectedProjectID }
        let group = library.albums.first { $0.id == library.selectedAlbumID }
        let folder = library.folders.first { $0.id == library.selectedFolderID }
        let smartCollection = library.smartCollections.first { $0.id == library.selectedSmartCollectionID }
        let topPickSummary = topPickSummary(in: library)
        let title = group?.name ?? smartCollection?.name ?? folder?.name
            ?? (library.filter == .all ? project?.name ?? "Library" : library.filter.title)
        let projectContext = project.map { " · \($0.name.uppercased())" } ?? ""
        let scopeLabel = group != nil ? "PROJECT\(projectContext) · GROUP"
            : project != nil && library.filter != .all ? "PROJECT\(projectContext) · REVIEW"
            : folder != nil ? "PROJECT\(projectContext) · FOLDER"
            : project != nil ? "PROJECT\(projectContext) · ALL PHOTOS"
            : smartCollection != nil ? "SMART COLLECTION"
            : "LIBRARY"
        let emptyState: LibraryWorkflowEmptyState?

        if !photos.isEmpty {
            emptyState = nil
        } else if !library.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            emptyState = LibraryWorkflowEmptyState(
                title: "No Photos Match",
                explanation: "Try another name or clear the search to see photographs in this view.",
                nextStep: .clearSearch
            )
        } else if !library.visiblePhotos.isEmpty || library.filter != .all || !library.cullFilters.isEmpty {
            emptyState = LibraryWorkflowEmptyState(
                title: "Filters Hide Every Photo",
                explanation: "Clear the active filters to show photographs in this scope.",
                nextStep: .clearFilters
            )
        } else if group != nil {
            emptyState = LibraryWorkflowEmptyState(
                title: "This group is empty",
                explanation: "Choose All Photos in this project, select photographs, then add them to this group.",
                nextStep: .browseProjectPhotos
            )
        } else if project == nil {
            emptyState = LibraryWorkflowEmptyState(
                title: "Create a Project",
                explanation: "Projects keep each job’s photographs and groups together.",
                nextStep: .createProject
            )
        } else if project?.folderIDs.isEmpty == true && project?.photoPaths.isEmpty == true {
            emptyState = LibraryWorkflowEmptyState(
                title: "Project Ready",
                explanation: "Add photos to this project. Originals stay where they are.",
                nextStep: .addPhotos
            )
        } else {
            emptyState = LibraryWorkflowEmptyState(
                title: "No Photos Available",
                explanation: "Refresh this project’s sources to check for changes.",
                nextStep: .refreshSources
            )
        }

        var activeFilters = Set<LibraryActiveFilter>()
        let activeCategory = library.smartCollections.first { $0.id == library.selectedSmartCollectionID }?.filter ?? library.filter
        if activeCategory != .all { activeFilters.insert(.category(activeCategory)) }
        activeFilters.formUnion(library.cullFilters.map(LibraryActiveFilter.cull))
        return LibraryWorkflowVisibleState(
            scopeLabel: scopeLabel,
            title: title,
            projectTitle: project?.name,
            photoCount: photos.count,
            selectedCount: library.selectedCount(in: photos),
            emptyState: emptyState,
            importStatus: library.importStatus,
            visiblePhotoURLs: photos.map(\.file.url),
            selectedPhotoURLs: photos.filter { library.selectedURLs.contains($0.file.url) }.map(\.file.url),
            focusedPhotoURL: library.selectedPhotoURL,
            searchText: library.searchText,
            activeFilters: activeFilters,
            sort: library.sort,
            isAnalyzingCull: library.analyzingCull,
            cullProgress: library.cullProgress,
            cullTotal: library.cullTotal,
            cullAnalysisSummary: library.cullAnalysisSummary,
            topPickSummary: topPickSummary,
            bulkActionSummary: bulkActionSummary
        )
    }

    static func topPickSummary(in library: PhotoLibrary) -> LibraryTopPickSummary {
        let scope = library.visiblePhotos
        let analyzedPhotoCount = scope.reduce(into: 0) { count, photo in
            if photo.cull != nil && !(photo.cull?.failed ?? true) { count += 1 }
        }
        return LibraryTopPickSummary(
            scopePhotoCount: scope.count,
            analyzedPhotoCount: analyzedPhotoCount,
            pickCount: analyzedPhotoCount > 0 ? library.topPickURLs(in: scope).count : 0,
            unit: library.topPickUnit,
            value: library.topPickValue
        )
    }

    @discardableResult
    static func perform(_ intent: LibraryWorkflowIntent, in library: PhotoLibrary) async -> LibraryWorkflowVisibleState {
        switch intent {
        case .importFolders(let urls, let projectID):
            await importFolders(urls, to: projectID, in: library)
        case .addSelectedPhotos(let photos, let projectID):
            await addSelectedPhotos(photos, to: projectID, in: library)
        case .analyzeCull(let scope, let replacingExisting):
            await library.analyzeCull(in: scope, replacingExisting: replacingExisting)
        default: break
        }
        return visibleState(in: library)
    }

    @discardableResult
    static func retryImport(in library: PhotoLibrary) async -> LibraryWorkflowVisibleState {
        guard let request = library.retryableImport else { return visibleState(in: library) }
        switch request {
        case .folders(let urls, let projectID): await importFolders(urls, to: projectID, in: library)
        case .photos(let urls, let projectID):
            let photos = library.photos.filter { urls.contains($0.file.url.standardizedFileURL) }
            await addSelectedPhotos(photos, to: projectID, in: library)
        }
        return visibleState(in: library)
    }

    private static func importFolders(_ urls: [URL], to projectID: UUID, in library: PhotoLibrary) async {
        guard let project = library.projects.first(where: { $0.id == projectID }) else { return }
        library.retryableImport = .folders(urls, projectID)
        library.importStatus = LibraryImportStatus(projectID: projectID, destinationName: project.name, phase: .importing,
                                                   importedCount: 0, progress: 0, total: urls.count,
                                                   message: nil, canRetry: false)
        let result = await library.importFolders(urls, to: projectID) { progress, total in
            reportFolderImportProgress(progress, total: total, project: project, in: library)
        }
        let failures = result.failures
        library.importStatus = LibraryImportStatus(projectID: projectID, destinationName: project.name,
                                                   phase: failures.isEmpty ? .completed : .failed,
                                                   importedCount: result.importedCount,
                                                   progress: result.scannedCount, total: max(urls.count, result.scannedCount),
                                                   message: failures.first,
                                                   canRetry: !failures.isEmpty)
        if failures.isEmpty { library.retryableImport = nil }
    }

    static func reportFolderImportProgress(_ progress: Int, total: Int,
                                           project: LibraryProject, in library: PhotoLibrary) {
        library.importStatus = LibraryImportStatus(projectID: project.id, destinationName: project.name,
                                                   phase: .importing, importedCount: 0,
                                                   progress: progress, total: total,
                                                   message: nil, canRetry: false)
    }

    private static func addSelectedPhotos(_ photos: [LibraryPhoto], to projectID: UUID, in library: PhotoLibrary) async {
        guard let project = library.projects.first(where: { $0.id == projectID }) else { return }
        let urls = photos.map { $0.file.url.standardizedFileURL }
        library.retryableImport = .photos(urls, projectID)
        library.importStatus = LibraryImportStatus(projectID: projectID, destinationName: project.name, phase: .importing,
                                                   importedCount: 0, progress: 0, total: urls.count,
                                                   message: nil, canRetry: false)
        await Task.yield()
        library.add(photos, to: projectID)
        library.importStatus = LibraryImportStatus(projectID: projectID, destinationName: project.name, phase: .completed,
                                                   importedCount: urls.count, progress: urls.count, total: urls.count,
                                                   message: nil, canRetry: false)
        library.retryableImport = nil
    }

    @MainActor private struct ScopeIdentity: Equatable {
        let projectID: UUID?
        let folderID: UUID?
        let groupID: UUID?
        let smartCollectionID: UUID?
        let filter: LibraryFilter

        init(_ library: PhotoLibrary) {
            projectID = library.selectedProjectID
            folderID = library.selectedFolderID
            groupID = library.selectedAlbumID
            smartCollectionID = library.selectedSmartCollectionID
            filter = library.filter
        }
    }
}
