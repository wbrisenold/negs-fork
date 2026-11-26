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
}

/// The single app-level route for Library scope intents and their visible result.
@MainActor enum LibraryWorkflow {
    @discardableResult
    static func perform(_ intent: LibraryWorkflowIntent, in library: PhotoLibrary) -> LibraryWorkflowVisibleState {
        let previousScope = ScopeIdentity(library)
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
        case .importFolders, .addSelectedPhotos: break
        }

        switch intent {
        case .search, .clearSearch, .setFilter, .removeFilter, .toggleCullFilter, .clearAllFilters, .setSort:
            library.pruneGridSelection(to: library.filteredPhotos().map(\.file.url))
        default: break
        }

        // Selection and photo-specific details belong to the previous scope.
        if previousScope != ScopeIdentity(library) { library.clearPhotoSelection() }
        return visibleState(in: library)
    }

    static func visibleState(in library: PhotoLibrary, displaying displayedPhotos: [LibraryPhoto]? = nil) -> LibraryWorkflowVisibleState {
        let photos = displayedPhotos ?? library.filteredPhotos()
        let project = library.projects.first { $0.id == library.selectedProjectID }
        let group = library.albums.first { $0.id == library.selectedAlbumID }
        let folder = library.folders.first { $0.id == library.selectedFolderID }
        let smartCollection = library.smartCollections.first { $0.id == library.selectedSmartCollectionID }
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
            selectedPhotoURLs: photos.filter { photo in
                library.gridSelection.selected.contains(photo.file.url) || library.selectedPhotoURL == photo.file.url
            }.map(\.file.url),
            focusedPhotoURL: library.selectedPhotoURL,
            searchText: library.searchText,
            activeFilters: activeFilters,
            sort: library.sort
        )
    }

    @discardableResult
    static func perform(_ intent: LibraryWorkflowIntent, in library: PhotoLibrary) async -> LibraryWorkflowVisibleState {
        switch intent {
        case .importFolders(let urls, let projectID):
            await importFolders(urls, to: projectID, in: library)
        case .addSelectedPhotos(let photos, let projectID):
            await addSelectedPhotos(photos, to: projectID, in: library)
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
        let result = await library.importFolders(urls, to: projectID)
        let failures = result.failures
        library.importStatus = LibraryImportStatus(projectID: projectID, destinationName: project.name,
                                                   phase: failures.isEmpty ? .completed : .failed,
                                                   importedCount: result.importedCount,
                                                   progress: result.scannedCount, total: max(urls.count, result.scannedCount),
                                                   message: failures.first,
                                                   canRetry: !failures.isEmpty)
        if failures.isEmpty { library.retryableImport = nil }
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
