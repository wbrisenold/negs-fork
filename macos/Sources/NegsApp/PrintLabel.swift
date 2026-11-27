import AppKit
import CoreText
import SwiftUI

/// Film, paper, and output choices live together in the develop rail. Keeping
/// them in a labeled control group leaves the photograph's caption clear.
struct PrintLabel: View {
    let model: EditorModel
    @Environment(\.sheetInk) private var ink

    var body: some View {
        let scanning = model.value("io.scan_film").bool
        let original = model.original != nil
        let kind = PrintLabelLayout.kind(scanning: scanning)
        let look = RenderLook(rawValue: model.value("io.render_look").string) ?? .referentOutput
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "camera.aperture").font(.system(size: 10, weight: .semibold))
                Text("STOCKS").font(Theme.ui(10, weight: .bold)).tracking(0.8)
                Spacer(minLength: 0)
                Text(scanning ? "SCAN" : "PRINT").font(Theme.ui(9, weight: .semibold)).tracking(0.5)
                    .foregroundStyle(ink.dim)
            }
            .foregroundStyle(ink.label)

            controlRow("FILM") {
                StockName(model: model, paper: false, name: model.filmName, size: 12.5, weight: 600,
                          strike: original ? .original : nil, opens: !original, compact: true)
            }
            controlRow("PAPER") {
                StockName(model: model, paper: true, name: model.paperName, size: 12.5, weight: 500,
                          strike: original ? .original : scanning ? .scanning : nil,
                          opens: !original && !scanning, compact: true)
            }
            if original {
                Text("Showing original · \(kind)")
                    .font(Theme.text(11, italic: true)).foregroundStyle(ink.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            controlRow("OUTPUT") {
                OutputLookMenu(model: model, selected: look, compact: true)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 11)
        .frame(width: Theme.Size.photoRail, alignment: .leading)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Film, paper, and output")
    }

    private func controlRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.ui(8.5, weight: .bold)).tracking(0.7).foregroundStyle(ink.dim)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The label's sizes and its one-or-two-rows rule, measured with the same
/// fonts the label draws with.
@MainActor enum PrintLabelLayout {
    /// Between the film and the paper on one row, and inside a name.
    static let gap: CGFloat = 9, inner: CGFloat = 7
    /// The space under the photograph: always two rows (§2.3).
    static let band: CGFloat = 68

    static func kind(scanning: Bool) -> String { scanning ? "not printed — scanning the film" : "printed on" }

    static func width(_ text: String, font: CTFont, tracking: CGFloat = 0) -> CGFloat {
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if tracking != 0 { attributes[.kern] = tracking }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        return ceil(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
    static var chevron: CGFloat { width("⌄", font: NSFont.systemFont(ofSize: 13)) + 1 }
    /// The film's name at 24 pt, 600, with its `⌄`.
    static func filmWidth(_ name: String) -> CGFloat {
        width(name, font: Theme.textFont(24, weight: 600), tracking: -0.24) + inner + chevron
    }
    /// "printed on", the paper's name at 17.5 pt and its `⌄`.
    static func paperWidth(_ name: String, kind: String) -> CGFloat {
        width(kind, font: Theme.textFont(14, italic: true)) + inner + width(name, font: Theme.textFont(17.5)) + inner + chevron
    }
    static func fitsOneRow(film: String, paper: String, kind: String, output: String? = nil, width: CGFloat) -> Bool {
        let outputWidth = output.map { gap + widthForOutput($0) } ?? 0
        return filmWidth(film) + gap + paperWidth(paper, kind: kind) + outputWidth <= width
    }

    static func widthForOutput(_ title: String) -> CGFloat {
        width(title, font: Theme.textFont(14, weight: 550)) + inner + chevron
    }
}

private enum RenderLook: String, CaseIterable, Identifiable {
    case original = "off"
    case acesSdrHillFit = "aces_sdr_hill_fit"
    case hncs = "hasselblad_hncs"
    case hncsPython = "hasselblad_hncs_python"
    case hncsSmooth = "hasselblad_hncs_smooth"
    case canonR5Population = "canon_r5_population"
    case referentOutput = "referent_output"
    case referentOutputHNCS = "referent_output_hncs_tone"
    case referentOutputHNCSSmooth = "referent_output_hncs_smooth_tone"

    var id: String { rawValue }
    var compactTitle: String {
        switch self {
        case .original: "Original Tone"
        case .acesSdrHillFit: "ACES SDR · Hill fit"
        case .hncs: "HNCS · Reference"
        case .hncsPython: "HNCS · Python"
        case .hncsSmooth: "HNCS · Smooth"
        case .canonR5Population: "Canon · Population fit (R5 included)"
        case .referentOutput: "Full Output"
        case .referentOutputHNCS: "Full Output + HNCS · Reference"
        case .referentOutputHNCSSmooth: "Full Output + HNCS · Smooth"
        }
    }
    var menuTitle: String {
        switch self {
        case .original: "Original Tone Mapper"
        case .acesSdrHillFit: "ACES SDR (Hill fit)"
        case .hncs: "HNCS Lightness Look · Reference (CLAHE)"
        case .hncsPython: "HNCS `apply_hncs()` Python Baseline"
        case .hncsSmooth: "HNCS Lightness Look · Smooth (no local contrast)"
        case .canonR5Population: "Canon Population Fit · pooled SOOC JPEGs (EOS R5 included; not RAW calibration)"
        case .referentOutput: "Referent Full Output Transform"
        case .referentOutputHNCS: "Referent Full Output + HNCS Tone · Reference (CLAHE)"
        case .referentOutputHNCSSmooth: "Referent Full Output + HNCS Tone · Smooth"
        }
    }
}

/// The selected render look stays in the preview workflow, alongside the
/// film and paper choices that determine the finished image.
private struct OutputLookMenu: View {
    let model: EditorModel
    let selected: RenderLook
    var compact = false
    @Environment(\.sheetInk) private var ink

    var body: some View {
        Menu {
            ForEach(RenderLook.allCases) { look in
                Button {
                    model.set("io.render_look", .string(look.rawValue))
                } label: {
                    if look == selected {
                        Label(look.menuTitle, systemImage: "checkmark")
                    } else {
                        Text(look.menuTitle)
                    }
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(selected.compactTitle).lineLimit(1).truncationMode(.tail)
                Text("⌄").font(.system(size: 13)).foregroundStyle(ink.dim)
            }
            .font(Theme.text(compact ? 11.5 : 14, weight: 550))
            .foregroundStyle(model.isModified("io.render_look") ? ink.accent : ink.paper)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, compact ? 8 : 0)
            .padding(.vertical, compact ? 7 : 0)
            .background { if compact { RoundedRectangle(cornerRadius: 6).fill(Theme.card) } }
            .overlay { if compact { RoundedRectangle(cornerRadius: 6).stroke(Theme.line, lineWidth: 1) } }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .help("Output transform: \(selected.menuTitle). Choose the look applied after the film scan.")
        .accessibilityLabel("Output transform")
        .accessibilityValue(selected.menuTitle)
    }
}

/// A stock name opens the fast grouped picker. A separate compare control
/// opens the slower image-preview tray when visual comparison is useful.
private struct StockName: View {
    enum Strike {
        /// Scanning the film: the paper is struck through at about half its height.
        case scanning
        /// Holding Original: both names are struck, higher up.
        case original
        var height: CGFloat { self == .scanning ? 0.54 : 0.34 }
        var width: CGFloat { self == .scanning ? 0.88 : 1 }
    }

    let model: EditorModel
    let paper: Bool
    let name: String
    let size: CGFloat
    let weight: CGFloat
    var strike: Strike?
    /// False while scanning (the paper) or holding Original: the name is only words.
    var opens = true
    var compact = false
    @State private var hovered = false
    @State private var anchor = MenuAnchor()
    @Environment(\.sheetInk) private var ink

    /// Its tray is open.
    private var open: Bool { model.tray?.paper == paper }
    private var guidance: String {
        (paper ? model.papers : model.films).first { $0.name == name }?.guidance
            ?? "Choose a \(paper ? "paper" : "film") stock."
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PrintLabelLayout.inner + 1) {
            if opens {
                Button(action: activate) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        stockName
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(ink.dim)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, compact ? 8 : 0)
                    .padding(.vertical, compact ? 6 : 0)
                    .background { if compact { RoundedRectangle(cornerRadius: 6).fill(Theme.card) } }
                    .overlay { if compact { RoundedRectangle(cornerRadius: 6).stroke(Theme.line, lineWidth: 1) } }
                    .contentShape(Rectangle())
                    .background(AnchorView(anchor: anchor))
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 }
                .help("\(name). \(guidance)")
                .accessibilityLabel("Choose \(paper ? "paper" : "film") stock")
                .accessibilityValue(name)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { activate() }
                if model.previews.enabled {
                    Button { model.toggleTray(paper: paper) } label: {
                        Image(systemName: "rectangle.split.2x1")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(open ? ink.accent : hovered ? ink.label : ink.dim)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Preview and compare \(paper ? "papers" : "films")")
                    .accessibilityLabel("Preview and compare \(paper ? "papers" : "films")")
                }
            } else {
                stockName.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
        // Clicks on the two stock controls stay inside the tray's focus scope.
        .background(TrayHitArea(model: model))
        .help(strike == .scanning ? "Not printed while scanning the film" : strike == .original ? "Showing the original" : "\(name). \(guidance)")
    }

    private var stockName: some View {
        Text(name)
            .font(Theme.text(size, weight: weight))
            .tracking(paper ? 0 : -0.24)
            .foregroundStyle(strike == nil ? ink.paper : ink.dim)
            .lineLimit(1).truncationMode(.tail)
            .padding(.bottom, compact ? 0 : 5)
            .overlay(alignment: .bottom) { underline }
            .overlay { if !compact { struck } }
    }

    @ViewBuilder private var underline: some View {
        if !compact, strike == nil {
            if open {
                PencilStroke().pencil(ink.accent).frame(height: 6).allowsHitTesting(false)
            } else if hovered {
                Rectangle().fill(ink.track).frame(height: 1.5).offset(y: -1).allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder private var struck: some View {
        if let strike {
            // As CSS places it: `left 54% / 88% 6px` over the name and its 5 pt below.
            GeometryReader { proxy in
                let width = proxy.size.width * strike.width
                PencilStroke().pencil(ink.accent)
                    .frame(width: width, height: 6)
                    .position(x: width / 2, y: (proxy.size.height - 6) * strike.height + 3)
            }
            .allowsHitTesting(false)
        }
    }

    private func activate() {
        let stocks = paper ? model.papers : model.listedFilms
        let groups = paper ? model.paperGroups : model.filmGroups
        let favorites = model.previews.favorites(in: stocks, paper: paper)
        var items: [ChoiceItem] = []
        if !favorites.isEmpty {
            items.append(.header("Favourites"))
            items += favorites.map { .stock($0.name, tag: StockMenu.favoriteID($0.id), help: $0.guidance) }
        }
        for group in groups {
            items.append(.header(group.title))
            items += group.stocks.map { .stock($0.name, tag: $0.id, help: $0.guidance) }
        }
        popUpChoiceMenu(items, selected: paper ? model.paper : model.film, under: anchor.view) { tag in
            let id = StockMenu.stockID(tag: tag)
            if paper { model.choosePaper(id) } else { model.chooseFilm(id) }
        }
    }
}
