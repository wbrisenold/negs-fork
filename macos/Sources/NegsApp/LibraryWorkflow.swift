import Foundation

enum LibraryWorkflowIntent {
    case openProject(UUID)
    case openReview(LibraryFilter)
    case openGroup(UUID)
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

        return LibraryWorkflowVisibleState(
            scopeLabel: scopeLabel,
            title: title,
            projectTitle: project?.name,
            photoCount: photos.count,
            selectedCount: library.selectedCount(in: photos),
            emptyState: emptyState
        )
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
