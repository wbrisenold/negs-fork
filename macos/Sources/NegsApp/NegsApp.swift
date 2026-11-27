import AppKit
import Darwin
import SwiftUI

/// AppKit runs the application, menus, window, and title bar; the canvas and
/// inspector inside the window are SwiftUI. A SwiftUI scene with the old
/// toolbar and inspector took about twice as long to show the window
/// (docs/native-macos-ui.md, Startup).
@main enum NegsMain {
    private static var instanceLockDescriptor: Int32 = -1

    static func main() {
        MainActor.assumeIsolated {
            guard acquireSingleInstance() else { return }
            let app = NSApplication.shared
            let delegate = ApplicationDelegate()
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        }
    }

    /// This launch replaces any older copy before it creates the editor or
    /// starts an engine. The advisory lock also closes the race between two
    /// nearly simultaneous launches.
    private static func acquireSingleInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return true }
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(bundleID).instance.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else { return false }

        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            instanceLockDescriptor = descriptor
            return true
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let older = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != currentPID && !$0.isTerminated }
        older.forEach { $0.terminate() }

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                instanceLockDescriptor = descriptor
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        older.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
        let forceDeadline = Date().addingTimeInterval(2)
        while Date() < forceDeadline {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                instanceLockDescriptor = descriptor
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        Darwin.close(descriptor)
        fputs("Negs could not acquire its single-instance lock.\n", stderr)
        return false
    }
}

@MainActor final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    let model = EditorModel()
    let updates = UpdateController()
    private let sessions = SessionStore()
    private var menu: MainMenu?
    private var editor: EditorWindowController?
    private var terminating = false
    private var removingAppData = false
    /// The quit questions are open in the alert sheet.
    private var askingToQuit = false
    private var appDataRemovalFinished = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The helper starts while AppKit builds the window, and the cached
        // catalog fills in the inspector's first frame. With that catalog the
        // session restores before the window is built, so its saved frame and
        // adjustments are in the window's first frames; the main actor's tasks
        // only run after AppKit's launch passes. Without a cached catalog, or
        // if the session isn't read within 0.1 s, it restores once the helper
        // answers and reports any error then. Benchmarks and explicit
        // launches must not reopen a previous photograph.
        #if SPEKTRAFILM_BENCHMARK
        LaunchBenchmark.begin(model)
        #endif
        model.launch()
        let benchmark = ProcessInfo.processInfo.environment["SPEKTRAFILM_BENCHMARK_PHOTO"] != nil
        var store: SessionStore? = benchmark ? nil : sessions
        #if SPEKTRAFILM_BENCHMARK
        if let path = ProcessInfo.processInfo.environment["SPEKTRAFILM_BENCHMARK_SESSION"] {
            store = SessionStore(file: URL(fileURLWithPath: path))
        }
        #endif
        var restoration: Task<EditorSession?, Error>?
        // The last photograph's sidecar is read with the session, a few kilobytes more.
        let sidecars = model.sidecarLookup
        if let store, Self.pathArgument != nil || !(Self.readSession(store, sidecars: sidecars, timeout: 0.1).map(model.restoreAtLaunch) ?? false) {
            restoration = Task { try await store.load(sidecars: sidecars) }
        }
        Task { await model.start(restoration: restoration) }
        menu = MainMenu(model: model, updates: updates) { [weak self] in self?.removeAllAppData() }
        NSApp.mainMenu = menu?.menu
        editor = EditorWindowController(model: model)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // The saved frame has usually been read while AppKit built the
        // window; waiting briefly puts it in the window's first frame. A
        // Finder open may have undone the restore that titled the window.
        model.finishLaunching(waitingUpTo: 0.15)
        editor?.refresh()
        editor?.showWindow(nil)
        #if SPEKTRAFILM_BENCHMARK
        LaunchBenchmark.windowShown()
        #endif
        NSApp.activate(ignoringOtherApps: true)
        // Finder opens arrive through application(_:open:); a path argument is for `swift run`.
        if let path = Self.pathArgument { model.open(URL(fileURLWithPath: path)) }
        #if SPEKTRAFILM_BENCHMARK
        InteractionBenchmark.start(model)
        GridBenchmark.start(model)
        #endif
        updates.schedule(afterStartupOf: model)
        offerBatchResume()
    }

    /// An export the last session didn't finish is offered once launch has
    /// settled, as updates are: never on the launch path.
    private func offerBatchResume() {
        guard ProcessInfo.processInfo.environment["SPEKTRAFILM_BENCHMARK_PHOTO"] == nil else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            while let self, !Task.isCancelled {
                let model = self.model
                if model.ready && (model.source == nil || model.previewCurrent || model.renderFailed) || model.error != nil {
                    return model.offerBatchResume()
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }
    /// The session, read on another thread and waited for at most `timeout`,
    /// so a photograph on an unresponsive volume never holds up launch. Nil
    /// if there's none, it can't be read, or it takes longer.
    private static func readSession(_ store: SessionStore, sidecars: SidecarLookup?, timeout: TimeInterval) -> EditorSession? {
        final class Result: @unchecked Sendable { var session: EditorSession? }
        let result = Result(), done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            result.session = try? store.read(sidecars: sidecars)
            done.signal()
        }
        // The semaphore orders the write before this read.
        return done.wait(timeout: .now() + timeout) == .success ? result.session : nil
    }
    private static var pathArgument: String? {
        CommandLine.arguments.dropFirst().first { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first(where: \.isFileURL) { model.open(url) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Cleanup intentionally discards the session. Never recreate it here.
        if removingAppData { return appDataRemovalFinished ? .terminateNow : .terminateCancel }
        guard !terminating else { return .terminateLater }
        if model.saving || (updates.installing && model.exporting) || askingToQuit { return .terminateCancel }
        // A question already open is answered first.
        if model.alerts.shown != nil { NSSound.beep(); return .terminateCancel }
        let questions = quitQuestions()
        guard !questions.isEmpty else { return saveAndTerminate(sender) }
        askingToQuit = true
        Task {
            for (alert, quit) in questions where await model.ask(alert).button != quit {
                askingToQuit = false
                return sender.reply(toApplicationShouldTerminate: false)
            }
            askingToQuit = false
            switch saveAndTerminate(sender) {
            case .terminateNow: sender.reply(toApplicationShouldTerminate: true)
            case .terminateCancel: sender.reply(toApplicationShouldTerminate: false)
            default: break
            }
        }
        return .terminateLater
    }

    /// What quitting now would stop, as questions in the alert sheet, each
    /// with the button that quits.
    private func quitQuestions() -> [(AppAlert, quit: Int)] {
        var questions: [(AppAlert, quit: Int)] = []
        if model.batchRunning, let remaining = model.batch?.journal.remaining, !updates.installing {
            // Kept in the journal: the next launch offers to resume.
            questions.append((AppAlert(
                title: "Export \(remaining == 1 ? "the remaining photograph" : "\(remaining) remaining photographs") next time?",
                detail: "Quitting stops the export. Files already exported stay; Negs offers to export the rest when it opens again.",
                buttons: [.init(title: "Quit"), .init(title: "Cancel", role: .cancel)]), 0))
        }
        if model.exporting {
            questions.append((AppAlert(
                title: "An export is still in progress.",
                detail: "Quitting cancels it. Any existing file at the destination is left unchanged.",
                buttons: [.init(title: "Continue Exporting", role: .cancel), .init(title: "Quit")]), 1))
        }
        return questions
    }

    /// Save once at quit/relaunch, not on slider changes or the rendering path.
    /// A failed write cancels termination instead of silently losing the
    /// session or Library catalog. The photograph's edits go to its sidecar first.
    private func saveAndTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ProcessInfo.processInfo.environment["SPEKTRAFILM_BENCHMARK_PHOTO"] == nil else { return .terminateNow }
        terminating = true
        Task {
            do {
                await model.flushSidecars()
                if let session = model.session {
                    try await sessions.save(session)
                    await model.flushPreviewCache()
                }
                try await model.photoLibrary.flushPersistence()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                terminating = false
                sender.reply(toApplicationShouldTerminate: false)
                model.error = "Could not save Negs data. The app stayed open. \(error.localizedDescription)"
            }
        }
        return .terminateLater
    }

    private func removeAllAppData() {
        guard !removingAppData, !terminating, !model.saving, !model.exporting, !model.batchRunning, !updates.installing, !updates.sessionInProgress else { return }
        Task {
            let answer = await model.ask(AppAlert(
                title: "Remove all Negs app data and quit?",
                detail: "This removes your settings, presets, saved editing session, recent-file history, and caches. Your current adjustments will be discarded. Original photographs and exported images are kept.\n\nNegs remains installed. You can move it to the Trash after it quits.",
                buttons: [.init(title: "Cancel", role: .cancel), .init(title: "Remove App Data and Quit", role: .destructive)]))
            guard answer.button == 1 else { return }
            // Anything started while it was asking keeps the data.
            guard !removingAppData, !terminating, !model.saving, !model.exporting, !model.batchRunning, !updates.installing, !updates.sessionInProgress else { return }
            removingAppData = true
            updates.stopForAppDataRemoval()
            editor?.prepareForAppDataRemoval()
            menu?.prepareForAppDataRemoval()
            model.shutdown()
            await model.flushPreviewCache()
            // Wait for an in-flight startup load before deleting session files.
            await sessions.finishPendingIO()
            let locations = AppDataLocations.current
            while true {
                NSDocumentController.shared.clearRecentDocuments(nil)
                var failures = await Task.detached(priority: .userInitiated) { AppDataCleaner.removeFiles(at: locations) }.value
                if !AppDataCleaner.removePreferences(domain: locations.preferencesDomain) {
                    failures.append("The saved preferences could not be cleared.")
                }
                if failures.isEmpty { break }
                // The window is gone, so the sheet stands on its own.
                let retry = await model.ask(AppAlert(title: "Some app data could not be removed.", detail: failures.joined(separator: "\n\n"),
                                                     buttons: [.init(title: "Retry"), .init(title: "Quit", role: .cancel)]))
                if retry.button != 0 { break }
            }
            appDataRemovalFinished = true
            NSApp.terminate(nil)
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        updates.stop()
        model.shutdown()
    }
}

/// The window's main column: the photograph, the drop target, and the status bar.
struct EditorCanvas: View {
    let model: EditorModel
    @State private var dropTargeted = false

    var body: some View {
        let grid = model.mode == .grid
        HStack(spacing: 0) {
            if model.source != nil, !model.imageOnly {
                VStack(spacing: 0) {
                    PrintLabel(model: model)
                    if model.stripShown, model.tray == nil {
                        PhotoRail(model: model).frame(maxHeight: .infinity)
                    } else if model.tray == nil {
                        VStack(spacing: 9) {
                            Text("Photo strip hidden").font(Theme.text(12, italic: true)).foregroundStyle(Theme.dim)
                            Button("Show Film Strip") { model.toggleFilmstrip() }
                                .buttonStyle(OutlinedButtonStyle())
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Spacer(minLength: 0)
                    }
                }
                .frame(width: PhotoRail.width)
                .frame(maxHeight: .infinity)
                .background(Theme.film)
            }

            VStack(spacing: 0) {
                // The grid's sheet covers the canvas, so returning is instant
                // and keeps the current photograph's zoom.
                CanvasArea(model: model, dropping: dropTargeted)
                if let tray = model.tray, !grid {
                    StockTray(model: model, visit: tray)
                } else if !dropTargeted, !model.imageOnly,
                          model.source != nil || model.exporting || model.batch != nil {
                    StatusBar(model: model)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        }
        // Where the strip's frames report their places (`SheetFlight`).
        .coordinateSpace(.named(ThumbnailPlaces.space))
        // A photograph or a folder dropped anywhere on the column opens.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.isFileURL else { return false }
            model.open(url); return true
        } isTargeted: { dropTargeted = $0 }
        // Under the grid's sheet, hidden from VoiceOver too.
        .accessibilityHidden(grid)
        .modifier(LibraryNoteTimer(model: model))
        // The open photograph's folder is the library, listed once the
        // window is up and kept current while it stays open.
        .task(id: model.source?.deletingLastPathComponent()) {
            guard let folder = model.source?.deletingLastPathComponent() else { return }
            await model.library.watch(folder)
        }
    }
}

/// The inspector column: the adjustments, or the crop panel while cropping.
struct InspectorPanel: View {
    let model: EditorModel
    /// False until the window is on screen; see EditorWindowController.
    var built = true

    var body: some View {
        ZStack(alignment: .top) {
            Theme.panel
            if !built { Color.clear }
            else if let session = model.cropSession { CropInspector(model: model, session: session) }
            else {
                VStack(spacing: 0) {
                    PaneHeader(model: model)
                    if model.inspectorPane == .presets { PresetInspector(model: model) }
                    // The sections aren't built until a photograph opens.
                    else if model.source == nil { InspectorEmptyLine() }
                    else { AdjustmentInspector(model: model) }
                }
            }
        }
        // With the divider's rule (`EdgeSplitView`), outlines the column
        // where it meets the title band (round 25 A).
        .overlay(alignment: .top) { Theme.line.frame(height: 1).allowsHitTesting(false) }
        .tint(Theme.paper)
        // Under the grid's sheet (§4.6).
        .accessibilityHidden(model.mode == .grid)
    }
}

/// The panel with no photograph: one line instead of its tabs (§4.14).
struct InspectorEmptyLine: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InkRule()
            Text("The film, the paper and every setting appear here once a photograph is open.")
                .font(Theme.text(14, italic: true)).foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Size.gutter)
                .padding(.top, 18)
            Spacer(minLength: 0)
        }
    }
}

/// Reads only the preview state, so edits don't re-evaluate the canvas.
struct CanvasArea: View {
    let model: EditorModel
    /// While a file is dragged over the window, the photograph, caption and
    /// label step aside for a line round the print's place (§4.14).
    var dropping = false
    @State private var geometry = CanvasGeometry()
    /// The pointer is over the photograph, which brightens the trim marks.
    @State private var overPrint = false
    /// Settings › Photographs › Viewer.
    @AppStorage(ViewerSheet.key) private var sheet = ViewerSheet.darkroom
    /// A monitor-only frame, independent of the photograph's export border.
    @AppStorage("negs.viewer.frameBorder") private var frameBorderVisible = false
    @State private var showingFilmFormat = false

    /// A single metadata caption above the image. Stock selectors live in the
    /// left develop rail, leaving the photograph's top edge visually quiet.
    static let captionBand: CGFloat = 82
    private var headerBand: CGFloat { model.source == nil ? 54 : Self.captionBand }
    static let labelBand: CGFloat = 0

    var body: some View {
        ZStack {
            sheet.color
            if let session = model.cropSession, let image = model.image {
                CropEditor(model: model, session: session, image: image)
            } else if model.source == nil, model.image == nil, model.standIn == nil, model.placeholder == nil {
                EmptyCanvas(model: model, dropping: dropping)
            } else {
                let failure = model.developFailure
                if failure == nil, !dropping, model.comparisonMode != .threeUp { lightTable }
                VStack(spacing: 0) {
                    Color.clear.frame(height: headerBand)
                    // Couldn't develop: the last develop, faded and greyed.
                    photograph
                        .grayscale(failure == nil ? 0 : 1)
                        .opacity(dropping ? 0 : failure == nil ? 1 : 0.12)
                }
                .overlay(alignment: .topLeading) {
                    if model.comparisonMode != .threeUp, !dropping, model.image != nil || model.standIn != nil || model.placeholder != nil {
                        GeometryReader { proxy in marks(in: proxy.size) }
                    }
                }
                if dropping {
                    EmptyCanvas(model: model, dropping: true, print: shownPrint)
                } else if let failure {
                    DevelopFailure(name: model.sourceItem.map { model.library.name(of: $0) } ?? "The photograph",
                                   reason: failure, retry: model.retryDevelop)
                        .padding(.top, headerBand).padding(.bottom, Self.labelBand)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.source != nil, !model.cropping {
                HStack(spacing: 2) {
                    Button { showingFilmFormat.toggle() } label: {
                        Label("Format", systemImage: "camera.aperture")
                            .padding(.horizontal, 9).padding(.vertical, 6)
                    }
                        .popover(isPresented: $showingFilmFormat, arrowEdge: .top) {
                            FilmFormatPicker(model: model)
                                .padding(10).frame(width: 300).background(Theme.panel)
                        }
                        .help("Choose the camera film format used for this photograph")
                    toolbarDivider
                    Menu {
                        Picker("Preview", selection: Binding(get: { model.comparisonMode }, set: { model.comparisonMode = $0 })) {
                            ForEach(PreviewCompareMode.allCases) { mode in Text(mode.title).tag(mode) }
                        }
                        Divider()
                        Button("Save Current as Version 1") { model.saveVersion(1) }
                        Button("Save Current as Version 2") { model.saveVersion(2) }
                        if !model.savedVersions.isEmpty { Divider() }
                        ForEach(model.savedVersions) { version in Button("Apply \(version.name)") { model.applyVersion(version.slot) } }
                    } label: {
                        Label("Compare", systemImage: "square.split.2x1")
                            .padding(.horizontal, 9).padding(.vertical, 6)
                    }
                    .help("Save and compare this photo’s original and edit versions")
                    toolbarDivider
                    Button { frameBorderVisible.toggle() } label: {
                        Label("Frame", systemImage: "viewfinder")
                            .padding(.horizontal, 9).padding(.vertical, 6)
                    }
                    .foregroundStyle(frameBorderVisible ? Theme.accent : Theme.label)
                    .accessibilityAddTraits(frameBorderVisible ? .isSelected : [])
                        .help("Show a viewer-only frame; it is never exported")
                }
                .buttonStyle(InkPressStyle())
                .font(Theme.text(12, weight: 600))
                .foregroundStyle(Theme.label)
                .padding(.horizontal, 5).padding(.vertical, 4)
                .background(Theme.panel.opacity(0.94), in: Capsule())
                .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
                .padding(.top, 8).padding(.trailing, 12)
            }
        }
        .overlay {
            if (model.comparisonMode == .wipe && model.comparisonOriginal != nil)
                || model.comparisonMode == .versionWipe {
                GeometryReader { proxy in
                    let y = headerBand
                    let height = max(proxy.size.height - headerBand - Self.labelBand, 1)
                    let print = shownPrint ?? CGRect(x: 0, y: y, width: proxy.size.width, height: height)
                    ZStack {
                        let comparisonReady = model.comparisonMode == .versionWipe
                            ? model.versionImages[1] != nil && model.versionImages[2] != nil
                            : model.comparisonOriginal != nil
                        if comparisonReady {
                            Capsule().fill(.black.opacity(0.38)).frame(width: 28, height: height)
                                .overlay(Rectangle().fill(.white.opacity(0.95)).frame(width: 2, height: height - 12))
                                .position(x: print.minX + print.width * model.wipePosition, y: y + height / 2)
                                .contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("wipeCanvas"))
                                    .onChanged { value in
                                        model.wipePosition = min(max((value.location.x - print.minX) / max(print.width, 1), 0.02), 0.98)
                                    })
                        } else {
                            let hasBothVersions = [1, 2].allSatisfy { slot in model.savedVersions.contains(where: { $0.slot == slot }) }
                            Text(hasBothVersions ? "Rendering both saved versions at preview quality…" : "Save Version 1 and Version 2 to compare them")
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .padding(10).background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 7))
                                .position(x: proxy.size.width / 2, y: y + height / 2)
                        }
                        if model.comparisonMode == .versionWipe {
                            HStack(spacing: 8) {
                                versionChoice(1)
                                Spacer()
                                versionChoice(2)
                            }
                            .frame(height: 28)
                            .position(x: proxy.size.width / 2, y: y + 18)
                            HStack(spacing: 8) {
                                Button { model.exportVersion(1) } label: { Label("Export Version 1", systemImage: "square.and.arrow.up") }
                                    .disabled(!model.savedVersions.contains(where: { $0.slot == 1 }) || !model.canExport)
                                Button { model.exportVersion(2) } label: { Label("Export Version 2", systemImage: "square.and.arrow.up") }
                                    .disabled(!model.savedVersions.contains(where: { $0.slot == 2 }) || !model.canExport)
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(.white)
                            .position(x: proxy.size.width / 2, y: y + height - 24)
                        } else {
                            HStack {
                                Text("BEFORE").padding(.leading, 12)
                                Spacer()
                                Text("CURRENT").padding(.trailing, 12)
                            }
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white).shadow(color: .black.opacity(0.7), radius: 3)
                            .frame(height: 24).position(x: proxy.size.width / 2, y: y + 16)
                        }
                        HStack(spacing: 5) {
                            Button { model.canvasScale.zoom(by: 0.8) } label: { Image(systemName: "minus.magnifyingglass") }
                                .help("Zoom out")
                            Button { model.zoom(fit: true) } label: { Text(model.comparisonMode == .versionWipe ? "Fit Both" : "Fit") }
                                .help(model.comparisonMode == .versionWipe
                                      ? "Fit both versions together. Pan and zoom stay matched."
                                      : "Fit the full photograph in the preview")
                            Button { model.canvasScale.zoom(by: 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                                .help("Zoom in")
                            Divider().frame(height: 16)
                            Button("Exit Wipe") { model.comparisonMode = .off }
                                .help("Return to the edited photograph")
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 7))
                        .foregroundStyle(.white)
                        .position(x: proxy.size.width - 100, y: y + 16)
                    }
                    .coordinateSpace(name: "wipeCanvas")
                }
            }
        }
        .environment(\.sheetInk, sheet.ink)
        // On its own dark plate, so it reads on any sheet.
        .overlay(alignment: .topLeading) { developTag }
        .onContinuousHover { phase in
            let over: Bool
            if case .active(let point) = phase, let print = shownPrint { over = print.contains(point) } else { over = false }
            if over != overPrint { overPrint = over }
        }
    }

    private var toolbarDivider: some View {
        Rectangle().fill(Theme.line).frame(width: 1, height: 16).padding(.horizontal, 3)
    }

    /// The print's place on the canvas, once it's laid out.
    private var shownPrint: CGRect? {
        geometry.print.width > 0 ? geometry.print.offsetBy(dx: 0, dy: headerBand) : nil
    }

    /// The border on screen, as `photograph` passes it to the preview.
    private var shownBorder: BorderSettings? {
        if model.original == nil, let trial = model.trialImage {
            return model.border.shown(for: Self.standInSize(trial, photo: model.photoSize))
        } else if model.image != nil {
            return model.border.shown(for: model.crop.size(of: model.imageSize))
        } else if model.standIn != nil {
            return nil
        } else if model.placeholder != nil {
            return model.border.shown(for: model.crop.size(of: model.placeholderSize))
        }
        return nil
    }

    /// A light under the print when its border's edge sinks into the sheet
    /// (`LightTable`). Fitted only: zoomed in, the print has no edges on screen.
    @ViewBuilder private var lightTable: some View {
        if !geometry.zoomed, let print = shownPrint,
           let light = LightTable.light(sheet: sheet.hex, edge: LightTable.edge(of: shownBorder)) {
            LightTableGlow(print: print, color: light)
        }
    }

    /// Developing or Updating, at the top centre of the photograph's visible part.
    @ViewBuilder private var developTag: some View {
        let title = DevelopTagTitle.title(source: model.source != nil, failed: model.renderFailed,
                                          developed: model.image != nil, slow: model.showsActivity,
                                          loadingOriginal: model.loadingOriginal)
        ZStack {
            if let title, !dropping, !model.cropping {
                GeometryReader { proxy in
                    let canvas = CGRect(origin: .zero, size: proxy.size)
                    let visible = shownPrint.map { $0.intersection(canvas) } ?? CGRect(x: 0, y: headerBand, width: proxy.size.width, height: 0)
                    DevelopTag(title: title)
                        .frame(width: max(visible.width, 1))
                        .offset(x: visible.minX, y: visible.minY + 16)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: title)
        .allowsHitTesting(false)
    }

    @ViewBuilder private var photograph: some View {
        if model.comparisonMode == .threeUp, model.source != nil, model.image != nil {
            comparePanels
        } else if model.original == nil, let trial = model.trialImage {
            // A tried stock's tile, enlarged at once until its develop is in (§5.1).
            let size = Self.standInSize(trial, photo: model.photoSize)
            PreviewCanvas(image: trial, size: size, rotation: 0, crop: CropSettings(), border: previewBorder(for: size),
                          filmTexture: model.filmTexture, filmStrip: model.filmStrip, zoomCommand: model.zoomCommand, fit: model.fitImage,
                          scale: model.canvasScale, geometry: geometry, upsideDown: model.upsideDown,
                          doubleClick: { [model] in model.doubleClickPhotograph(zoomed: $0) })
        } else if let image = model.image {
            canvas(model.original ?? image, size: model.imageSize, rotation: model.imageRotation)
        } else if let standIn = model.standIn {
            // Finished already: drawn as it is, the size the photograph will be.
            PreviewCanvas(image: standIn, size: Self.standInSize(standIn, photo: model.placeholderSize), rotation: 0, crop: CropSettings(),
                          border: nil, filmTexture: nil, filmStrip: nil, zoomCommand: model.zoomCommand, fit: model.fitImage,
                          scale: model.canvasScale, geometry: geometry, upsideDown: model.upsideDown,
                          doubleClick: { [model] in model.doubleClickPhotograph(zoomed: $0) })
        } else if let placeholder = model.placeholder {
            canvas(placeholder, size: model.placeholderSize, rotation: model.imageRotation)
        } else {
            Color.clear
        }
    }

    /// Camera metadata above the print, kept inside the short caption band.
    @ViewBuilder private func marks(in size: CGSize) -> some View {
        let print = geometry.print.offsetBy(dx: 0, dy: headerBand)
        if print.width > 0 {
            let margin = ImageScrollView.fitInset
            let left = max(print.minX, margin)
            let right = min(print.maxX, size.width - margin)
            let width = max(right - left, 1)
            let portrait = !geometry.zoomed && print.height > print.width
            PhotoCaption(facts: model.photoFacts, fileName: model.sourceItem.map { model.library.name(of: $0) } ?? "", portrait: portrait)
                .frame(width: width, height: 24, alignment: .center)
                .offset(x: left, y: 50)
            if let slot = model.previewVersionSlot, model.comparisonMode == .off {
                Text("VERSION \(slot)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.black.opacity(0.68), in: Capsule())
                    .position(x: left + 42, y: print.minY + 18)
                    .accessibilityLabel("Showing saved Version \(slot)")
            }
            // Not zoomed in: the corners are off the canvas then (§4.3).
            // Nor in Image Only, which crops nothing.
            if !geometry.zoomed, !model.imageOnly, model.image != nil, model.developFailure == nil {
                CropTrimMarks(model: model, print: print, lit: overPrint, crop: model.beginCrop)
            }
        }
    }

    /// The stand-in's layout size: its own shape (fitted, only that shows),
    /// with the long side of the photograph's placeholder once that's read,
    /// else 2048, as a RAW's.
    static func standInSize(_ image: CGImage, photo: CGSize) -> CGSize {
        let long = max(photo.width, photo.height) > 0 ? max(photo.width, photo.height) : 2048
        let scale = long / CGFloat(max(image.width, image.height, 1))
        return CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    }

    private func canvas(_ image: AnyObject, size: CGSize, rotation: Int) -> some View {
        let wipeBase: AnyObject = model.comparisonMode == .versionWipe ? (model.versionImages[2] ?? image) : image
        return PreviewCanvas(image: wipeBase, size: size, rotation: rotation, crop: model.crop, border: previewBorder(for: model.crop.size(of: size)), filmTexture: model.filmTexture,
                      filmStrip: model.filmStrip, diagnosticOverlay: model.comparisonMode == .off && model.original == nil ? model.diagnosticOverlay : nil,
                      backgroundMaskOverlay: model.comparisonMode == .off && model.original == nil ? model.visibleBackgroundMaskOverlay : nil,
                      backgroundMaskOverlayOpacity: CGFloat(model.backgroundMaskOverlayOpacity),
                      comparisonImage: wipeComparisonImage, wipeFraction: model.wipePosition,
                      zoomCommand: model.zoomCommand, fit: model.fitImage, scale: model.canvasScale, geometry: geometry,
                      upsideDown: model.upsideDown, settled: model.original != nil || model.showsSettledFrame,
                      doubleClick: { [model] in model.doubleClickPhotograph(zoomed: $0) },
                      colorPickTapEnabled: model.scopeMode == .picker,
                      colorPicked: { [model] point in model.pickColor(at: point) },
                      maskPaintingEnabled: model.backgroundMaskBrushActive && !model.backgroundMaskGenerating,
                      maskBrushSubtract: model.backgroundMaskBrushSubtract,
                      maskStrokeBegan: { [model] point in model.beginBackgroundMaskStroke(at: point) },
                      maskStrokeChanged: { [model] point in model.continueBackgroundMaskStroke(at: point) },
                      maskStrokeEnded: { [model] in model.endBackgroundMaskStroke() })
    }

    private var wipeComparisonImage: AnyObject? {
        switch model.comparisonMode {
        case .wipe: model.comparisonOriginal
        case .versionWipe: model.versionImages[1]
        case .off, .threeUp: nil
        }
    }

    private func versionChoice(_ slot: Int) -> some View {
        let saved = model.savedVersions.contains(where: { $0.slot == slot })
        let selected = model.editingVersionSlot == slot
        return Button { model.selectVersionForEditing(slot) } label: {
            VStack(spacing: 2) {
                Text("VERSION \(slot)").font(.system(size: 10, weight: .bold, design: .rounded))
                Text(selected ? "EDITING" : saved ? "Click to edit" : "Not saved")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
            }
            .foregroundStyle(selected ? Theme.accent : .white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(selected ? Theme.accent.opacity(0.18) : .black.opacity(0.72), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? Theme.accent.opacity(0.85) : .white.opacity(0.28), lineWidth: 1))
        }
        .buttonStyle(.borderless)
        .disabled(!saved)
        .help(saved ? "Select Version \(slot) to edit it; changes are saved back to that version." : "Save an edit to Version \(slot) first.")
    }

    @ViewBuilder private var comparePanels: some View {
        VStack(spacing: 3) {
            HStack {
                Spacer()
                Label("VIEWS LINKED", systemImage: "link")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
                Button { model.zoom(fit: true) } label: {
                    Label("Fit & Sync", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.borderless)
                .help("Fit both saved versions to their panels. Panning and zooming either version keeps the other matched.")
            }
            .padding(.horizontal, 12).frame(height: 34)
            HStack(spacing: 1) {
                comparePanel("Before", image: model.comparisonOriginal, crop: model.crop)
                ForEach(1...2, id: \.self) { slot in
                    comparePanel("Version \(slot)", image: model.versionImages[slot], crop: model.savedVersions.first(where: { $0.slot == slot })?.state.crop ?? model.crop)
                }
            }
        }
        .background(.black.opacity(0.2))
    }

    private func comparePanel(_ title: String, image: AnyObject?, crop: CropSettings) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                if title == "Before" {
                    Text(title).font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                } else if let slot = Int(title.split(separator: " ").last ?? "") {
                    Button { model.selectVersionForEditing(slot) } label: {
                        HStack(spacing: 7) {
                            Image(systemName: model.editingVersionSlot == slot ? "slider.horizontal.3" : "hand.tap")
                                .font(.system(size: 10, weight: .semibold))
                            Text("VERSION \(slot)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .tracking(0.45)
                            Text(model.editingVersionSlot == slot ? "EDITING" : "EDIT")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .tracking(0.35)
                        }
                        .foregroundStyle(model.editingVersionSlot == slot ? Theme.onAccent : Theme.label)
                        .padding(.horizontal, 11).padding(.vertical, 7)
                        .background(model.editingVersionSlot == slot ? Theme.accent : Theme.panel,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .stroke(model.editingVersionSlot == slot ? Theme.accent : Theme.line, lineWidth: 1))
                    }
                    .buttonStyle(.borderless)
                    .help("Click to load Version \(slot) into the controls. Changes save back here while comparison stays open.")
                    Spacer()
                    Button { model.exportVersion(slot) } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.label)
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .background(Theme.panel, in: Capsule())
                            .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
                    }
                    .buttonStyle(.borderless)
                    .disabled(!model.canExport)
                    .help("Export this saved version")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            if let image {
                PreviewCanvas(image: image, size: model.imageSize, rotation: model.imageRotation, crop: crop,
                              border: previewBorder(for: crop.size(of: model.imageSize)), filmTexture: model.filmTexture,
                              filmStrip: model.filmStrip, zoomCommand: model.zoomCommand, fit: true,
                              navigation: title == "Before" ? nil : model.versionNavigation,
                              navigationSlot: Int(title.split(separator: " ").last ?? ""))
            } else {
                ContentUnavailableView(title, systemImage: "photo", description: Text(title == "Before" ? "Loading original" : "Save a version to this slot"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The frame preview is painted around the canvas copy only. Export reads
    /// `model.border` directly, so this monitor preference cannot be baked in.
    private func previewBorder(for size: CGSize) -> BorderSettings? {
        guard frameBorderVisible || model.border.enabled else { return nil }
        var border = model.border
        if frameBorderVisible { border.enabled = true }
        border.export = false
        return border.shown(for: size)
    }
}
