import AppKit

// A compact studio header: persistent Library/Develop navigation, the active
// file name, and a direct Export action.

/// The window's content: the title band over the split view. The columns,
/// the grid's sheet and the alert's dimming all start under the band.
@MainActor final class EditorFrame: NSViewController {
    let split: NSSplitViewController
    let band = TitleBand()

    init(split: NSSplitViewController, size: NSSize,
         onSelectWorkspace: @escaping (EditorWorkspace) -> Bool, onExport: @escaping (NSView) -> Void,
         onShowAdjustments: @escaping () -> Void) {
        self.split = split
        super.init(nibName: nil, bundle: nil)
        band.onSelectWorkspace = onSelectWorkspace
        band.onExport = onExport
        band.onShowAdjustments = onShowAdjustments
        let view = EditorFrameView(band: band, content: split.view)
        view.frame = NSRect(origin: .zero, size: size)
        self.view = view
        addChild(split)
        view.addSubview(split.view)
        view.addSubview(band)
        view.place()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

final class EditorFrameView: NSView {
    let band: TitleBand
    let content: NSView

    init(band: TitleBand, content: NSView) {
        self.band = band
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.NS.bg.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // The band takes no clicks: they go to the window's title bar under
    // it, which drags and zooms the window.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self || hit === band ? nil : hit
    }

    // Placed as the frame changes, not on the next layout pass, so the
    // columns never have a moment at the wrong size.
    override func resizeSubviews(withOldSize oldSize: NSSize) { place() }

    func place() {
        let height = min(Theme.Size.titleBar, bounds.height)
        band.frame = NSRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
        content.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - height)
    }
}

/// The title band holds the filename and compact workspace/actions controls;
/// its unused background still lets the window drag and zoom.
final class TitleBand: NSView {
    let name = NSTextField(labelWithString: "Negs")
    private let workspaceSwitcher = NSSegmentedControl(labels: ["Library", "Develop"], trackingMode: .selectOne, target: nil, action: nil)
    private let exportButton = NSButton(title: "Export", target: nil, action: nil)
    private let showAdjustmentsButton = NSButton(title: "Adjustments", target: nil, action: nil)
    var onSelectWorkspace: ((EditorWorkspace) -> Bool)?
    var onExport: ((NSView) -> Void)?
    var onShowAdjustments: (() -> Void)?
    var showsAdjustmentReopen = false {
        didSet { showAdjustmentsButton.isHidden = !showsStudioControls || !showsAdjustmentReopen; needsLayout = true }
    }
    var showingLibrary = false {
        didSet { synchronizeWorkspaceSelection() }
    }
    var exportEnabled = false {
        didSet { exportButton.isEnabled = exportEnabled }
    }
    var exportHelp = "Export the current photograph or selected photos" {
        didSet { exportButton.toolTip = exportHelp }
    }
    var exportTitle = "Export" {
        didSet {
            exportButton.title = exportTitle
            exportButton.setAccessibilityLabel(exportTitle == "Progress" ? "View export progress and results" : "Export photograph or selection")
            needsLayout = true
        }
    }
    var showsStudioControls = true {
        didSet {
            workspaceSwitcher.isHidden = !showsStudioControls
            exportButton.isHidden = !showsStudioControls
            showAdjustmentsButton.isHidden = !showsStudioControls || !showsAdjustmentReopen
            needsLayout = true
        }
    }
    /// Between the zoom button and the name (`.lights`' 14 pt padding).
    static let gap: CGFloat = 14
    /// Where the name starts in full screen, with no traffic lights.
    static let fullScreenInset: CGFloat = Theme.Size.gutter

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.NS.bg.cgColor
        name.font = Theme.textFont(13, weight: 600) as NSFont
        name.textColor = Theme.NS.paper
        name.lineBreakMode = .byTruncatingMiddle
        name.cell?.truncatesLastVisibleLine = true
        // The window's title says it; VoiceOver reads that.
        name.setAccessibilityElement(false)
        addSubview(name)
        workspaceSwitcher.setImage(NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Library"), forSegment: 0)
        workspaceSwitcher.setImage(NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Develop"), forSegment: 1)
        workspaceSwitcher.segmentStyle = .capsule
        workspaceSwitcher.controlSize = .small
        workspaceSwitcher.selectedSegmentBezelColor = Theme.NS.accent
        workspaceSwitcher.setWidth(88, forSegment: 0)
        workspaceSwitcher.setWidth(88, forSegment: 1)
        workspaceSwitcher.setToolTip("Browse and organize photographs", forSegment: 0)
        workspaceSwitcher.setToolTip("Develop the selected photograph", forSegment: 1)
        workspaceSwitcher.setAccessibilityLabel("Workspace")
        workspaceSwitcher.setAccessibilityIdentifier("workspace-switcher")
        workspaceSwitcher.toolTip = "Choose Library or Develop"
        workspaceSwitcher.target = self
        workspaceSwitcher.action = #selector(selectWorkspace(_:))
        addSubview(workspaceSwitcher)
        exportButton.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Export")
        exportButton.imagePosition = .imageLeading
        exportButton.target = self
        exportButton.action = #selector(export)
        exportButton.isEnabled = exportEnabled
        configureToolbarButton(exportButton, title: "Export", symbol: "square.and.arrow.up", help: exportHelp, selected: true)
        exportButton.setAccessibilityLabel("Export photograph or selection")
        addSubview(exportButton)
        showAdjustmentsButton.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Show Adjustments")
        showAdjustmentsButton.imagePosition = .imageLeading
        showAdjustmentsButton.target = self
        showAdjustmentsButton.action = #selector(showAdjustments)
        configureToolbarButton(showAdjustmentsButton, title: "Adjustments", symbol: "slider.horizontal.3", help: "Reopen the right editing sidebar")
        showAdjustmentsButton.setAccessibilityLabel("Show Adjustments")
        showAdjustmentsButton.isHidden = true
        addSubview(showAdjustmentsButton)
        synchronizeWorkspaceSelection()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var title: String {
        get { name.stringValue }
        set { guard newValue != name.stringValue else { return }; name.stringValue = newValue; needsLayout = true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return showsStudioControls && (hit === workspaceSwitcher || hit === exportButton
            || (showsAdjustmentReopen && hit === showAdjustmentsButton)) ? hit : nil
    }

    @objc private func selectWorkspace(_ sender: NSSegmentedControl) {
        let requested: EditorWorkspace
        switch sender.selectedSegment {
        case 0: requested = .library
        case 1: requested = .editor
        default: return
        }
        let previousSelection = showingLibrary ? 0 : 1
        let transitionSucceeded = onSelectWorkspace?(requested) ?? false
        sender.selectedSegment = transitionSucceeded ? (requested == .library ? 0 : 1) : previousSelection
    }
    @objc private func export(_ sender: NSButton) { onExport?(sender) }
    @objc private func showAdjustments() { onShowAdjustments?() }
    override var mouseDownCanMoveWindow: Bool { true }

    private func configureToolbarButton(_ button: NSButton, title: String, symbol: String, help: String, selected: Bool = false) {
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.isBordered = true
        button.font = Theme.textFont(12, weight: 600) as NSFont
        button.toolTip = help
        button.bezelColor = selected ? Theme.NS.accent : Theme.NS.panel
        button.contentTintColor = selected ? Theme.NS.onAccent : Theme.NS.label
    }

    private func synchronizeWorkspaceSelection() {
        workspaceSwitcher.selectedSegment = showingLibrary ? 0 : 1
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // From the text itself: the label's own size can lag a new name.
        let text = name.attributedStringValue.size()
        let size = NSSize(width: ceil(text.width) + 4, height: ceil(text.height))
        // Level with the traffic lights, after the zoom button.
        var left = Self.fullScreenInset, middle = bounds.midY
        if let window, !window.styleMask.contains(.fullScreen), let zoom = window.standardWindowButton(.zoomButton),
           let close = window.standardWindowButton(.closeButton), zoom.superview != nil {
            left = convert(zoom.bounds, from: zoom).maxX + Self.gap
            middle = convert(close.bounds, from: close).midY
        }
        let switcherSize = workspaceSwitcher.fittingSize
        workspaceSwitcher.frame = NSRect(x: left.rounded(), y: (middle - switcherSize.height / 2).rounded(),
                                         width: switcherSize.width, height: switcherSize.height)
        let exportSize = exportButton.fittingSize
        exportButton.frame = NSRect(x: bounds.width - exportSize.width - Theme.Size.gutter,
                                    y: (bounds.midY - exportSize.height / 2).rounded(),
                                    width: exportSize.width, height: exportSize.height)
        let adjustmentsSize = showAdjustmentsButton.fittingSize
        showAdjustmentsButton.frame = NSRect(x: exportButton.frame.minX - adjustmentsSize.width - 8,
                                             y: (bounds.midY - adjustmentsSize.height / 2).rounded(),
                                             width: adjustmentsSize.width, height: adjustmentsSize.height)
        let titleLeft = showsStudioControls ? workspaceSwitcher.frame.maxX + 14 : left
        let nameMaxX = showsStudioControls
            ? (showsAdjustmentReopen ? showAdjustmentsButton.frame.minX : exportButton.frame.minX) - 16
            : bounds.width - Theme.Size.gutter
        let width = max(min(nameMaxX - titleLeft, bounds.width - titleLeft - Theme.Size.gutter), 0)
        name.frame = NSRect(x: titleLeft.rounded(), y: (middle - size.height / 2).rounded(), width: width, height: size.height)
    }
}
