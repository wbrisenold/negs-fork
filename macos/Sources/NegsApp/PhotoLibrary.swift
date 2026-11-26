import AppKit
import Observation
import UniformTypeIdentifiers
import Vision

// Adapted from Whittle's BurstClusterEngine, Copyright (c) 2026 Surendran
// Balachandran, MIT licensed. Source: https://github.com/surendranb/whittle

extension UTType {
    static let negsProject = UTType(filenameExtension: "negproject", conformingTo: .json) ?? .json
    static let negsBin = UTType(filenameExtension: "negbin", conformingTo: .json) ?? .json
}

/// Reused temporal and single-linkage grouping from Whittle's MIT-licensed
/// `ClusterEngine` (https://github.com/surendranb/whittle).
private struct BurstTimedItem: Equatable {
    let id: String
    let date: Date?
}

private enum BurstClusterEngine {
    static func temporalGroups(_ items: [BurstTimedItem], maxGap: TimeInterval) -> [[BurstTimedItem]] {
        let dated = items.filter { $0.date != nil }.sorted { $0.date! < $1.date! }
        guard let first = dated.first else { return [] }
        var groups: [[BurstTimedItem]] = []
        var current = [first]
        for item in dated.dropFirst() {
            if item.date!.timeIntervalSince(current.last!.date!) <= maxGap {
                current.append(item)
            } else {
                groups.append(current)
                current = [item]
            }
        }
        groups.append(current)
        return groups
    }

    static func visualSubclusters(
        _ ids: [String], threshold: Double,
        distance: (String, String) -> Double?
    ) -> [[String]] {
        var clusters: [[String]] = []
        for id in ids {
            if let index = clusters.indices.first(where: { index in
                clusters[index].contains { member in
                    guard let measured = distance(id, member) else { return false }
                    return measured <= threshold
                }
            }) {
                clusters[index].append(id)
            } else {
                clusters.append([id])
            }
        }
        return clusters
    }
}

enum LibraryFlag: String, CaseIterable, Codable, Identifiable, Sendable {
    case none, picked, rejected
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "Unflagged"
        case .picked: "Picked"
        case .rejected: "Rejected"
        }
    }
}

enum LibraryFilter: String, CaseIterable, Codable, Identifiable, Sendable {
    case all, picked, clientPicks, rejected, unrated, fiveStar, exportQueued, missing
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All Photos"
        case .picked: "Picked"
        case .clientPicks: "Client Picks"
        case .rejected: "Rejected"
        case .unrated: "Unrated"
        case .fiveStar: "Five Stars"
        case .exportQueued: "Export Queue"
        case .missing: "Missing Files"
        }
    }
    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .picked: "flag.fill"
        case .clientPicks: "heart.fill"
        case .rejected: "xmark.circle"
        case .unrated: "star"
        case .fiveStar: "star.fill"
        case .exportQueued: "square.and.arrow.up"
        case .missing: "externaldrive.badge.exclamationmark"
        }
    }
}

enum LibrarySort: String, CaseIterable, Equatable, Identifiable, Sendable {
    case name, newest, oldest, cullScore, sharpness, aesthetics
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: "Name"
        case .newest: "Modified · Newest"
        case .oldest: "Modified · Oldest"
        case .cullScore: "Cull Score · Highest"
        case .sharpness: "Sharpness · Highest"
        case .aesthetics: "Aesthetics · Highest"
        }
    }
}

enum CullFilterChip: CaseIterable, Hashable, Sendable {
    case eyesOpen, sharp, exposure, aesthetics, composition, aiScore, topPicks, burstLeads, rejects
    var title: String {
        switch self {
        case .eyesOpen: "Eyes Open"
        case .sharp: "Sharpness 70+"
        case .exposure: "Exposure 70+"
        case .aesthetics: "Aesthetics 70+"
        case .composition: "Composition 70+"
        case .aiScore: "Cull Score 70+"
        case .topPicks: "Top Picks"
        case .burstLeads: "Burst Leads"
        case .rejects: "Rejects"
        }
    }
    var symbol: String {
        switch self {
        case .eyesOpen: "eye"
        case .sharp: "viewfinder"
        case .exposure: "sun.max"
        case .aesthetics: "sparkles"
        case .composition: "viewfinder.rectangular"
        case .aiScore: "sparkles"
        case .topPicks: "rosette"
        case .burstLeads: "square.stack.3d.up"
        case .rejects: "xmark.circle"
        }
    }
}

enum CullDecision: String, Codable, Sendable {
    case topPick, review, reject
    var title: String {
        switch self {
        case .topPick: "Top Pick"
        case .review: "Review"
        case .reject: "Reject"
        }
    }
}

enum TopPickUnit: String, CaseIterable, Identifiable {
    case images, percent
    var id: String { rawValue }
    var title: String { self == .images ? "images per scene" : "% per scene" }
}

/// Local Vision results plus transparent, deterministic technical signals.
/// A missing aesthetic score means this macOS version did not provide Apple's
/// on-device aesthetics request; it is never replaced with a guessed value.
struct CullAnalysis: Codable, Hashable, Sendable {
    var version: Int = 4
    var score: Int
    var sharpness: Int
    var faceSharpness: Int? = nil
    var faceCaptureQuality: Int? = nil
    var faceExposure: Int? = nil
    var exposure: Int? = nil
    var clippedHighlightsPercent: Double? = nil
    var crushedShadowsPercent: Double? = nil
    var sceneFingerprint: Data? = nil
    var captureDate: Date? = nil
    var aesthetics: Int?
    var composition: Int?
    var eyesOpen: Bool?
    var faceCount: Int
    var utilityImage: Bool
    var failed = false
    var reasons: [String]

    var hardReject: Bool {
        !failed && (eyesOpen == false || sharpness < 18 || (faceSharpness ?? 100) < 28
                    || (exposure ?? 100) < 18 || (faceExposure ?? 100) < 16 || score < 28 || utilityImage)
    }
}

struct LibraryPhoto: Codable, Hashable, Identifiable, Sendable {
    var file: PhotoFile
    var folderID: UUID
    var rating = 0
    var flag: LibraryFlag = .none
    var clientPicked = false
    var selectedForExport = false
    var missing = false
    var albumIDs = Set<UUID>()
    var cull: CullAnalysis?
    var id: URL { file.url }

    func matches(_ filter: LibraryFilter) -> Bool {
        switch filter {
        case .all: true
        case .picked: flag == .picked
        case .clientPicks: clientPicked
        case .rejected: flag == .rejected
        case .unrated: rating == 0
        case .fiveStar: rating == 5
        case .exportQueued: selectedForExport
        case .missing: missing
        }
    }
}

struct LibraryFolder: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var path: String
    var bookmark: Data?
    var name: String { URL(fileURLWithPath: path).lastPathComponent }

    func resolvedURL() -> URL {
        guard let bookmark else { return URL(fileURLWithPath: path) }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return URL(fileURLWithPath: path)
        }
        return url
    }
}

struct LibraryAlbum: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var projectID: UUID? = nil
    /// Source folder used only to place newly discovered photos in the
    /// category created when that folder was added to a project.
    var sourceFolderID: UUID? = nil
}

struct SmartLibraryCollection: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var filter: LibraryFilter
}

struct LibraryProject: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var folderIDs = Set<UUID>()
    /// Last `.negproject` file saved from this project on this Mac.
    var projectFilePath: String? = nil
    /// Kept only to read older catalogs and `.negproject` files.
    var photoPaths = Set<String>()
    /// Removed from this project while source folders remain attached.
    var excludedPhotoPaths = Set<String>()

    private enum CodingKeys: String, CodingKey { case id, name, folderIDs, projectFilePath, photoPaths, excludedPhotoPaths }

    init(id: UUID, name: String, folderIDs: Set<UUID> = [], projectFilePath: String? = nil, photoPaths: Set<String> = [], excludedPhotoPaths: Set<String> = []) {
        self.id = id; self.name = name; self.folderIDs = folderIDs; self.projectFilePath = projectFilePath
        self.photoPaths = photoPaths; self.excludedPhotoPaths = excludedPhotoPaths
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        folderIDs = try values.decodeIfPresent(Set<UUID>.self, forKey: .folderIDs) ?? []
        projectFilePath = try values.decodeIfPresent(String.self, forKey: .projectFilePath)
        photoPaths = try values.decodeIfPresent(Set<String>.self, forKey: .photoPaths) ?? []
        excludedPhotoPaths = try values.decodeIfPresent(Set<String>.self, forKey: .excludedPhotoPaths) ?? []
    }
}

private struct PhotoLibraryDocument: Codable, Sendable {
    var schema = 2
    var folders: [LibraryFolder] = []
    var photos: [LibraryPhoto] = []
    var albums: [LibraryAlbum] = []
    var smartCollections: [SmartLibraryCollection] = []
    var projects: [LibraryProject] = []
    var selectedProjectID: UUID?

    private enum CodingKeys: String, CodingKey {
        case schema, folders, photos, albums, smartCollections, projects, selectedProjectID
    }

    init() {}

    init(schema: Int = 2, folders: [LibraryFolder], photos: [LibraryPhoto], albums: [LibraryAlbum],
         smartCollections: [SmartLibraryCollection], projects: [LibraryProject] = [], selectedProjectID: UUID? = nil) {
        self.schema = schema
        self.folders = folders
        self.photos = photos
        self.albums = albums
        self.smartCollections = smartCollections
        self.projects = projects
        self.selectedProjectID = selectedProjectID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        folders = try container.decodeIfPresent([LibraryFolder].self, forKey: .folders) ?? []
        photos = try container.decodeIfPresent([LibraryPhoto].self, forKey: .photos) ?? []
        albums = try container.decodeIfPresent([LibraryAlbum].self, forKey: .albums) ?? []
        smartCollections = try container.decodeIfPresent([SmartLibraryCollection].self, forKey: .smartCollections) ?? []
        projects = try container.decodeIfPresent([LibraryProject].self, forKey: .projects) ?? []
        selectedProjectID = try container.decodeIfPresent(UUID.self, forKey: .selectedProjectID)
    }
}

struct LibrarySidebarCounts {
    var filters: [LibraryFilter: Int] = [:]
    var folders: [UUID: Int] = [:]
    var projectFolders: [UUID: [UUID: Int]] = [:]
    var albums: [UUID: Int] = [:]
    var projects: [UUID: Int] = [:]
    var smartCollections: [String: Int] = [:]
}

private struct LibraryFilterCountScope: Equatable {
    let projectID: UUID?
    let folderID: UUID?
    let albumID: UUID?
    let searchText: String
}

private struct LibraryPhotoScope: Equatable {
    let projectID: UUID?
    let folderID: UUID?
    let albumID: UUID?
    let searchText: String
    let sort: LibrarySort
}

/// Serializes catalog snapshots off the main thread. Revisions prevent a
/// delayed save from replacing a newer library state.
private actor PhotoLibraryDiskWriter {
    static let shared = PhotoLibraryDiskWriter()
    private var revisions: [UUID: Int] = [:]

    func save(_ document: PhotoLibraryDocument, owner: UUID, revision: Int, to url: URL) throws {
        guard revision > revisions[owner, default: 0] else { return }
        revisions[owner] = revision
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: url, options: .atomic)
    }
}

private enum PhotoLibraryLoadError: Error, Sendable {
    case message(String)
}

private struct LibraryProjectDocument: Codable, Sendable {
    var formatVersion = 1
    var project: LibraryProject
    var folders: [LibraryFolder]
    var photos: [LibraryPhoto]
    var albums: [LibraryAlbum] = []

    private enum CodingKeys: String, CodingKey { case formatVersion, project, folders, photos, albums }

    init(project: LibraryProject, folders: [LibraryFolder], photos: [LibraryPhoto], albums: [LibraryAlbum] = []) {
        self.project = project; self.folders = folders; self.photos = photos; self.albums = albums
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try values.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        project = try values.decode(LibraryProject.self, forKey: .project)
        folders = try values.decode([LibraryFolder].self, forKey: .folders)
        photos = try values.decode([LibraryPhoto].self, forKey: .photos)
        albums = try values.decodeIfPresent([LibraryAlbum].self, forKey: .albums) ?? []
    }
}

/// Persistent photo references and Lightroom-style culling metadata. Originals
/// stay in their folders; the catalog stores bookmarks and sidecar metadata.
@MainActor @Observable final class PhotoLibrary {
    private(set) var folders: [LibraryFolder] = [] {
        didSet { scopePhotosCache = nil; scopedFilterCountsCache = nil }
    }
    private(set) var photos: [LibraryPhoto] = [] {
        didSet {
            sceneGroupsCache = nil; topPicksCache = nil; burstLeadsCache = nil
            sidebarCountsCache = nil; scopedFilterCountsCache = nil
            scopePhotosCache = nil; photoByURLCache = nil
        }
    }
    private(set) var albums: [LibraryAlbum] = []
    private(set) var projects: [LibraryProject] = [] {
        didSet { sidebarCountsCache = nil; scopedFilterCountsCache = nil; scopePhotosCache = nil }
    }
    private(set) var smartCollections: [SmartLibraryCollection] = [] {
        didSet { sidebarCountsCache = nil }
    }
    var filter: LibraryFilter = .all
    /// Shared culling filters stay active as the user moves between Library and Edit.
    var cullFilters = Set<CullFilterChip>()
    var sort: LibrarySort = .name
    var searchText = ""
    var selectedFolderID: UUID?
    var selectedProjectID: UUID?
    var selectedAlbumID: UUID?
    var selectedSmartCollectionID: UUID?
    var selectedPhotoURL: URL?
    /// Transient grid selection; the catalog's selected photo remains the inspector focus.
    var gridSelection = LibrarySelection()
    var topPickUnit: TopPickUnit = TopPickUnit(rawValue: UserDefaults.standard.string(forKey: "negs.library.topPickUnit") ?? "images") ?? .images {
        didSet {
            let maximum = topPickUnit == .percent ? 100 : 10000
            if topPickValue > maximum { topPickValue = maximum }
            UserDefaults.standard.set(topPickUnit.rawValue, forKey: "negs.library.topPickUnit")
        }
    }
    var topPickValue: Int = max(1, UserDefaults.standard.object(forKey: "negs.library.topPickValue") as? Int ?? 4) {
        didSet {
            let bounded = min(max(topPickValue, 1), topPickUnit == .percent ? 100 : 10000)
            if bounded != topPickValue { topPickValue = bounded; return }
            UserDefaults.standard.set(topPickValue, forKey: "negs.library.topPickValue")
        }
    }
    private(set) var loaded = false
    private(set) var refreshing = false
    private(set) var refreshProgress = 0
    private(set) var refreshTotal = 0
    private(set) var analyzingCull = false
    private(set) var cullProgress = 0
    private(set) var cullTotal = 0
    private(set) var error: String?
    var importStatus: LibraryImportStatus?
    var retryableImport: LibraryImportRequest?
    @ObservationIgnored private var scopedFolders: [UUID: URL] = [:]
    @ObservationIgnored private var loadStarted = false
    @ObservationIgnored private var sceneGroupsCache: (scope: Set<URL>, groups: [[LibraryPhoto]])?
    @ObservationIgnored private var topPicksCache: (unit: TopPickUnit, value: Int, scope: Set<URL>, urls: Set<URL>)?
    @ObservationIgnored private var burstLeadsCache: (scope: Set<URL>, urls: Set<URL>)?
    @ObservationIgnored private var sidebarCountsCache: LibrarySidebarCounts?
    @ObservationIgnored private var scopedFilterCountsCache: (scope: LibraryFilterCountScope, counts: [LibraryFilter: Int])?
    @ObservationIgnored private var scopePhotosCache: (scope: LibraryPhotoScope, photos: [LibraryPhoto])?
    @ObservationIgnored private var photoByURLCache: [URL: LibraryPhoto]?
    @ObservationIgnored private let persistenceID = UUID()
    @ObservationIgnored private var persistenceRevision = 0
    @ObservationIgnored private var persistenceTask: Task<Void, Never>?
    @ObservationIgnored private var activeRefresh: Task<[String], Never>?
    @ObservationIgnored private var activeRefreshProjectID: UUID?
    @ObservationIgnored private var activeRefreshID: UUID?
    @ObservationIgnored private let storeURL: URL

    private static let sceneDistanceThreshold = 0.45

    var sidebarCounts: LibrarySidebarCounts {
        // Keep Observation dependencies even when the ignored cache answers.
        _ = photos; _ = smartCollections; _ = projects
        if let sidebarCountsCache { return sidebarCountsCache }
        let smartFilters = Set(smartCollections.map { $0.filter })
        let projectByFolder = Dictionary(projects.flatMap { project in
            project.folderIDs.map { ($0, project.id) }
        }, uniquingKeysWith: { first, _ in first })
        let projectsByID = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let legacyProjectsByPath = Dictionary(grouping: projects.flatMap { project in
            project.photoPaths.map { (URL(fileURLWithPath: $0).standardizedFileURL.path, project.id) }
        }, by: { $0.0 })
        var counts = LibrarySidebarCounts()
        for photo in photos {
            counts.folders[photo.folderID, default: 0] += 1
            for albumID in photo.albumIDs { counts.albums[albumID, default: 0] += 1 }
            let path = photo.file.url.standardizedFileURL.path
            let ownerID = projectByFolder[photo.folderID]
            if let ownerID, let owner = projectsByID[ownerID], !owner.excludedPhotoPaths.contains(path) {
                counts.projects[ownerID, default: 0] += 1
                counts.projectFolders[ownerID, default: [:]][photo.folderID, default: 0] += 1
            }
            for (_, projectID) in legacyProjectsByPath[path] ?? [] where projectID != ownerID {
                if let project = projectsByID[projectID], !project.excludedPhotoPaths.contains(path) {
                    counts.projects[projectID, default: 0] += 1
                }
            }
            for filter in LibraryFilter.allCases where filter != .missing {
                if photo.matches(filter) && !photo.missing { counts.filters[filter, default: 0] += 1 }
            }
            for filter in smartFilters where photo.matches(filter) && !photo.missing {
                counts.smartCollections[filter.rawValue, default: 0] += 1
            }
        }
        sidebarCountsCache = counts
        return counts
    }

    init(storeURL: URL? = nil) {
        self.storeURL = storeURL ?? AppDataLocations.supportDirectory.appendingPathComponent("photo-library.json")
        let maximum = topPickUnit == .percent ? 100 : 10000
        topPickValue = min(max(topPickValue, 1), maximum)
    }

    /// The active folder/project/album/search scope before its Library category filter.
    var scopePhotos: [LibraryPhoto] {
        _ = photos; _ = folders
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = LibraryPhotoScope(projectID: selectedProjectID, folderID: selectedFolderID, albumID: selectedAlbumID,
                                      searchText: query, sort: sort)
        if let cached = scopePhotosCache, cached.scope == scope { return cached.photos }
        let folderNames = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.name) })
        let project = projects.first { $0.id == selectedProjectID }
        let result = photos.filter { photo in
            let path = photo.file.url.standardizedFileURL.path
            let projectMatches = project.map { ($0.folderIDs.contains(photo.folderID) || $0.photoPaths.contains(path))
                && !$0.excludedPhotoPaths.contains(path) } ?? false
            let albumMatches = selectedAlbumID.map { photo.albumIDs.contains($0) } ?? true
            let folderMatches = selectedFolderID.map { $0 == photo.folderID } ?? true
            let textMatches = query.isEmpty || photo.file.name.localizedCaseInsensitiveContains(query)
                || (folderNames[photo.folderID]?.localizedCaseInsensitiveContains(query) ?? false)
            return projectMatches && albumMatches && folderMatches && textMatches
        }
        let sorted: [LibraryPhoto]
        switch sort {
        case .name:
            sorted = result.sorted { $0.file.name.localizedStandardCompare($1.file.name) == .orderedAscending }
        case .newest:
            sorted = result.sorted { ($0.file.modified ?? .distantPast) > ($1.file.modified ?? .distantPast) }
        case .oldest:
            sorted = result.sorted { ($0.file.modified ?? .distantFuture) < ($1.file.modified ?? .distantFuture) }
        case .cullScore:
            sorted = result.sorted { ($0.cull?.score ?? -1) > ($1.cull?.score ?? -1) }
        case .sharpness:
            sorted = result.sorted { ($0.cull?.faceSharpness ?? $0.cull?.sharpness ?? -1) > ($1.cull?.faceSharpness ?? $1.cull?.sharpness ?? -1) }
        case .aesthetics:
            sorted = result.sorted { ($0.cull?.aesthetics ?? -1) > ($1.cull?.aesthetics ?? -1) }
        }
        scopePhotosCache = (scope, sorted)
        return sorted
    }

    var visiblePhotos: [LibraryPhoto] {
        let category = smartCollections.first { $0.id == selectedSmartCollectionID }?.filter ?? filter
        let scoped = selectedProjectID != nil
        guard category != .missing || scoped else { return [] }
        return scopePhotos.filter { $0.matches(category) && (scoped || !$0.missing) }
    }

    /// The same Library and AI filters, applied to a caller's current scope.
    func filteredPhotos(from visible: [LibraryPhoto]? = nil, topPicks suppliedTopPicks: Set<URL>? = nil) -> [LibraryPhoto] {
        let candidates = visible ?? visiblePhotos
        // The Library screen already computes this set for its Top Picks
        // label and inspector. Reuse it instead of rebuilding the scope and
        // looking up the cached ranking a second time during the same update.
        let top = cullFilters.contains(.topPicks)
            ? (suppliedTopPicks ?? Set(topPickURLs(in: candidates))): []
        let burstLeads = cullFilters.contains(.burstLeads) ? burstLeadURLs(in: candidates) : []
        return candidates.filter { photo in
            cullFilters.allSatisfy { filter in
                switch filter {
                case .eyesOpen: photo.cull?.eyesOpen == true
                case .sharp: (photo.cull?.faceSharpness ?? photo.cull?.sharpness ?? -1) >= 70
                case .exposure: (photo.cull?.exposure ?? -1) >= 70
                case .aesthetics: (photo.cull?.aesthetics ?? -1) >= 70
                case .composition: (photo.cull?.composition ?? -1) >= 70
                case .aiScore: (photo.cull?.score ?? -1) >= 70
                case .topPicks: top.contains(photo.file.url)
                case .burstLeads: burstLeads.contains(photo.file.url)
                case .rejects: photo.cull?.hardReject == true
                }
            }
        }
    }

    /// Optional burst review powered by Whittle's MIT-licensed clustering
    /// implementation. Undated or unanalysed images are always preserved.
    private func burstLeadURLs(in candidates: [LibraryPhoto]) -> Set<URL> {
        let scope = Set(candidates.map(\.file.url))
        if let burstLeadsCache, burstLeadsCache.scope == scope { return burstLeadsCache.urls }
        let dated = candidates.compactMap { photo -> (LibraryPhoto, Date)? in
            guard let date = photo.cull?.captureDate,
                  photo.cull?.failed == false,
                  photo.cull?.sceneFingerprint != nil else { return nil }
            return (photo, date)
        }
        let groups = BurstClusterEngine.temporalGroups(
            dated.map { BurstTimedItem(id: $0.0.file.url.path, date: $0.1) }, maxGap: 10
        )
        let byPath = Dictionary(uniqueKeysWithValues: dated.map { ($0.0.file.url.path, $0.0) })
        var retained = Set(candidates.filter {
            $0.cull?.failed != false || $0.cull?.captureDate == nil || $0.cull?.sceneFingerprint == nil
        }.map(\.file.url))

        for group in groups {
            let paths = group.map(\.id)
            var fingerprints: [String: VNFeaturePrintObservation] = [:]
            for path in paths {
                guard let data = byPath[path]?.cull?.sceneFingerprint,
                      let print = try? NSKeyedUnarchiver.unarchivedObject(
                        ofClass: VNFeaturePrintObservation.self, from: data) else { continue }
                fingerprints[path] = print
            }
            let clusters = BurstClusterEngine.visualSubclusters(paths, threshold: 0.6) { first, second in
                guard let firstPrint = fingerprints[first], let secondPrint = fingerprints[second] else { return nil }
                return Self.sceneDistance(firstPrint, secondPrint)
            }
            for cluster in clusters {
                let ranked = cluster.compactMap { byPath[$0] }.sorted {
                    let a = $0.cull?.score ?? -1, b = $1.cull?.score ?? -1
                    return a == b ? $0.file.url.path < $1.file.url.path : a > b
                }
                if cluster.count > 1, let lead = ranked.first { retained.insert(lead.file.url) }
                else { ranked.forEach { retained.insert($0.file.url) } }
            }
        }
        burstLeadsCache = (scope, retained)
        return retained
    }

    var detectedScenes: [[LibraryPhoto]] {
        detectedScenes(in: visiblePhotos)
    }

    func detectedScenes(in visiblePhotos: [LibraryPhoto]) -> [[LibraryPhoto]] {
        let scope = Set(visiblePhotos.map(\.file.url))
        if let sceneGroupsCache, sceneGroupsCache.scope == scope { return sceneGroupsCache.groups }
        // Keep every successfully analyzed frame in the ranking. Hard rejects
        // still rank low, but a configured Top N must mean N frames when a
        // scene contains N analyzed photos. Rank only the current Library view,
        // so photos in another folder cannot consume this folder's top slots.
        let eligible = visiblePhotos.filter { $0.cull != nil && !($0.cull?.failed ?? true) }
            .sorted { $0.file.url.path < $1.file.url.path }
        var scenes: [[LibraryPhoto]] = []
        var exemplars: [VNFeaturePrintObservation] = []
        var legacyScene: [LibraryPhoto] = []
        for photo in eligible {
            guard let data = photo.cull?.sceneFingerprint,
                  let fingerprint = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data) else {
                legacyScene.append(photo)
                continue
            }
            let match = exemplars.indices.first { Self.sceneDistance(fingerprint, exemplars[$0]) <= Self.sceneDistanceThreshold }
            guard let match else {
                scenes.append([photo])
                exemplars.append(fingerprint)
                continue
            }
            scenes[match].append(photo)
        }
        if !legacyScene.isEmpty { scenes.append(legacyScene) }
        sceneGroupsCache = (scope, scenes)
        return scenes
    }

    /// Select the best configured number or share per scene, or across the whole view.
    var topPickURLs: Set<URL> {
        topPickURLs(in: visiblePhotos)
    }

    func topPickURLs(in visiblePhotos: [LibraryPhoto]) -> Set<URL> {
        let scope = Set(visiblePhotos.map(\.file.url))
        if let topPicksCache, topPicksCache.unit == topPickUnit,
           topPicksCache.value == topPickValue, topPicksCache.scope == scope {
            return topPicksCache.urls
        }
        let eligible = visiblePhotos.filter { $0.cull != nil && !($0.cull?.failed ?? true) }
        let ranked = eligible.sorted {
            let a = $0.cull?.score ?? -1, b = $1.cull?.score ?? -1
            return a == b ? $0.file.url.path < $1.file.url.path : a > b
        }
        let limit = topPickUnit == .images ? topPickValue : Int(ceil(Double(ranked.count) * Double(topPickValue) / 100))
        let picks = Set(ranked.prefix(limit).map(\.file.url))
        topPicksCache = (topPickUnit, topPickValue, scope, picks)
        return picks
    }

    private static func sceneDistance(_ first: VNFeaturePrintObservation, _ second: VNFeaturePrintObservation) -> Double {
        var distance: Float = .infinity
        guard (try? first.computeDistance(&distance, to: second)) != nil else { return .infinity }
        return Double(distance)
    }

    var selectedPhoto: LibraryPhoto? {
        _ = photos
        guard let selectedPhotoURL else { return nil }
        if photoByURLCache == nil {
            photoByURLCache = Dictionary(photos.map { ($0.file.url, $0) }, uniquingKeysWith: { _, latest in latest })
        }
        return photoByURLCache?[selectedPhotoURL]
    }

    func selectGridPhoto(_ url: URL, extending: Bool = false, toggling: Bool = false, in order: [URL]) {
        if toggling {
            gridSelection.toggle(url, in: order)
            selectedPhotoURL = gridSelection.current
        } else {
            if extending { gridSelection.extend(to: url, in: order) }
            else { gridSelection.select(url) }
            selectedPhotoURL = url
        }
    }

    func clearPhotoSelection() {
        gridSelection = LibrarySelection()
        selectedPhotoURL = nil
    }

    func pruneGridSelection(to order: [URL]) {
        let visible = Set(order)
        if let current = gridSelection.current, !visible.contains(current) {
            gridSelection = LibrarySelection()
            if let selectedPhotoURL, visible.contains(selectedPhotoURL) {
                gridSelection.select(selectedPhotoURL)
            } else {
                selectedPhotoURL = nil
            }
        } else if gridSelection.current == nil, let selectedPhotoURL, visible.contains(selectedPhotoURL) {
            gridSelection.select(selectedPhotoURL)
        } else {
            gridSelection.prune(to: visible)
            if let selectedURL = selectedPhotoURL, !visible.contains(selectedURL) {
                selectedPhotoURL = gridSelection.current
            }
        }
    }

    func count(for filter: LibraryFilter) -> Int {
        _ = photos; _ = folders
        let scope = LibraryFilterCountScope(projectID: selectedProjectID, folderID: selectedFolderID, albumID: selectedAlbumID,
                                            searchText: searchText.trimmingCharacters(in: .whitespacesAndNewlines))
        let hasScopedView = scope.projectID != nil || scope.folderID != nil || scope.albumID != nil || !scope.searchText.isEmpty
        guard hasScopedView else {
            return filter == .missing ? 0 : sidebarCounts.filters[filter, default: 0]
        }
        if scopedFilterCountsCache?.scope != scope {
            var counts: [LibraryFilter: Int] = [:]
            let locationScoped = scope.projectID != nil || scope.folderID != nil || scope.albumID != nil
            for photo in scopePhotos {
                if photo.missing && !locationScoped { continue }
                if photo.missing { counts[.missing, default: 0] += 1 }
                for category in LibraryFilter.allCases where category != .missing && photo.matches(category) {
                    counts[category, default: 0] += 1
                }
            }
            scopedFilterCountsCache = (scope, counts)
        }
        return scopedFilterCountsCache?.counts[filter, default: 0] ?? 0
    }

    func selectedCount(in visible: [LibraryPhoto]) -> Int {
        let visibleURLs = Set(visible.map { $0.file.url })
        let selectedURLs = gridSelection.selected.union(selectedPhotoURL.map { [$0] } ?? [])
        return selectedURLs.intersection(visibleURLs).count
    }

    func count(for project: LibraryProject) -> Int {
        sidebarCounts.projects[project.id, default: 0]
    }

    func count(for folder: LibraryFolder, in project: LibraryProject? = nil) -> Int {
        let owner = project ?? projects.first { $0.id == selectedProjectID }
        guard let owner, owner.folderIDs.contains(folder.id) else { return 0 }
        return sidebarCounts.projectFolders[owner.id, default: [:]][folder.id, default: 0]
    }

    func count(for category: LibraryAlbum) -> Int {
        sidebarCounts.albums[category.id, default: 0]
    }
    func load() async {
        guard !loadStarted else { return }
        loadStarted = true
        let url = storeURL
        let result = await Task.detached(priority: .utility) { () -> Result<PhotoLibraryDocument, PhotoLibraryLoadError> in
            guard FileManager.default.fileExists(atPath: url.path) else { return .success(PhotoLibraryDocument()) }
            do {
                let data = try Data(contentsOf: url)
                let document = try JSONDecoder().decode(PhotoLibraryDocument.self, from: data)
        guard (1...2).contains(document.schema) else { return .failure(.message("This Library catalog version isn’t supported.")) }
                return .success(document)
            } catch {
                return .failure(.message("Could not read the photo Library: \(error.localizedDescription)"))
            }
        }.value
        guard case .success(let document) = result else {
            if case .failure(.message(let message)) = result { error = message }
            loaded = true
            return
        }
        folders = document.folders
        photos = document.photos.map { photo in
            var photo = photo
            photo.rating = min(5, max(0, photo.rating))
            return photo
        }
        albums = document.albums
        smartCollections = document.smartCollections
        projects = document.projects.map { old in
            var project = old
            let legacyPaths = old.photoPaths
            project.folderIDs.formUnion(photos.filter { legacyPaths.contains($0.file.url.standardizedFileURL.path) }.map(\.folderID))
            project.photoPaths = []
            return project
        }
        if projects.isEmpty, !folders.isEmpty {
            projects = [LibraryProject(id: UUID(), name: "Library", folderIDs: Set(folders.map(\.id)))]
        }
        migrateProjectCategories()
        selectedProjectID = document.selectedProjectID.flatMap { id in projects.contains(where: { $0.id == id }) ? id : nil }
            ?? projects.first?.id
        beginFolderAccess()
        await refresh()
        loaded = true
        if !document.projects.isEmpty || (!folders.isEmpty && document.projects.isEmpty) { persist() }
    }

    struct FolderImportResult {
        let importedCount: Int
        let scannedCount: Int
        let failures: [String]
    }

    func importFolders(_ urls: [URL]) async {
        guard let selectedProjectID else { return }
        _ = await importFolders(urls, to: selectedProjectID)
    }

    func importFolders(_ urls: [URL], to projectID: UUID) async -> FolderImportResult {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else {
            return FolderImportResult(importedCount: 0, scannedCount: 0, failures: ["The destination project no longer exists."])
        }
        var selectedFolderIDs = Set<UUID>()
        var failures: [String] = []
        let initialPhotoURLs = Set(projectPhotos(projects[projectIndex]).map { $0.file.url.standardizedFileURL })
        var foldersByPath = Dictionary(folders.map { (URL(fileURLWithPath: $0.path).standardizedFileURL.path, $0.id) },
                                       uniquingKeysWith: { first, _ in first })
        for url in urls {
            let standardized = url.standardizedFileURL
            if let existingID = foldersByPath[standardized.path] {
                if let otherProject = projects.first(where: { $0.id != projectID && $0.folderIDs.contains(existingID) }) {
                    let message = "“\(standardized.lastPathComponent)” already belongs to project “\(otherProject.name)”. Folders belong to one project at a time."
                    if projectID == selectedProjectID { error = message }
                    failures.append(message)
                    continue
                }
                selectedFolderIDs.insert(existingID)
                continue
            }
            let bookmark = try? url.bookmarkData(options: [.withSecurityScope],
                                                includingResourceValuesForKeys: nil, relativeTo: nil)
            let folder = LibraryFolder(id: UUID(), path: url.path, bookmark: bookmark)
            folders.append(folder)
            foldersByPath[standardized.path] = folder.id
            selectedFolderIDs.insert(folder.id)
            if url.startAccessingSecurityScopedResource() { scopedFolders[folder.id] = url }
        }
        guard !selectedFolderIDs.isEmpty else {
            return FolderImportResult(importedCount: 0, scannedCount: 0,
                                      failures: failures.isEmpty ? ["Choose at least one source folder."] : failures)
        }
        projects[projectIndex].folderIDs.formUnion(selectedFolderIDs)
        for folderID in selectedFolderIDs {
            ensureSourceCategory(folderID, projectID: projectID)
        }
        persist()
        failures.append(contentsOf: await refresh(projectID: projectID, afterCurrent: true))
        guard let updatedProjectIndex = projects.firstIndex(where: { $0.id == projectID }) else {
            return FolderImportResult(importedCount: 0, scannedCount: selectedFolderIDs.count,
                                      failures: ["The destination project was removed during import."])
        }
        let importedCount = projectPhotos(projects[updatedProjectIndex])
            .filter { !initialPhotoURLs.contains($0.file.url.standardizedFileURL) }.count
        return FolderImportResult(importedCount: importedCount, scannedCount: selectedFolderIDs.count, failures: failures)
    }

    /// Bring the folder already open in Edit into the selected Library
    /// project. Edit stores sidecars beside source files; Library stores
    /// folder membership separately, so this keeps both views on the same set.
    func syncEditedPhoto(_ photoURL: URL) async {
        await load()
        let folderURL = photoURL.deletingLastPathComponent().standardizedFileURL
        let photoPath = photoURL.standardizedFileURL.path
        if let folder = folders.first(where: {
            URL(fileURLWithPath: $0.path).standardizedFileURL == folderURL
        }), let owner = projects.first(where: { $0.folderIDs.contains(folder.id) }) {
            selectedProjectID = owner.id
            selectedFolderID = nil
            selectedAlbumID = nil
            selectedSmartCollectionID = nil
            filter = .all
            return
        }
        if let owner = projects.first(where: { $0.photoPaths.contains(photoPath) }) {
            selectedProjectID = owner.id
            selectedFolderID = nil
            selectedAlbumID = nil
            selectedSmartCollectionID = nil
            filter = .all
            return
        }
        if selectedProjectID == nil {
            if projects.isEmpty { createProject(named: "Library") }
            else { selectedProjectID = projects.first?.id }
        }
        await importFolders([folderURL])
    }

    func removeFolder(_ id: UUID) {
        guard let projectIndex = projects.firstIndex(where: { $0.id == selectedProjectID }) else { return }
        projects[projectIndex].folderIDs.remove(id)
        if selectedFolderID == id { selectedFolderID = nil }
        persist()
    }

    private func migrateProjectCategories() {
        // Old catalogs had global albums. Split them by project membership so
        // category navigation is always scoped to its owning project.
        for legacy in albums.filter({ $0.projectID == nil }) {
            let memberPaths = Set(photos.filter { $0.albumIDs.contains(legacy.id) }
                .map { $0.file.url.standardizedFileURL.path })
            var owners = projects.filter { project in
                photos.contains { photo in
                    memberPaths.contains(photo.file.url.standardizedFileURL.path)
                        && (project.folderIDs.contains(photo.folderID)
                            || project.photoPaths.contains(photo.file.url.standardizedFileURL.path))
                }
            }
            if owners.isEmpty, let first = projects.first { owners = [first] }
            guard !owners.isEmpty else { continue }
            albums.removeAll { $0.id == legacy.id }
            for owner in owners {
                var scoped = legacy
                scoped.id = UUID()
                scoped.projectID = owner.id
                scoped.sourceFolderID = nil
                albums.append(scoped)
                for index in photos.indices where photos[index].albumIDs.contains(legacy.id) {
                    let path = photos[index].file.url.standardizedFileURL.path
                    let belongs = owner.folderIDs.contains(photos[index].folderID) || owner.photoPaths.contains(path)
                    photos[index].albumIDs.remove(legacy.id)
                    if belongs { photos[index].albumIDs.insert(scoped.id) }
                }
            }
        }

        for project in projects {
            for folderID in project.folderIDs { ensureSourceCategory(folderID, projectID: project.id) }
        }
    }

    private func ensureSourceCategory(_ folderID: UUID, projectID: UUID?) {
        guard let projectID, let folder = folders.first(where: { $0.id == folderID }) else { return }
        let sourceIndex = albums.firstIndex { $0.projectID == projectID && $0.sourceFolderID == folderID }
        let namedIndex = albums.firstIndex {
            $0.projectID == projectID && $0.sourceFolderID == nil
                && $0.name.localizedCaseInsensitiveCompare(folder.name) == .orderedSame
        }
        let categoryID: UUID
        if let sourceIndex, let namedIndex, sourceIndex != namedIndex {
            // Early project migration could leave an empty legacy category
            // beside the category created from its source. Keep the familiar
            // name and fold any members into that one category.
            let redundantID = albums[sourceIndex].id
            categoryID = albums[namedIndex].id
            albums[namedIndex].sourceFolderID = folderID
            for index in photos.indices where photos[index].albumIDs.remove(redundantID) != nil {
                photos[index].albumIDs.insert(categoryID)
            }
            albums.remove(at: sourceIndex)
        } else if let sourceIndex {
            categoryID = albums[sourceIndex].id
        } else if let namedIndex {
            albums[namedIndex].sourceFolderID = folderID
            categoryID = albums[namedIndex].id
        } else {
            let base = folder.name
            var name = base
            var suffix = 2
            while albums.contains(where: { $0.projectID == projectID && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                name = "\(base) \(suffix)"
                suffix += 1
            }
            let created = LibraryAlbum(id: UUID(), name: name, projectID: projectID, sourceFolderID: folderID)
            albums.append(created)
            categoryID = created.id
        }
        for index in photos.indices where photos[index].folderID == folderID {
            photos[index].albumIDs.insert(categoryID)
        }
    }

    private func projectPhotos(_ project: LibraryProject) -> [LibraryPhoto] {
        photos.filter {
            let path = $0.file.url.standardizedFileURL.path
            return (project.folderIDs.contains($0.folderID) || project.photoPaths.contains(path))
                && !project.excludedPhotoPaths.contains(path)
        }
    }

    private func foldersForProject(_ project: LibraryProject, records: [LibraryPhoto]) -> [LibraryFolder] {
        let folderIDs = project.folderIDs.union(records.map(\.folderID))
        return folders.filter { folderIDs.contains($0.id) }
    }

    private static func projectFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:")
        let safe = name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(safe.isEmpty ? "Project" : safe).negproject"
    }

    func refresh(projectID: UUID? = nil, afterCurrent: Bool = false) async -> [String] {
        if let activeRefresh {
            let currentProjectID = activeRefreshProjectID
            let currentRefreshID = activeRefreshID
            let result = await activeRefresh.value
            if afterCurrent || currentProjectID != projectID {
                if activeRefreshID == currentRefreshID {
                    self.activeRefresh = nil
                    activeRefreshProjectID = nil
                    activeRefreshID = nil
                    refreshing = false
                }
                return await refresh(projectID: projectID)
            }
            return result
        }
        refreshing = true
        let targetProjectID = projectID ?? selectedProjectID
        activeRefreshProjectID = targetProjectID
        let refreshID = UUID()
        activeRefreshID = refreshID
        let task = Task { await self.refreshNow(projectID: targetProjectID) }
        activeRefresh = task
        let failures = await task.value
        if activeRefreshID == refreshID {
            activeRefresh = nil
            activeRefreshProjectID = nil
            activeRefreshID = nil
            refreshing = false
        }
        return failures
    }

    private func refreshNow(projectID: UUID?) async -> [String] {
        refreshProgress = 0
        let activeFolderIDs = projects.first(where: { $0.id == projectID })?.folderIDs ?? []
        let sources = folders.filter { activeFolderIDs.contains($0.id) }.map { ($0.id, $0.resolvedURL()) }
        refreshTotal = sources.count
        let scans = await withTaskGroup(of: (UUID, [PhotoFile]?, String?).self, returning: [(UUID, [PhotoFile]?, String?)].self) { group in
            var nextSource = 0
            var results: [(UUID, [PhotoFile]?, String?)] = []
            for _ in 0..<min(2, sources.count) {
                let (id, url) = sources[nextSource]
                nextSource += 1
                group.addTask {
                    do { return (id, try PhotoFolder.snapshot(in: url), nil) }
                    catch { return (id, nil, "Couldn’t scan “\(url.lastPathComponent)”: \(error.localizedDescription)") }
                }
            }
            while let result = await group.next() {
                results.append(result)
                refreshProgress += 1
                if let status = importStatus, status.phase == .importing,
                   status.projectID == projectID {
                    importStatus = LibraryImportStatus(projectID: projectID, destinationName: status.destinationName, phase: status.phase,
                                                      importedCount: status.importedCount, progress: refreshProgress,
                                                      total: refreshTotal, message: status.message, canRetry: status.canRetry)
                }
                if nextSource < sources.count {
                    let (id, url) = sources[nextSource]
                    nextSource += 1
                    group.addTask {
                        do { return (id, try PhotoFolder.snapshot(in: url), nil) }
                        catch { return (id, nil, "Couldn’t scan “\(url.lastPathComponent)”: \(error.localizedDescription)") }
                    }
                }
            }
            return results
        }
        // A cancelled caller must not publish a partial multi-folder scan.
        guard !Task.isCancelled else { return [] }
        var previousByFolder = Dictionary(grouping: photos, by: \.folderID)
        var refreshedPhotos = photos.filter { !activeFolderIDs.contains($0.folderID) }
        for (folderID, files, _) in scans {
            // A folder removed while its scan runs must not reappear.
            guard activeFolderIDs.contains(folderID), let files else { continue }
            var byName = Dictionary(uniqueKeysWithValues:
                (previousByFolder.removeValue(forKey: folderID) ?? []).map { ($0.file.name, $0) })
            for name in Array(byName.keys) {
                byName[name]?.missing = true
            }
            for file in files {
                if var old = byName[file.name] {
                    old.file = file
                    old.missing = false
                    byName[file.name] = old
                } else {
                    var added = LibraryPhoto(file: file, folderID: folderID)
                    added.albumIDs = Set(albums.filter { $0.sourceFolderID == folderID }.map(\.id))
                    byName[file.name] = added
                }
            }
            refreshedPhotos.append(contentsOf: byName.values)
        }
        if scans.contains(where: { $0.1 != nil }) {
            refreshedPhotos.append(contentsOf: previousByFolder.values.joined())
            photos = refreshedPhotos.sorted { $0.file.url.path < $1.file.url.path }
            if projectID == selectedProjectID { error = refreshError(for: scans) }
            persist()
        } else if !sources.isEmpty, projectID == selectedProjectID {
            error = refreshError(for: scans)
        }
        if let selectedPhotoURL, !photos.contains(where: { $0.file.url == selectedPhotoURL }) {
            self.selectedPhotoURL = nil
        }
        return scans.compactMap(\.2)
    }

    private func refreshError(for scans: [(UUID, [PhotoFile]?, String?)]) -> String? {
        let failed = scans.compactMap { id, files, _ in
            files == nil ? folders.first(where: { $0.id == id })?.name : nil
        }
        guard !failed.isEmpty else { return nil }
        let shown = failed.prefix(3).joined(separator: ", ")
        let remaining = failed.count - min(failed.count, 3)
        let extra = remaining > 0 ? " and \(remaining) more" : ""
        return "Couldn’t read \(shown)\(extra). Check folder access and retry."
    }

    func analyzeCull(replacingExisting: Bool = false) async {
        guard !analyzingCull else { return }
        let candidates = photos.filter { !$0.missing && (replacingExisting || $0.cull == nil) }
        guard !candidates.isEmpty else { return }
        var photoIndices = Dictionary(uniqueKeysWithValues: photos.enumerated().map { ($0.element.file.url, $0.offset) })
        analyzingCull = true
        cullProgress = 0
        cullTotal = candidates.count
        defer { analyzingCull = false }

        for photo in candidates {
            if Task.isCancelled { break }
            let result = await Task.detached(priority: .utility) {
                CullAnalyzer.analyze(photo.file.url)
            }.value
            let index = photoIndices[photo.file.url].flatMap { index in
                photos.indices.contains(index) && photos[index].file.url == photo.file.url ? index : nil
            } ?? photos.firstIndex(where: { $0.file.url == photo.file.url })
            if let index {
                photos[index].cull = result ?? CullAnalysis(score: 0, sharpness: 0, aesthetics: nil,
                    composition: nil, eyesOpen: nil, faceCount: 0, utilityImage: false, failed: true,
                    reasons: ["Could not decode this image for culling; review it manually"])
                photoIndices[photo.file.url] = index
            }
            cullProgress += 1
        }
        persist()
    }

    func setRating(_ rating: Int, for url: URL? = nil) {
        update(url) { $0.rating = min(5, max(0, rating)) }
    }
    func setFlag(_ flag: LibraryFlag, for url: URL? = nil) { update(url) { $0.flag = flag } }
    func setFlag(_ flag: LibraryFlag, for urls: [URL]) {
        let targets = Set(urls)
        guard !targets.isEmpty else { return }
        var changed = false
        for index in photos.indices where targets.contains(photos[index].file.url) && photos[index].flag != flag {
            photos[index].flag = flag
            changed = true
        }
        if changed { persist() }
    }
    func setClientPick(_ value: Bool, for url: URL? = nil) { update(url) { $0.clientPicked = value } }
    func setExportQueued(_ value: Bool, for url: URL? = nil) { update(url) { $0.selectedForExport = value } }
    func setExportQueued(_ value: Bool, for urls: [URL]) {
        let targets = Set(urls)
        guard !targets.isEmpty else { return }
        var changed = false
        for index in photos.indices where targets.contains(photos[index].file.url) && photos[index].selectedForExport != value {
            photos[index].selectedForExport = value
            changed = true
        }
        if changed { persist() }
    }

    func createAlbum(named name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let projectID = selectedProjectID, !name.isEmpty,
              !albums.contains(where: { $0.projectID == projectID && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { return }
        let album = LibraryAlbum(id: UUID(), name: name, projectID: projectID)
        albums.append(album)
        selectedAlbumID = album.id
        selectedFolderID = nil
        selectedSmartCollectionID = nil
        filter = .all
        persist()
    }

    func renameCategory(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = albums.firstIndex(where: { $0.id == id }),
              !albums.contains(where: { $0.id != id && $0.projectID == albums[index].projectID
                  && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { return }
        albums[index].name = name
        persist()
    }

    func deleteAlbum(_ id: UUID) {
        albums.removeAll { $0.id == id }
        for index in photos.indices { photos[index].albumIDs.remove(id) }
        if selectedAlbumID == id { selectedAlbumID = nil }
        persist()
    }

    func addSelectedPhoto(to albumID: UUID) {
        guard let selectedPhoto else { return }
        addToBin([selectedPhoto], binID: albumID)
    }

    func addToBin(_ targets: [LibraryPhoto], binID: UUID) {
        let urls = Set(targets.map { $0.file.url })
        guard !urls.isEmpty, albums.contains(where: { $0.id == binID }) else { return }
        var changed = false
        for index in photos.indices where urls.contains(photos[index].file.url) && !photos[index].albumIDs.contains(binID) {
            photos[index].albumIDs.insert(binID)
            changed = true
        }
        if changed { persist() }
    }

    func categories(for projectID: UUID) -> [LibraryAlbum] {
        albums.filter { $0.projectID == projectID }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func selectProject(_ id: UUID) {
        guard projects.contains(where: { $0.id == id }) else { return }
        selectedProjectID = id
        selectedFolderID = nil
        selectedAlbumID = nil
        selectedSmartCollectionID = nil
        filter = .all
        persist()
    }

    func selectGroup(_ id: UUID) {
        guard let group = albums.first(where: { $0.id == id }),
              let projectID = group.projectID,
              projects.contains(where: { $0.id == projectID }) else { return }
        selectedProjectID = projectID
        selectedFolderID = nil
        selectedAlbumID = id
        selectedSmartCollectionID = nil
        filter = .all
        persist()
    }

    func selectReviewFilter(_ filter: LibraryFilter) {
        selectedFolderID = nil
        selectedAlbumID = nil
        selectedSmartCollectionID = nil
        self.filter = filter
        persist()
    }

    func removeFromBin(_ targets: [LibraryPhoto], binID: UUID) {
        let urls = Set(targets.map { $0.file.url })
        guard !urls.isEmpty else { return }
        var changed = false
        for index in photos.indices where urls.contains(photos[index].file.url) && photos[index].albumIDs.contains(binID) {
            photos[index].albumIDs.remove(binID)
            changed = true
        }
        if changed { persist() }
    }

    func createSmartCollection(named name: String, filter: LibraryFilter) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let collection = SmartLibraryCollection(id: UUID(), name: name, filter: filter)
        smartCollections.append(collection)
        selectedSmartCollectionID = collection.id
        selectedFolderID = nil
        selectedAlbumID = nil
        selectedProjectID = nil
        persist()
    }

    func deleteSmartCollection(_ id: UUID) {
        smartCollections.removeAll { $0.id == id }
        if selectedSmartCollectionID == id { selectedSmartCollectionID = nil }
        persist()
    }

    func createProject(named name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !projects.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { return }
        let project = LibraryProject(id: UUID(), name: name)
        projects.append(project)
        selectedProjectID = project.id
        selectedFolderID = nil
        selectedAlbumID = nil
        selectedSmartCollectionID = nil
        filter = .all
        persist()
    }

    func renameProject(_ id: UUID, to newName: String) throws {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = projects.firstIndex(where: { $0.id == id }) else { return }
        guard !projects.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            throw EngineError(message: "A project named “\(name)” already exists.")
        }
        var renamed = projects[index]
        renamed.name = name
        if let oldPath = renamed.projectFilePath {
            let oldURL = URL(fileURLWithPath: oldPath)
            if FileManager.default.fileExists(atPath: oldPath) {
                let safeName = Self.projectFileName(name)
                let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(safeName)
                if oldURL.standardizedFileURL != newURL.standardizedFileURL,
                   FileManager.default.fileExists(atPath: newURL.path) {
                    throw EngineError(message: "A project file named “\(safeName)” already exists in that location.")
                }
                let records = projectPhotos(renamed)
                let folders = foldersForProject(renamed, records: records)
                var portable = renamed
                portable.projectFilePath = nil
                let document = LibraryProjectDocument(project: portable, folders: folders, photos: records,
                                                      albums: categories(for: id))
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(document)
                let moved = oldURL.standardizedFileURL != newURL.standardizedFileURL
                if moved { try FileManager.default.moveItem(at: oldURL, to: newURL) }
                do {
                    try data.write(to: newURL, options: .atomic)
                } catch {
                    if moved { try? FileManager.default.moveItem(at: newURL, to: oldURL) }
                    throw error
                }
                renamed.projectFilePath = newURL.path
            } else {
                renamed.projectFilePath = nil
            }
        }
        projects[index] = renamed
        persist()
    }

    func deleteProject(_ id: UUID) {
        let categoryIDs = Set(albums.filter { $0.projectID == id }.map(\.id))
        projects.removeAll { $0.id == id }
        albums.removeAll { $0.projectID == id }
        for index in photos.indices { photos[index].albumIDs.subtract(categoryIDs) }
        if selectedProjectID == id { selectedProjectID = projects.first?.id; selectedFolderID = nil }
        persist()
    }

    func add(_ photos: [LibraryPhoto], to projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].photoPaths.formUnion(photos.map { $0.file.url.standardizedFileURL.path })
        projects[index].excludedPhotoPaths.subtract(photos.map { $0.file.url.standardizedFileURL.path })
        persist()
    }

    func remove(_ photos: [LibraryPhoto], from projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let paths = photos.map { $0.file.url.standardizedFileURL.path }
        let folderIDs = projects[index].folderIDs
        projects[index].photoPaths.subtract(paths)
        projects[index].excludedPhotoPaths.formUnion(photos.filter { folderIDs.contains($0.folderID) }
            .map { $0.file.url.standardizedFileURL.path })
        persist()
    }

    func exportProject(_ id: UUID, to url: URL) throws {
        guard let project = projects.first(where: { $0.id == id }) else { return }
        let records = projectPhotos(project)
        var portable = project
        portable.projectFilePath = nil
        let document = LibraryProjectDocument(project: portable,
                                              folders: foldersForProject(project, records: records),
                                              photos: records, albums: categories(for: id))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: url, options: .atomic)
        if let index = projects.firstIndex(where: { $0.id == id }) {
            projects[index].projectFilePath = url.standardizedFileURL.path
            persist()
        }
    }

    func importProject(from url: URL) async throws {
        let document = try await Task.detached(priority: .userInitiated) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            return try JSONDecoder().decode(LibraryProjectDocument.self, from: Data(contentsOf: url))
        }.value
        guard document.formatVersion == 1, !document.project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EngineError(message: "This Negs project file isn’t supported.")
        }

        // A source folder has one project owner. Validate the complete import
        // before touching the live catalog so a conflict cannot leave a partial
        // project or make the same folder appear under two projects.
        let currentOwners = Dictionary(folders.compactMap { folder in
            projects.first(where: { $0.folderIDs.contains(folder.id) })
                .map { (URL(fileURLWithPath: folder.path).standardizedFileURL.path, $0.name) }
        }, uniquingKeysWith: { first, _ in first })
        for folder in document.folders {
            let path = URL(fileURLWithPath: folder.path).standardizedFileURL.path
            if let owner = currentOwners[path] {
                throw EngineError(message: "Cannot open this project because “\(folder.name)” already belongs to “\(owner)”. Remove that folder from its current project first.")
            }
        }
        let importedFolderIDs = Set(document.folders.map(\.id))
        guard document.photos.allSatisfy({ importedFolderIDs.contains($0.folderID) }) else {
            throw EngineError(message: "This Negs project is incomplete: one or more photographs reference a missing source folder.")
        }

        var project = document.project
        project.id = UUID()
        project.projectFilePath = nil
        let baseName = project.name
        var suffix = 2
        while projects.contains(where: { $0.name.localizedCaseInsensitiveCompare(project.name) == .orderedSame }) {
            project.name = "\(baseName) \(suffix)"
            suffix += 1
        }

        var folderIDs: [UUID: UUID] = [:]
        var foldersByPath = Dictionary(folders.map { (URL(fileURLWithPath: $0.path).standardizedFileURL.path, $0.id) },
                                       uniquingKeysWith: { first, _ in first })
        for folder in document.folders {
            let path = URL(fileURLWithPath: folder.path).standardizedFileURL.path
            if let existingID = foldersByPath[path] {
                folderIDs[folder.id] = existingID
            } else {
                var imported = folder
                imported.id = UUID()
                folderIDs[folder.id] = imported.id
                folders.append(imported)
                foldersByPath[path] = imported.id
            }
        }
        let oldCategoryIDs = Set(document.albums.map(\.id))
        var categoryIDs: [UUID: UUID] = [:]
        for category in document.albums { categoryIDs[category.id] = UUID() }
        let categoryByPath = Dictionary(document.photos.map {
            ($0.file.url.standardizedFileURL.path, $0.albumIDs.intersection(oldCategoryIDs))
        }, uniquingKeysWith: { first, _ in first })
        var knownPaths = Set(photos.map { $0.file.url.standardizedFileURL.path })
        for record in document.photos {
            let path = record.file.url.standardizedFileURL.path
            if knownPaths.insert(path).inserted {
                var imported = record
                imported.folderID = folderIDs[record.folderID] ?? record.folderID
                imported.albumIDs = Set(categoryByPath[path, default: []].compactMap { categoryIDs[$0] })
                imported.missing = true
                photos.append(imported)
            } else if let index = photos.firstIndex(where: { $0.file.url.standardizedFileURL.path == path }) {
                photos[index].albumIDs.formUnion(categoryByPath[path, default: []].compactMap { categoryIDs[$0] })
            }
        }

        var importedCategories = document.albums
        let remappedFolders = Dictionary(uniqueKeysWithValues: folderIDs.map { ($0.key, $0.value) })
        for index in importedCategories.indices {
            importedCategories[index].id = categoryIDs[importedCategories[index].id] ?? UUID()
            importedCategories[index].projectID = project.id
            if let sourceID = importedCategories[index].sourceFolderID {
                importedCategories[index].sourceFolderID = remappedFolders[sourceID] ?? sourceID
            }
        }
        albums.append(contentsOf: importedCategories)

        projects.append(project)
        selectedProjectID = project.id
        selectedFolderID = nil
        selectedAlbumID = nil
        selectedSmartCollectionID = nil
        filter = .all
        beginFolderAccess()
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index].folderIDs = Set(folderIDs.values)
            projects[index].photoPaths = []
        }
        persist()
        await refresh()
    }

    private func update(_ url: URL?, _ change: (inout LibraryPhoto) -> Void) {
        guard let url = url ?? selectedPhotoURL,
              let index = photos.firstIndex(where: { $0.file.url == url }) else { return }
        change(&photos[index])
        persist()
    }

    private func beginFolderAccess() {
        for folder in folders where scopedFolders[folder.id] == nil {
            let url = folder.resolvedURL()
            if url.startAccessingSecurityScopedResource() { scopedFolders[folder.id] = url }
        }
    }

    private func persist() {
        persistenceRevision += 1
        let revision = persistenceRevision
        persistenceTask?.cancel()
        persistenceTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            guard let self, self.persistenceRevision == revision else { return }
            let document = PhotoLibraryDocument(folders: self.folders, photos: self.photos, albums: self.albums,
                                                smartCollections: self.smartCollections, projects: self.projects,
                                                selectedProjectID: self.selectedProjectID)
            do {
                try await PhotoLibraryDiskWriter.shared.save(document, owner: self.persistenceID,
                                                              revision: revision, to: self.storeURL)
            } catch {
                guard self.persistenceRevision == revision else { return }
                self.error = "Could not save the photo Library: \(error.localizedDescription)"
            }
        }
    }

    /// Quit waits for the latest catalog snapshot, including one still in the
    /// short coalescing window, so off-main persistence does not lose the last edit.
    func flushPersistence() async throws {
        persistenceTask?.cancel()
        persistenceTask = nil
        persistenceRevision += 1
        let revision = persistenceRevision
        let document = PhotoLibraryDocument(folders: folders, photos: photos, albums: albums,
                                            smartCollections: smartCollections, projects: projects,
                                            selectedProjectID: selectedProjectID)
        try await PhotoLibraryDiskWriter.shared.save(document, owner: persistenceID, revision: revision, to: storeURL)
    }
}
