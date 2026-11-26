import AppKit
import SwiftUI

struct LibraryWorkspaceView: View {
    let model: EditorModel
    @Bindable private var library: PhotoLibrary
    @AppStorage("negs.library.thumbnailSize") private var thumbnailSize = 176.0
    @AppStorage("negs.library.showInspector") private var showInspector = false
    @State private var librarySearchInput: String
    @State private var showingProjectSheet = false
    @State private var showingProjectRenameSheet = false
    @State private var projectToRename: UUID?
    @State private var showingCategorySheet = false
    @State private var categoryToRename: UUID?
    @State private var categoryToReset: UUID?
    @State private var categoryError: String?
    @State private var showingProjectPhotoPicker = false
    @State private var showingCategoryResetConfirmation = false
    @State private var showingFilterOptions = false
    @State private var showingTopPickOptions = false
    @State private var projectName = ""
    @FocusState private var librarySearchFocused: Bool
    @FocusState private var libraryGridFocused: Bool
    private var cullFilters: Set<CullFilterChip> { library.cullFilters }

    private var selected: LibraryPhoto? { library.selectedPhoto }
    private var hasLocationScope: Bool { library.selectedFolderID != nil || library.selectedProjectID != nil }
    private func displayedPhotos(from visiblePhotos: [LibraryPhoto], topPicks: Set<URL>? = nil) -> [LibraryPhoto] {
        library.filteredPhotos(from: visiblePhotos, topPicks: topPicks)
    }
    private var addableCullFilters: [CullFilterChip] {
        CullFilterChip.allCases.filter { $0 != .topPicks }
    }
    private func filterTitle(_ filter: CullFilterChip, topPickLabel: String) -> String {
        filter == .topPicks ? topPickLabel : filter.title
    }

    init(model: EditorModel) {
        self.model = model
        self._library = Bindable(wrappedValue: model.photoLibrary)
        self._librarySearchInput = State(initialValue: model.photoLibrary.searchText)
    }

    var body: some View {
        let visiblePhotos = library.visiblePhotos
        let analyzedTopPicks = visiblePhotos.reduce(into: 0) { count, photo in
            if photo.cull != nil && !(photo.cull?.failed ?? true) { count += 1 }
        }
        let topPickURLs = analyzedTopPicks > 0 ? library.topPickURLs(in: visiblePhotos) : []
        let topPickQuota = library.topPickUnit == .percent ? " · \(library.topPickValue)%" : ""
        let topPickLabel = analyzedTopPicks == 0
            ? "Top Picks · Not analyzed"
            : "Top \(topPickURLs.count) of \(analyzedTopPicks)\(topPickQuota)"
        return HSplitView {
            sidebar.frame(minWidth: 172, idealWidth: 196, maxWidth: 228)
                .padding(StudioStyle.Space.paneInset)
                .background(Theme.film)
            content(visiblePhotos: visiblePhotos, topPickURLs: topPickURLs, topPickLabel: topPickLabel)
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, StudioStyle.Space.paneInset)
            if showInspector {
                inspector(topPickURLs: topPickURLs)
                    .frame(minWidth: 270, idealWidth: 310, maxWidth: 350)
                    .padding(StudioStyle.Space.paneInset)
                    .background(Theme.panel)
            }
        }
        .background(Theme.film)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .buttonStyle(OutlinedButtonStyle())
        .task {
            await library.load()
            if let source = model.source { await library.syncEditedPhoto(source) }
        }
        .onChange(of: model.source) { _, source in
            guard model.workspace == .library, let source else { return }
            Task { await library.syncEditedPhoto(source) }
        }
        .onChange(of: model.librarySearchFocusRequest) { _, _ in focusLibrarySearch() }
        .onAppear {
            if model.librarySearchFocusRequest > 0 { focusLibrarySearch() }
        }
        .sheet(isPresented: $showingProjectSheet) { projectSheet }
        .sheet(isPresented: $showingProjectRenameSheet) { projectRenameSheet }
        .sheet(isPresented: $showingCategorySheet) { categorySheet }
        .sheet(isPresented: $showingProjectPhotoPicker) {
            if let projectID = library.selectedProjectID {
                ProjectPhotoPicker(library: library, projectID: projectID, addSourceFolder: importFolders)
            }
        }
        .confirmationDialog("Reset all edits in this group?", isPresented: $showingCategoryResetConfirmation,
                            titleVisibility: .visible) {
            Button("Reset Group Edits", role: .destructive) {
                guard let id = categoryToReset else { return }
                model.resetEdits(of: library.photos.filter { $0.albumIDs.contains(id) && !$0.missing }.map { $0.file.url })
                categoryToReset = nil
            }
            Button("Cancel", role: .cancel) { categoryToReset = nil }
        } message: {
            Text("Online photos in this group will return to their default edits. Offline photos are left unchanged until they’re available. Original files are kept.")
        }
    }

    private var sidebar: some View {
        return ScrollView {
            VStack(alignment: .leading, spacing: StudioStyle.Space.section) {
                sidebarSection("PROJECTS", subtitle: "Each project keeps its photos and groups together.", actionTitle: "New Project…", action: {
                    projectName = ""
                    showingProjectSheet = true
                }) {
                    if library.projects.isEmpty {
                        Text("No projects yet. Create one for a client or job.")
                            .font(Theme.ui(10)).foregroundStyle(Theme.dim)
                            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 7)
                    } else {
                        ForEach(library.projects) { project in
                            NavigationRow(title: project.name, symbol: "briefcase",
                                          count: library.count(for: project), selected: library.selectedProjectID == project.id) {
                                _ = LibraryWorkflow.perform(.openProject(project.id), in: library)
                            }
                            .help("Open this project and its groups. Original files stay in place.")
                            .contextMenu {
                                Button("Rename Project…", systemImage: "pencil") {
                                    projectToRename = project.id
                                    projectName = project.name
                                    showingProjectRenameSheet = true
                                }
                                Button("Export Project…", systemImage: "square.and.arrow.up") {
                                    exportProjectPanel(project.id)
                                }
                                Divider()
                                Button("Delete Project", systemImage: "trash", role: .destructive) {
                                    library.deleteProject(project.id)
                                }
                            }
                        }
                    }
                }
                if let project = library.projects.first(where: { $0.id == library.selectedProjectID }) {
                    sidebarSection("REVIEW") {
                        NavigationRow(title: "All Photos", symbol: "square.grid.2x2",
                                      count: library.count(for: project),
                                      selected: library.selectedFolderID == nil && library.selectedAlbumID == nil
                                        && library.selectedSmartCollectionID == nil && library.filter == .all) {
                            _ = LibraryWorkflow.perform(.openReview(.all), in: library)
                        }
                        ForEach(LibraryFilter.allCases.filter { $0 != .all && ($0 != .missing || hasLocationScope) }) { filter in
                            NavigationRow(title: filter.title, symbol: filter.symbol, count: library.count(for: filter),
                                          selected: library.selectedFolderID == nil && library.selectedAlbumID == nil
                                            && library.selectedSmartCollectionID == nil && library.filter == filter) {
                                _ = LibraryWorkflow.perform(.openReview(filter), in: library)
                            }
                        }
                    }
                    sidebarSection("GROUPS", subtitle: "Collect related photos for a job or client.", actionTitle: "New Group…", action: {
                        categoryToRename = nil
                        projectName = ""
                        categoryError = nil
                        showingCategorySheet = true
                    }) {
                        ForEach(library.categories(for: project.id)) { category in
                            NavigationRow(title: category.name, symbol: "square.grid.2x2",
                                          count: library.count(for: category), selected: library.selectedAlbumID == category.id) {
                                _ = LibraryWorkflow.perform(.openGroup(category.id), in: library)
                            }
                            .contextMenu { categoryActions(category) }
                        }
                        if library.categories(for: project.id).isEmpty {
                            Text("No groups yet. Create one to collect related photos.")
                                .font(Theme.ui(10)).foregroundStyle(Theme.dim)
                                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 7)
                        }
                    }
                } else {
                    ContentUnavailableView("Create a Project", systemImage: "briefcase",
                                           description: Text("Projects contain All Photos and their own groups."))
                        .font(Theme.ui(10)).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 14)
        }
        .background(Theme.bg)
    }

    private func content(visiblePhotos: [LibraryPhoto], topPickURLs: Set<URL>, topPickLabel: String) -> some View {
        let displayedPhotos = displayedPhotos(from: visiblePhotos, topPicks: topPickURLs)
        let workflowState = LibraryWorkflow.visibleState(in: library, displaying: displayedPhotos)
        let editablePhotos = displayedPhotos.filter { !$0.missing }
        let selectedURLs = library.gridSelection.selected.union(library.selectedPhotoURL.map { Set([$0]) } ?? [])
        let selectedPhotos = displayedPhotos.filter { selectedURLs.contains($0.file.url) }
        let selectedReady = editablePhotos.filter { selectedURLs.contains($0.file.url) }
        // An explicit selection containing only offline files must not fall
        // through to editing every available photo in the view.
        let editTargets = selectedURLs.isEmpty ? editablePhotos : selectedReady
        let unqueuedSelectionCount = selectedReady.filter { !$0.selectedForExport }.count
        let offlineCount = displayedPhotos.count - editablePhotos.count
        let projectIsEmpty = workflowState.emptyState?.nextStep == .addPhotos
        return VStack(spacing: 0) {
            HStack(spacing: StudioStyle.Space.compact) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(workflowState.scopeLabel).font(Theme.metadata(10)).tracking(1.0).foregroundStyle(Theme.dim)
                    HStack(spacing: 7) {
                        Text(workflowState.title).font(Theme.text(18, weight: 600)).foregroundStyle(Theme.paper)
                            .lineLimit(1).truncationMode(.tail)
                        Text("\(workflowState.photoCount) photos · \(workflowState.selectedCount) selected")
                            .font(Theme.metadata(10.5)).foregroundStyle(Theme.dim).monospacedDigit()
                            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                            .help(library.selectedProjectID != nil
                                  ? "Project membership and library changes are saved automatically on this Mac."
                                  : "Photographs in the current Library view.")
                        if library.analyzingCull {
                            Text("Analyzing \(library.cullProgress) / \(library.cullTotal)")
                                .font(Theme.ui(10)).foregroundStyle(Theme.dim)
                        }
                        if library.refreshing {
                            ProgressView().controlSize(.small)
                            Text("Scanning \(library.refreshProgress) / \(library.refreshTotal) sources")
                                .font(Theme.ui(10)).foregroundStyle(Theme.dim).monospacedDigit()
                                .help("Folder scans run in the background; the Library remains available while they finish.")
                        }
                    }
                }
                Spacer(minLength: 8)
                if !library.photos.isEmpty {
                TextField("Search Library", text: $librarySearchInput)
                    .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 145)
                    .focused($librarySearchFocused)
                    .onSubmit { library.searchText = librarySearchInput }
                    .task(id: librarySearchInput) {
                        guard librarySearchInput != library.searchText else { return }
                        try? await Task.sleep(nanoseconds: 180_000_000)
                        guard !Task.isCancelled else { return }
                        library.searchText = librarySearchInput
                    }
                    .overlay(alignment: .trailing) {
                        if !librarySearchInput.isEmpty {
                            Button {
                                librarySearchInput = ""
                                library.searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Clear library search")
                            .padding(.trailing, 6)
                        }
                    }
                    .onChange(of: library.searchText) { _, value in
                        if librarySearchInput != value { librarySearchInput = value }
                    }
                }
                if !library.photos.isEmpty {
                Menu {
                    ForEach(LibrarySort.allCases) { sort in
                        Button {
                            library.sort = sort
                        } label: {
                            if library.sort == sort { Label(sort.title, systemImage: "checkmark") }
                            else { Text(sort.title) }
                        }
                    }
                } label: {
                    Label(library.sort.title, systemImage: "arrow.up.arrow.down")
                        .font(.callout)
                }
                .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
                .help("Sort photos")
                }
                Menu {
                    Button("Open Project…", systemImage: "folder", action: openProjectPanel)
                    if let projectID = library.selectedProjectID {
                        Button("Save Project…", systemImage: "square.and.arrow.down") {
                            exportProjectPanel(projectID)
                        }
                    }
                    Divider()
                    Button(library.analyzingCull ? "Analyzing…" : library.photos.contains(where: { $0.cull != nil }) ? "Re-analyze with AI" : "Analyze with AI") {
                        Task { await library.analyzeCull(replacingExisting: library.photos.allSatisfy { $0.cull != nil }) }
                    }
                    .disabled(library.analyzingCull || !library.photos.contains(where: { !$0.missing }))
                    Divider()
                    Button(library.refreshing ? "Refreshing…" : "Refresh Project Sources", systemImage: "arrow.clockwise") {
                        Task { await library.refresh() }
                    }
                    .disabled(library.refreshing)
                    Divider()
                    Slider(value: $thumbnailSize, in: 120...256) { Text("Thumbnail Size") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(Theme.ui(14))
                }
                .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
                .help("Project, analysis and display actions")
                Button { showInspector.toggle() } label: {
                    Image(systemName: "sidebar.trailing")
                        .font(Theme.ui(14))
                        .foregroundStyle(showInspector ? Theme.paper : Theme.dim)
                        .frame(width: 28, height: 26)
                }
                .buttonStyle(WordActionStyle())
                .help(showInspector ? "Hide photo details" : "Show photo details")
            }
            .controlSize(.small)
            .padding(.horizontal, StudioStyle.Space.section).padding(.vertical, 11)
            Divider()
            if let error = library.error {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                    Text(error).font(Theme.ui(11)).foregroundStyle(Theme.label)
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Retry") { Task { await library.refresh() } }
                        .buttonStyle(OutlinedButtonStyle()).disabled(library.refreshing)
                }
                .padding(.horizontal, StudioStyle.Space.section).padding(.vertical, 7)
                .background(Theme.warn.opacity(0.08))
                Divider()
            }
            if let importStatus = workflowState.importStatus {
                HStack(spacing: StudioStyle.Space.standard) {
                    if importStatus.phase == .importing {
                        ProgressView(value: Double(importStatus.progress), total: Double(max(importStatus.total, 1)))
                            .frame(width: 92)
                            .accessibilityLabel("Import progress")
                    } else {
                        Image(systemName: importStatus.phase == .failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(importStatus.phase == .failed ? Theme.warn : StudioStyle.positive)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(importStatus.phase == .importing ? "Importing into \(importStatus.destinationName)" :
                             importStatus.phase == .completed ? "Added \(importStatus.importedCount) photos to \(importStatus.destinationName)" :
                             "Import to \(importStatus.destinationName) needs attention")
                            .font(Theme.ui(11, weight: .medium)).foregroundStyle(Theme.label)
                        if let message = importStatus.message {
                            Text(message).font(Theme.ui(10)).foregroundStyle(Theme.dim).lineLimit(2)
                        } else if importStatus.phase == .importing {
                            Text("Scanning source folders…").font(Theme.ui(10)).foregroundStyle(Theme.dim)
                        }
                    }
                    Spacer(minLength: 4)
                    if importStatus.canRetry {
                        Button("Retry Import") {
                            Task { _ = await LibraryWorkflow.retryImport(in: library) }
                        }
                        .buttonStyle(StudioActionButtonStyle(kind: .secondary))
                        .accessibilityLabel("Retry import into \(importStatus.destinationName)")
                    }
                }
                .padding(.horizontal, StudioStyle.Space.section).padding(.vertical, StudioStyle.Space.compact)
                .studioWorkspaceCard()
                .padding(.horizontal, StudioStyle.Space.section).padding(.bottom, StudioStyle.Space.compact)
            }
            HStack(spacing: 8) {
                if !library.photos.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                Button { showingFilterOptions = true } label: {
                    Text("Filters")
                }
                .buttonStyle(OutlinedButtonStyle()).fixedSize()
                .disabled(cullFilters.count >= addableCullFilters.count)
                .popover(isPresented: $showingFilterOptions, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: StudioStyle.Space.tight) {
                        Text("FILTER PHOTOS")
                            .font(Theme.ui(10, weight: .semibold)).tracking(0.5).foregroundStyle(Theme.dim)
                            .padding(.horizontal, 8).padding(.bottom, 2)
                        Text("All selected filters must match.")
                            .font(Theme.text(13, italic: true)).foregroundStyle(Theme.dim).padding(.horizontal, 8)
                        ForEach(addableCullFilters.filter { !cullFilters.contains($0) }, id: \.self) { filter in
                            Button {
                                library.cullFilters.insert(filter)
                                showingFilterOptions = false
                            } label: {
                                Label(filterTitle(filter, topPickLabel: topPickLabel), systemImage: filter.symbol)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(WordActionStyle()).padding(.horizontal, 8).padding(.vertical, 6)
                        }
                        if !cullFilters.isEmpty {
                            Divider().padding(.vertical, 3)
                            Button("Clear Filters") {
                                library.cullFilters.removeAll()
                                showingFilterOptions = false
                            }
                            .buttonStyle(WordActionStyle()).padding(.horizontal, 8).padding(.vertical, 6)
                        }
                    }
                    .padding(10).frame(width: 210)
                }
                ForEach(CullFilterChip.allCases.filter { cullFilters.contains($0) }, id: \.self) { filter in
                    HStack(spacing: 4) {
                        Text(filterTitle(filter, topPickLabel: topPickLabel))
                        Button { library.cullFilters.remove(filter) } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }.buttonStyle(WordActionStyle()).help("Remove \(filterTitle(filter, topPickLabel: topPickLabel)) filter")
                    }
                    .font(Theme.ui(10, weight: .medium)).padding(.horizontal, 7).padding(.vertical, 4)
                    .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.accent.opacity(0.32), lineWidth: 0.7))
                }
                Button {
                    showingTopPickOptions = true
                } label: {
                    Text(cullFilters.contains(.topPicks) ? "Top Picks · On" : "Top Picks…")
                }
                .buttonStyle(OutlinedButtonStyle())
                .popover(isPresented: $showingTopPickOptions, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("TOP PICKS").font(Theme.ui(10, weight: .semibold)).tracking(0.5).foregroundStyle(Theme.dim)
                        Picker("Choose by", selection: $library.topPickUnit) {
                            Text("Photos").tag(TopPickUnit.images)
                            Text("Percent").tag(TopPickUnit.percent)
                        }
                        .pickerStyle(.segmented)
                        HStack {
                            Text("Quick sets").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Menu("Presets") {
                                Button("Top 4 photos") {
                                    library.topPickUnit = .images; library.topPickValue = 4
                                }
                                Button("Top 25 photos") {
                                    library.topPickUnit = .images; library.topPickValue = 25
                                }
                                Button("Top 23%") {
                                    library.topPickUnit = .percent; library.topPickValue = 23
                                }
                            }
                            .menuStyle(.borderlessButton).fixedSize()
                        }
                        HStack {
                            Text(library.topPickUnit == .images ? "Keep the highest-scoring photos" : "Keep the highest-scoring share")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            TextField("Value", value: $library.topPickValue, format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 60).multilineTextAlignment(.trailing)
                            Stepper("Adjust top-pick value", value: $library.topPickValue,
                                    in: 1...(library.topPickUnit == .percent ? 100 : 10000))
                                .labelsHidden().fixedSize()
                            Text(library.topPickUnit == .percent ? "%" : "images")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                        Text("Ranks analyzed photos in the current Library view, then keeps this number or percentage. Project, search and group scope all apply.")
                            .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                        Button {
                            if cullFilters.contains(.topPicks) { library.cullFilters.remove(.topPicks) }
                            else { library.cullFilters.insert(.topPicks) }
                            showingTopPickOptions = false
                        } label: {
                            Text(cullFilters.contains(.topPicks) ? "Hide Top Picks" : "Show Top Picks")
                        }
                        .buttonStyle(OutlinedButtonStyle(prominent: true))
                    }
                    .padding(14).frame(width: 320)
                }
                    }
                }
                .scrollIndicators(.hidden)
                }
                Spacer(minLength: 4)
                if offlineCount > 0 {
                    Text("\(editablePhotos.count) ready · \(offlineCount) offline")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
                if library.gridSelection.selected.count > 1 {
                    Text("\(library.gridSelection.selected.count) selected")
                        .font(Theme.ui(10, weight: .medium)).foregroundStyle(Theme.dim).monospacedDigit()
                        .help("Bulk selection for the visible Library grid")
                    Button("Clear Selection") { library.gridSelection.deselectAll() }
                        .buttonStyle(OutlinedButtonStyle()).help("Keep the current photo selected")
                }
                if !selectedPhotos.isEmpty {
                    Menu {
                        Button("Pick Selected", systemImage: "flag.fill") {
                            library.setFlag(.picked, for: selectedPhotos.map(\.file.url))
                        }
                        Button("Reject Selected", systemImage: "xmark.circle") {
                            library.setFlag(.rejected, for: selectedPhotos.map(\.file.url))
                        }
                        Button("Clear Flags", systemImage: "flag.slash") {
                            library.setFlag(.none, for: selectedPhotos.map(\.file.url))
                        }
                    } label: {
                        Label("Mark \(selectedPhotos.count)", systemImage: "checkmark.circle")
                    }
                    .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
                    .help("Pick, reject, or clear flags for all selected photos")
                    if let projectID = library.selectedProjectID {
                        let groups = library.categories(for: projectID)
                        if !groups.isEmpty {
                            Menu {
                                ForEach(groups) { group in
                                    Menu(group.name) {
                                        Button("Add Selected Photos to Group", systemImage: "plus.circle") {
                                            library.addToBin(selectedPhotos, binID: group.id)
                                        }
                                        Button("Remove Selected Photos from Group", systemImage: "minus.circle") {
                                            library.removeFromBin(selectedPhotos, binID: group.id)
                                        }
                                    }
                                }
                            } label: {
                                Label("Groups", systemImage: "square.grid.2x2")
                            }
                            .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
                            .help("Add or remove the selected photos from a project group")
                        }
                    }
                }
                if !editTargets.isEmpty {
                    Button {
                        editFiltered(editTargets)
                    } label: {
                        Text(selectedURLs.isEmpty ? "Edit All \(editTargets.count)" : "Edit Selected \(editTargets.count)")
                    }
                    .buttonStyle(OutlinedButtonStyle(prominent: true))
                    if !selectedReady.isEmpty {
                        Button {
                            library.setExportQueued(true, for: selectedReady.map(\.file.url))
                        } label: {
                            Text(unqueuedSelectionCount == 0 ? "Queued \(selectedReady.count)" : "Queue \(unqueuedSelectionCount)")
                        }
                        .buttonStyle(OutlinedButtonStyle())
                        .disabled(unqueuedSelectionCount == 0)
                        .help("Add the selected photos to the Export Queue")
                    }
                }
                if library.selectedProjectID != nil && !projectIsEmpty {
                    Button("Add Photos…", action: { showingProjectPhotoPicker = true })
                        .buttonStyle(OutlinedButtonStyle())
                    if let projectID = library.selectedProjectID {
                        if !selectedPhotos.isEmpty {
                            Button("Remove Selected from Project") {
                                library.remove(selectedPhotos, from: projectID)
                            }
                            .buttonStyle(OutlinedButtonStyle())
                            .help("Remove only the selected photographs from this project.")
                        }
                    }
                } else if !selectedReady.isEmpty && !library.projects.isEmpty {
                    Menu {
                        ForEach(library.projects.filter { $0.id != library.selectedProjectID }) { project in
                            Button(project.name) {
                                library.add(selectedReady, to: project.id)
                            }
                        }
                    } label: {
                        Text("Add Selected to Project")
                    }
                    .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
                    .help("Add only the selected photographs to a project.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, StudioStyle.Space.section).padding(.vertical, StudioStyle.Space.compact)
            Divider()
            if offlineCount > 0 {
                Text("\(offlineCount) photographs are offline. Check the source location and refresh.")
                    .font(Theme.text(15, italic: true)).foregroundStyle(Theme.warn).padding(10)
            }
            if !library.loaded || library.refreshing && library.photos.isEmpty {
                ProgressView("Loading Library…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let emptyState = workflowState.emptyState {
                VStack(spacing: 9) {
                    Image(systemName: emptyState.nextStep == .addPhotos || emptyState.nextStep == .createProject
                          ? "photo.badge.plus" : "square.stack.3d.up")
                        .font(.system(size: 24, weight: .regular)).foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                    Text(emptyState.title).font(Theme.text(16, weight: 600)).foregroundStyle(Theme.paper)
                    Text(emptyState.explanation).font(Theme.ui(11)).foregroundStyle(Theme.dim)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    workflowNextStepButton(for: emptyState.nextStep)
                        .padding(.top, 3)
                }
                .frame(maxWidth: 390)
                .padding(24)
                .studioWorkspaceCard()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    photoGrid(displayedPhotos, topPickURLs: topPickURLs).padding(18)
                }
                .focusable()
                .focused($libraryGridFocused)
                .onKeyPress(.leftArrow) { moveLibrarySelection(by: -1); return .handled }
                .onKeyPress(.rightArrow) { moveLibrarySelection(by: 1); return .handled }
                .onKeyPress(characters: CharacterSet(charactersIn: "pxuPXU012345")) { press in
                    guard libraryGridFocused, let photo = library.selectedPhoto, !photo.missing else { return .ignored }
                    switch press.characters.lowercased() {
                    case "p": library.setFlag(.picked)
                    case "x": library.setFlag(.rejected)
                    case "u": library.setFlag(.none)
                    case "0"..."5": if let rating = Int(press.characters) { library.setRating(rating) }
                    default: return .ignored
                    }
                    return .handled
                }
            }
        }
        .onAppear { library.pruneGridSelection(to: displayedPhotos.map(\.file.url)) }
        .onChange(of: displayedPhotos.map(\.file.url)) { _, urls in library.pruneGridSelection(to: urls) }
        .background(Theme.bg)
    }

    private func focusLibrarySearch() {
        Task { @MainActor in
            await Task.yield()
            librarySearchFocused = true
        }
    }

    @ViewBuilder private func workflowNextStepButton(for step: LibraryWorkflowNextStep) -> some View {
        switch step {
        case .createProject:
            Button("Create Project…", systemImage: "briefcase", action: {
                projectName = ""
                showingProjectSheet = true
            })
            .buttonStyle(StudioActionButtonStyle(kind: .primary))
        case .addPhotos:
            HStack(spacing: 8) {
                Button("Add Photos…", systemImage: "photo.badge.plus", action: importFolders)
                    .buttonStyle(StudioActionButtonStyle(kind: .primary))
                Button("Select Photos…", action: { showingProjectPhotoPicker = true })
                    .buttonStyle(StudioActionButtonStyle(kind: .secondary))
            }
        case .browseProjectPhotos:
            Button("View All Photos", systemImage: "square.grid.2x2") {
                _ = LibraryWorkflow.perform(.openReview(.all), in: library)
            }
            .buttonStyle(StudioActionButtonStyle(kind: .primary))
        case .clearSearch:
            Button("Clear Search", systemImage: "xmark.circle") {
                librarySearchInput = ""
                library.searchText = ""
            }
            .buttonStyle(StudioActionButtonStyle(kind: .primary))
        case .clearFilters:
            Button("Clear Filters", systemImage: "xmark.circle") {
                library.filter = .all
                library.selectedSmartCollectionID = nil
                library.cullFilters.removeAll()
            }
            .buttonStyle(StudioActionButtonStyle(kind: .primary))
        case .refreshSources:
            Button("Refresh Project Photos", systemImage: "arrow.clockwise") {
                Task { await library.refresh() }
            }
            .buttonStyle(StudioActionButtonStyle(kind: .primary))
        }
    }

    private func inspector(topPickURLs: Set<URL>) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudioStyle.Space.standard) {
                    Text("Photo Details").font(Theme.ui(17, weight: .semibold)).foregroundStyle(Theme.paper)
                if let photo = selected {
                    LibraryPreview(file: photo.file, size: 205)
                    Text(photo.file.name).font(Theme.text(16, weight: 600)).foregroundStyle(Theme.paper).textSelection(.enabled).lineLimit(3)
                    metadataRow("Source", library.folders.first { $0.id == photo.folderID }?.name ?? "Unavailable")
                    metadataRow("Format", photo.file.url.pathExtension.uppercased())
                    metadataRow("File Size", photo.file.size.map(formatBytes) ?? "—")
                    metadataRow("Modified", photo.file.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                    if photo.missing {
                        Label("Original is offline", systemImage: "externaldrive.badge.exclamationmark").foregroundStyle(.orange)
                    }
                    Divider()
                    Text("Rating").font(Theme.ui(11, weight: .semibold)).foregroundStyle(Theme.label)
                    HStack(spacing: 3) {
                        ForEach(1...5, id: \.self) { score in
                            Button { library.setRating(score) } label: {
                                Image(systemName: score <= photo.rating ? "star.fill" : "star")
                                    .foregroundStyle(score <= photo.rating ? Theme.accent : Theme.dim)
                            }.buttonStyle(WordActionStyle()).help("Rate \(score) stars")
                        }
                        Button { library.setRating(0) } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(WordActionStyle()).help("Clear rating")
                    }
                    Divider()
                    Text("CULLING").font(Theme.text(10, weight: 700)).tracking(1).foregroundStyle(Theme.dim)
                        .help("AI-assisted ranking combines visual quality estimates with measured image signals. Treat the score as a review aid.")
                    if let cull = photo.cull {
                        if cull.failed {
                            Label("Analysis unavailable", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text("\(cull.score)").font(Theme.text(22, weight: 650)).foregroundStyle(Theme.paper)
                                Text("/ 100").font(Theme.ui(11)).foregroundStyle(Theme.dim)
                                Text(cull.hardReject ? "Reject" : topPickURLs.contains(photo.file.url) ? "Top of View" : "Review")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(cull.hardReject ? Theme.warn : topPickURLs.contains(photo.file.url) ? Theme.accent : Theme.dim)
                            }
                            DisclosureGroup("Analysis details") {
                                VStack(alignment: .leading, spacing: 6) {
                                    metadataRow("Sharpness", "\(cull.sharpness) / 100")
                                    if let faceSharpness = cull.faceSharpness { metadataRow("Face Focus", "\(faceSharpness) / 100") }
                                    if let faceCaptureQuality = cull.faceCaptureQuality { metadataRow("Face Quality", "\(faceCaptureQuality) / 100") }
                                    if let exposure = cull.exposure { metadataRow("Exposure", "\(exposure) / 100") }
                                    if let faceExposure = cull.faceExposure { metadataRow("Face Exposure", "\(faceExposure) / 100") }
                                    if let clipped = cull.clippedHighlightsPercent { metadataRow("Clipped Highlights", String(format: "%.1f%%", clipped)) }
                                    if let crushed = cull.crushedShadowsPercent { metadataRow("Crushed Shadows", String(format: "%.1f%%", crushed)) }
                                    metadataRow("Aesthetic AI", cull.aesthetics.map { "\($0) / 100" } ?? "Unavailable")
                                    metadataRow("Composition", cull.composition.map { "\($0) / 100 · subject placement" } ?? "Unavailable")
                                    metadataRow("Eyes", cull.eyesOpen.map { $0 ? "Open" : "Possibly closed" } ?? "Not applicable / unknown")
                                    metadataRow("Faces", "\(cull.faceCount)")
                                    ForEach(cull.reasons, id: \.self) { reason in
                                        Label(reason, systemImage: "info.circle")
                                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(.top, 6)
                            }
                            .font(Theme.ui(11, weight: .medium)).foregroundStyle(Theme.label)
                        }
                    } else {
                        Text("Run AI Cull for focus, eyes, composition and aesthetic scores on this Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Analyze Library") {
                            Task { await library.analyzeCull() }
                        }.buttonStyle(OutlinedButtonStyle())
                    }
                    Divider()
                    HStack(spacing: 8) {
                        Button {
                            library.setFlag(photo.flag == .picked ? .none : .picked)
                        } label: {
                            Text(photo.flag == .picked ? "Picked" : "Pick")
                        }
                        .buttonStyle(OutlinedButtonStyle(prominent: photo.flag == .picked))
                        Button {
                            library.setFlag(photo.flag == .rejected ? .none : .rejected)
                        } label: {
                            Text(photo.flag == .rejected ? "Rejected" : "Reject")
                        }
                        .buttonStyle(OutlinedButtonStyle(prominent: photo.flag == .rejected))
                    }
                    Toggle("Client Pick", isOn: Binding(get: { photo.clientPicked }, set: { library.setClientPick($0) }))
                    Toggle("Queue for Export", isOn: Binding(get: { photo.selectedForExport }, set: { library.setExportQueued($0) }))
                    Button("Edit Selected Photo") { model.openLibraryPhoto(photo.file.url) }
                        .buttonStyle(PencilButtonStyle(height: 32))
                        .disabled(photo.missing)
                } else {
                    ContentUnavailableView("No Selection", systemImage: "photo")
                }
            }
            .padding(16)
        }
        .background(Theme.panel)
    }

    private var projectSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Project").font(.headline)
            TextField("Project name", text: $projectName)
                .textFieldStyle(.roundedBorder).frame(width: 320)
            Text("A project keeps its photos and groups together. Original files stay in place.")
                .font(.caption).foregroundStyle(.secondary).frame(width: 320, alignment: .leading)
            HStack {
                Spacer()
                Button("Cancel") { showingProjectSheet = false }
                Button("Create") {
                    library.createProject(named: projectName)
                    showingProjectSheet = false
                }.keyboardShortcut(.defaultAction).disabled(projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).background(Theme.panel).preferredColorScheme(.dark)
    }

    private var projectRenameSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Project").font(.headline)
            TextField("Project name", text: $projectName)
                .textFieldStyle(.roundedBorder).frame(width: 320)
            Text(projectRenameDescription)
                .font(.caption).foregroundStyle(.secondary).frame(width: 320, alignment: .leading)
            HStack {
                Spacer()
                Button("Cancel") { showingProjectRenameSheet = false }
                Button("Rename") {
                    guard let id = projectToRename else { return }
                    do {
                        try library.renameProject(id, to: projectName)
                        showingProjectRenameSheet = false
                    } catch { Self.showProjectError(error) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).background(Theme.panel).preferredColorScheme(.dark)
    }

    private var categorySheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(categoryToRename == nil ? "New Group" : "Rename Group").font(.headline)
            TextField("Group name", text: $projectName)
                .textFieldStyle(.roundedBorder).frame(width: 320)
            if let categoryError {
                Text(categoryError).font(.caption).foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true).frame(width: 320, alignment: .leading)
            } else {
                Text("Groups collect this project’s photos without moving the original files.")
                    .font(.caption).foregroundStyle(.secondary).frame(width: 320, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Cancel") { showingCategorySheet = false }
                Button(categoryToRename == nil ? "Create Group" : "Rename Group") {
                    let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    let ownerID = categoryToRename
                        .flatMap { id in library.albums.first(where: { $0.id == id })?.projectID }
                        ?? library.selectedProjectID
                    guard let ownerID else { return }
                    if let id = categoryToRename {
                        if library.categories(for: ownerID).contains(where: {
                            $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
                        }) {
                            categoryError = "A group with that name already exists in this project."
                        } else {
                            library.renameCategory(id, to: name)
                            showingCategorySheet = false
                        }
                    } else if library.categories(for: ownerID).contains(where: {
                        $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
                    }) {
                        categoryError = "A group with that name already exists in this project."
                    } else {
                        library.createAlbum(named: name)
                        showingCategorySheet = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).background(Theme.panel).preferredColorScheme(.dark)
    }

    private var projectRenameDescription: String {
        guard let id = projectToRename,
              let path = library.projects.first(where: { $0.id == id })?.projectFilePath,
              FileManager.default.fileExists(atPath: path) else {
            return "This project has not been saved as a .negproject file yet. Its new name will be used when you export it."
        }
        return "Its saved .negproject file will also be renamed in the same location."
    }

    private func sidebarSection<Content: View>(_ title: String, subtitle: String? = nil, actionTitle: String? = nil,
                                               action: (() -> Void)? = nil,
                                               @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(Theme.text(10, weight: 600)).tracking(1.25).foregroundStyle(Theme.dim)
                Spacer(minLength: 4)
                if let actionTitle, let action {
                    WordButton(title: actionTitle, size: 12, action: action)
                }
            }
            .padding(.horizontal, 7)
            if let subtitle {
                Text(subtitle)
                    .font(Theme.text(9.5))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 7)
                    .padding(.bottom, 2)
            }
            content()
        }
    }

    @ViewBuilder private func categoryActions(_ category: LibraryAlbum) -> some View {
        Button("Rename Group…", systemImage: "pencil") {
            categoryToRename = category.id
            projectName = category.name
            categoryError = nil
            showingCategorySheet = true
        }
        Button("Export Group…", systemImage: "square.and.arrow.up") { exportCategory(category) }
            .disabled(!library.photos.contains { $0.albumIDs.contains(category.id) && !$0.missing })
        Button("Reset Group Edits…", systemImage: "arrow.counterclockwise", role: .destructive) {
            categoryToReset = category.id
            showingCategoryResetConfirmation = true
        }
        Divider()
        Button("Delete Group", systemImage: "trash", role: .destructive) {
            library.deleteAlbum(category.id)
        }
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(Theme.dim).frame(width: 92, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .trailing)
                .multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(Theme.ui(11)).foregroundStyle(Theme.label)
    }

    private func photoGrid(_ photos: [LibraryPhoto], topPickURLs: Set<URL>) -> some View {
        let order = photos.map(\.file.url)
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSize), spacing: 12)], spacing: 14) {
            ForEach(photos) { photo in
                LibraryPhotoCard(photo: photo,
                                 selected: library.gridSelection.selected.contains(photo.file.url) || photo.file.url == library.selectedPhotoURL,
                                 isTopPick: topPickURLs.contains(photo.file.url) && photo.cull?.hardReject != true,
                                 size: CGFloat(thumbnailSize)) {
                    library.selectGridPhoto(photo.file.url, extending: NSEvent.modifierFlags.contains(.shift),
                                            toggling: NSEvent.modifierFlags.contains(.command), in: order)
                    libraryGridFocused = true
                } open: {
                    model.openLibraryPhoto(photo.file.url)
                } setFlag: { flag in
                    library.setFlag(flag, for: photo.file.url)
                } setRating: { rating in
                    library.setRating(rating, for: photo.file.url)
                }
            }
        }
    }

    private func moveLibrarySelection(by offset: Int) {
        let photos = displayedPhotos(from: library.visiblePhotos).filter { !$0.missing }
        guard !photos.isEmpty else { return }
        let current = photos.firstIndex { $0.file.url == library.selectedPhotoURL }
        let next = min(max((current ?? (offset > 0 ? -1 : photos.count)) + offset, 0), photos.count - 1)
        library.selectGridPhoto(photos[next].file.url, in: photos.map(\.file.url))
    }

    private func editFiltered(_ editablePhotos: [LibraryPhoto]) {
        let urls = editablePhotos.map(\.file.url)
        guard !urls.isEmpty else { return }
        model.editLibrarySelection(urls)
    }

    @MainActor private func importFolders() {
        guard let projectID = library.selectedProjectID,
              let project = library.projects.first(where: { $0.id == projectID }) else { return }
        let panel = NSOpenPanel()
        panel.title = "Add Photos to Project"
        panel.prompt = "Add Photos"
        panel.message = "Destination project: \(project.name). Original files stay where they are."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            Task { _ = await LibraryWorkflow.perform(.importFolders(panel.urls, to: projectID), in: library) }
        }
    }

    private func exportCategory(_ category: LibraryAlbum) {
        let urls = library.photos.filter { $0.albumIDs.contains(category.id) && !$0.missing }
            .map { $0.file.url }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !urls.isEmpty else { return }
        model.exportLibraryPhotos(urls)
    }

    @MainActor private func openProjectPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Negs Project"
        panel.prompt = "Open"
        panel.allowedContentTypes = [.negsProject]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do { try await library.importProject(from: url) }
                catch { Self.showProjectError(error) }
            }
        }
    }

    @MainActor private func exportProjectPanel(_ projectID: UUID) {
        guard let project = library.projects.first(where: { $0.id == projectID }) else { return }
        let panel = NSSavePanel()
        panel.title = "Export Negs Project"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.negsProject]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(project.name).negproject"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do { try library.exportProject(projectID, to: url) }
                catch { Self.showProjectError(error) }
            }
        }
    }

    @MainActor private static func showProjectError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Project Action Failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func formatBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

}

private struct WordActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.ui(12, weight: .medium))
            .foregroundStyle(configuration.isPressed ? Theme.paper : Theme.label)
            .opacity(configuration.isPressed ? 0.62 : 1)
            .contentShape(Rectangle())
    }
}

private struct NavigationRow: View {
    let title: String
    let symbol: String
    let count: Int
    let selected: Bool
    let action: () -> Void
    @FocusState private var keyboardFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 15)
                Text(title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 3)
                Text("\(count)").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(Theme.text(10.5))
            .padding(.leading, 8).padding(.trailing, 7).padding(.vertical, 6)
            .background(selected ? Theme.accent.opacity(0.13) : .clear,
                        in: RoundedRectangle(cornerRadius: 2, style: .circular))
            .overlay {
                if selected {
                    HStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 1).fill(Theme.accent).frame(width: 2)
                        Spacer(minLength: 0)
                    }
                }
            }
            .overlay {
                if keyboardFocused {
                    RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.accent.opacity(0.85), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(WordActionStyle())
        .focused($keyboardFocused)
        .foregroundStyle(selected ? Theme.accent : Theme.label)
    }
}

private struct ProjectPhotoPicker: View {
    @Bindable var library: PhotoLibrary
    let projectID: UUID
    let addSourceFolder: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var sourceFolderID: UUID?
    @State private var searchText = ""
    @State private var selectedURLs = Set<URL>()

    private var project: LibraryProject? { library.projects.first { $0.id == projectID } }
    private var candidates: [LibraryPhoto] {
        guard let project else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.photos.filter { photo in
            !photo.missing
                && (!project.folderIDs.contains(photo.folderID)
                    || project.excludedPhotoPaths.contains(photo.file.url.standardizedFileURL.path))
                && !project.photoPaths.contains(photo.file.url.standardizedFileURL.path)
                && (sourceFolderID == nil || photo.folderID == sourceFolderID)
                && (query.isEmpty || photo.file.name.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add Photos to Project").font(.title3.weight(.semibold))
                    Text("Destination: \(project?.name ?? "Project")")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("All Sources") { sourceFolderID = nil }
                    Divider()
                    ForEach(library.folders) { folder in
                        Button(folder.name) { sourceFolderID = folder.id }
                    }
                } label: {
                    Label(library.folders.first { $0.id == sourceFolderID }?.name ?? "All Sources",
                          systemImage: "externaldrive")
                }
                .menuStyle(.borderlessButton).fixedSize()
                TextField("Search filenames", text: $searchText)
                    .textFieldStyle(.roundedBorder).frame(width: 210)
            }
            .padding(18)
            Divider()
            HStack(spacing: 12) {
                Text("\(candidates.count) available")
                    .foregroundStyle(.secondary).monospacedDigit()
                Button("Select All") { selectedURLs.formUnion(candidates.map(\.file.url)) }
                    .buttonStyle(OutlinedButtonStyle()).disabled(candidates.isEmpty)
                Button("Clear") { selectedURLs.removeAll() }
                    .buttonStyle(OutlinedButtonStyle()).disabled(selectedURLs.isEmpty)
                Spacer()
                Text("\(selectedURLs.count) selected")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.callout)
            .padding(.horizontal, 18).padding(.vertical, 10)
            Divider()
            if candidates.isEmpty {
                VStack(spacing: 12) {
                    ContentUnavailableView("No Available Photos", systemImage: "photo.on.rectangle.angled",
                                           description: Text(library.folders.isEmpty
                                            ? "Import photos to this project first."
                                            : "Every matching photo is already in the project, or no photos match your search."))
                    if library.folders.isEmpty {
                        Button("Import Photos…", action: addSourceFolder)
                            .buttonStyle(OutlinedButtonStyle(prominent: true))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 14) {
                        ForEach(candidates) { photo in
                            ProjectPhotoChoice(photo: photo, selected: selectedURLs.contains(photo.file.url)) {
                                if selectedURLs.contains(photo.file.url) {
                                    selectedURLs.remove(photo.file.url)
                                } else {
                                    selectedURLs.insert(photo.file.url)
                                }
                            }
                        }
                    }
                    .padding(18)
                }
            }
            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add \(selectedURLs.count) Photos") {
                    let photos = library.photos.filter { selectedURLs.contains($0.file.url) }
                    Task {
                        _ = await LibraryWorkflow.perform(.addSelectedPhotos(photos, to: projectID), in: library)
                        dismiss()
                    }
                }
                .buttonStyle(StudioActionButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(selectedURLs.isEmpty)
            }
            .padding(16)
        }
        .frame(minWidth: 720, minHeight: 540)
        .preferredColorScheme(.dark)
    }
}

private struct ProjectPhotoChoice: View {
    let photo: LibraryPhoto
    let selected: Bool
    let action: () -> Void
    @State private var image: CGImage?

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 3).fill(Theme.film)
                    if let image {
                        Image(decorative: image, scale: 2).resizable().scaledToFit().padding(5)
                    } else {
                        Image(systemName: "photo").foregroundStyle(.tertiary)
                    }
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3).symbolRenderingMode(.palette)
                        .foregroundStyle(selected ? Theme.accent : Theme.paper.opacity(0.85), .black.opacity(0.55))
                        .padding(7)
                }
                .frame(height: 124)
            Text(photo.file.name).font(Theme.ui(12)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(Theme.label)
            }
            .padding(5)
            .background(selected ? Theme.accent.opacity(0.14) : .clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Theme.accent : Theme.line, lineWidth: selected ? 1.2 : 0.7))
        }
        .buttonStyle(.plain)
        .task(id: photo.file) {
            let result = await PhotoThumbnails.shared.image(for: photo.file)
            guard !Task.isCancelled else { return }
            image = result
        }
    }
}

private struct LibraryPhotoCard: View {
    let photo: LibraryPhoto
    let selected: Bool
    let isTopPick: Bool
    let size: CGFloat
    let select: () -> Void
    let open: () -> Void
    let setFlag: (LibraryFlag) -> Void
    let setRating: (Int) -> Void
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?
    @State private var hovered = false

    private var thumbnailRequest: LibraryThumbnailRequest {
        LibraryThumbnailRequest(photo: photo.file,
                                size: .grid(points: size, scale: displayScale))
    }

    var body: some View {
        Button(action: select) { cardContent }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { open() })
        .help("Click to select · Double-click to edit")
        .contextMenu {
            Button("Open in Editor", systemImage: "slider.horizontal.3", action: open)
            Divider()
            Button(photo.flag == .picked ? "Clear Pick" : "Pick", systemImage: "flag.fill") {
                setFlag(photo.flag == .picked ? .none : .picked)
            }
            Button(photo.flag == .rejected ? "Clear Reject" : "Reject", systemImage: "xmark.circle") {
                setFlag(photo.flag == .rejected ? .none : .rejected)
            }
            Menu("Rating") {
                ForEach(0...5, id: \.self) { score in
                    Button(score == 0 ? "Unrated" : "\(score) Stars") { setRating(score) }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(photo.file.name)
        .accessibilityValue("\(photo.rating) stars, \(photo.flag.title)")
        .task(id: thumbnailRequest) {
            guard !photo.missing else { image = nil; return }
            let thumbnailRequest = thumbnailRequest
            let request = Task.detached(priority: .utility) {
                await PhotoThumbnails.shared.image(for: thumbnailRequest.photo, size: thumbnailRequest.size)
            }
            let result = await withTaskCancellationHandler { await request.value } onCancel: { request.cancel() }
            guard !Task.isCancelled else { return }
            image = result
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            thumbnail
            Text(photo.file.name).font(.caption).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(selected ? Color.primary : Color.secondary)
            photoBadges
            if let cull = photo.cull {
                HStack(spacing: 4) {
                    Text(cull.failed ? "Cull unavailable" : "Cull \(cull.score)")
                        .font(.system(size: 9, weight: .semibold, design: .rounded)).monospacedDigit()
                    if isTopPick { Text("TOP PICK").font(.system(size: 8, weight: .bold)).tracking(0.3) }
                }
                .foregroundStyle(isTopPick ? Theme.accent : cull.hardReject ? Theme.warn : Theme.dim)
            }
        }
        .padding(3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Theme.panel : hovered ? Theme.panel.opacity(0.45) : .clear,
                    in: RoundedRectangle(cornerRadius: 3))
        .overlay {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(selected ? Theme.accent : Theme.line.opacity(hovered ? 0.9 : 0), lineWidth: 1)
        }
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .animation(.easeOut(duration: 0.12), value: selected)
        .contentShape(Rectangle())
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).fill(Theme.film)
            if let image {
                Image(decorative: image, scale: 2).resizable().scaledToFit().padding(4)
            } else if photo.missing {
                Text("Offline").font(Theme.text(15, italic: true)).foregroundStyle(Theme.warn)
            } else {
                VStack(spacing: 5) {
                    Image(systemName: "photo").font(.system(size: 17, weight: .regular))
                    Text("No Preview").font(Theme.ui(10, weight: .medium))
                }
                .foregroundStyle(Theme.dim)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.blank)
            }
        }
        // Match the grid zoom to the actual image area so portrait frames remain
        // legible at the user's chosen thumbnail size.
        .frame(maxWidth: .infinity).frame(height: size)
        .overlay(alignment: .topTrailing) {
            if photo.flag == .picked {
                Image(systemName: "flag.fill").foregroundStyle(.green).padding(7)
            } else if photo.flag == .rejected {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red).padding(7)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(selected ? Theme.accent : Theme.line, lineWidth: selected ? 1.2 : 0.6)
        }
    }

    private var photoBadges: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { score in
                    Image(systemName: score <= photo.rating ? "star.fill" : "star")
                    .font(.system(size: 9)).foregroundStyle(score <= photo.rating ? Theme.accent : Theme.dim)
            }
            if photo.clientPicked {
                Text("Client Pick").font(Theme.ui(9)).foregroundStyle(Theme.label).padding(.leading, 4)
            }
            Spacer(minLength: 0)
            if photo.selectedForExport {
                Text("Queued").font(Theme.ui(9)).foregroundStyle(Theme.dim)
            }
        }
    }
}

private struct LibraryThumbnailRequest: Equatable {
    let photo: PhotoFile
    let size: PhotoThumbnails.Size
}

private struct LibraryPreview: View {
    let file: PhotoFile
    let size: CGFloat
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).fill(Theme.film)
            if let image { Image(decorative: image, scale: 2).resizable().scaledToFit().padding(5) }
            else { Theme.blank }
        }
        .frame(maxWidth: .infinity).frame(height: size * 0.66)
        .task(id: file) {
            image = nil
            let request = Task.detached(priority: .utility) { await PhotoThumbnails.shared.image(for: file) }
            let result = await withTaskCancellationHandler { await request.value } onCancel: { request.cancel() }
            guard !Task.isCancelled else { return }
            image = result
        }
    }
}
