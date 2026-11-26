import AppKit
import SwiftUI

enum Adjustment: Identifiable {
    case slider(String, String, ClosedRange<Double>, Double)
    case toggle(String, String)
    case choice(String, String, [String])
    /// One lane (index) of an engine array that stays null until edited, so
    /// the film's grain preset from the catalog applies. B&W films have one
    /// emulsion: they show the lane under `bw`, or hide it when that is nil.
    case stockSlider(String, String, Int, ClosedRange<Double>, Double, bw: String?)
    /// Keystone's 0...80 scale over Negs' normalized 0...1 engine parameter.
    case silverRetention
    /// A button that solves for parameters: title, help.
    case balancePrint(String, String)
    /// How the enlarger's magenta and yellow shifts move each other: help.
    case filterLink(String)

    /// Why an adjustment is unavailable in the current workflow. The value
    /// remains in the edit state; availability only controls interaction.
    func unavailableReason(filmIsBW: Bool, scanningFilm: Bool) -> String? {
        switch self {
        case .stockSlider(_, _, _, _, _, let bwTitle) where filmIsBW && bwTitle == nil:
            return "This grain channel is only available with color film."
        case .silverRetention where scanningFilm:
            return "Silver retention applies to a negative, not a scan of film."
        case .silverRetention where filmIsBW:
            return "Silver retention is unavailable with black-and-white film."
        default:
            return nil
        }
    }

    var id: String {
        switch self {
        case .slider(_, let path, _, _), .toggle(_, let path), .choice(_, let path, _): return path
        case .stockSlider(_, let path, let index, _, _, _): return "\(path).\(index)"
        case .silverRetention: return "film_render.silver_retention"
        case .balancePrint(let title, _): return title
        case .filterLink: return FilterLink.key
        }
    }
}

enum InspectorSection: String, CaseIterable {
    case camera = "Camera", film = "Film", print = "Print", scan = "Scan & Color"
}

/// Prepare the photograph, develop the film, then finish the scan.
enum InspectorTab: String, CaseIterable {
    case exposure = "Light", color = "Color", lab = "Film", mask = "Masks", output = "Export"

    var title: String {
        switch self {
        case .exposure: "Light"
        case .color: "Color"
        case .lab: "Film"
        case .mask: "Masks"
        case .output: "Export"
        }
    }

    var symbol: String {
        switch self {
        case .exposure: "sun.max"
        case .color: "slider.horizontal.3"
        case .lab: "camera.macro"
        case .mask: "person.crop.rectangle"
        case .output: "square.and.arrow.up"
        }
    }

    /// Reading and keyboard order shared by the visible tab row and focus loop.
    static let focusOrder = allCases

    /// The task tabs use Command-Option-number, leaving the existing menu
    /// routes (including Command-Option-I/P) unchanged.
    var shortcutKey: String { String(ordinal) }

    private var ordinal: Int { Self.focusOrder.firstIndex(of: self)! + 1 }
    var shortcutModifiers: EventModifiers { [.command, .option] }
    var accessibilityName: String { title }
    var accessibilityHint: String { "Show \(title) adjustments (Command-Option-\(shortcutKey))" }
    func accessibilityLabel(editCount: Int) -> String {
        editCount > 0 ? "\(title), \(editCount) \(editCount == 1 ? "edit" : "edits")" : title
    }
    func accessibilityValue(isSelected: Bool, editCount: Int) -> String {
        let state = isSelected ? "Selected" : "Not selected"
        guard editCount > 0 else { return state }
        return "\(state), \(editCount) \(editCount == 1 ? "edit" : "edits")"
    }
}

let prepToneControls: [Adjustment] = [
    .slider("Highlights", "prep.highlights", -180...100, 1),
    .slider("Shadows", "prep.shadows", -100...100, 1),
    .slider("Contrast", "prep.contrast", -100...100, 1),
    .slider("Lift", "prep.lift", -100...100, 1),
    .slider("Gain", "prep.gain", -100...100, 1)
]
let prepColorControls: [Adjustment] = [
    .slider("Color Boost", "prep.color_boost", -100...100, 1),
    .slider("Saturation", "prep.saturation", -100...100, 1)
]
let prepDetailControls: [Adjustment] = [
    .slider("Midtone Detail", "prep.midtone_detail", -100...100, 1)
]

struct AdjustmentGroup: Identifiable {
    let title: String
    let symbol: String
    let section: InspectorSection
    /// Switches the whole effect on and off from the group's header.
    var enable: String?
    /// How many of the leading controls the Lab shows without Show all
    /// controls; a group with none shows only then (or once it's changed).
    var basic = 0
    let controls: [Adjustment]
    var id: String { title }
}

let adjustmentGroups: [AdjustmentGroup] = [
    .init(title: "Lens Diffusion", symbol: "camera.filters", section: .camera, enable: "camera.diffusion_filter.active", basic: 2, controls: [
        .choice("Filter", "camera.diffusion_filter.filter_family", ["black_pro_mist", "glimmerglass", "pro_mist", "cinebloom"]),
        .slider("Strength", "camera.diffusion_filter.strength", 0...2, 0.01),
        .slider("Spatial scale", "camera.diffusion_filter.spatial_scale", 0.1...3, 0.01),
        .slider("Halo warmth", "camera.diffusion_filter.halo_warmth", -1.5...1.5, 0.01),
        .slider("Core intensity", "camera.diffusion_filter.core_intensity", 0...2, 0.01),
        .slider("Halo intensity", "camera.diffusion_filter.halo_intensity", 0...2, 0.01),
        .slider("Bloom intensity", "camera.diffusion_filter.bloom_intensity", 0...2, 0.01),
        .slider("Halo size", "camera.diffusion_filter.halo_size", 0.1...3, 0.01),
        .slider("Bloom size", "camera.diffusion_filter.bloom_size", 0.1...3, 0.01)
    ]),
    .init(title: "Film Curves", symbol: "chart.xyaxis.line", section: .film, enable: "film_render.density_curves_morph.active", basic: 1, controls: [
        .slider("Gamma", "film_render.density_curves_morph.gamma_factor", 0.5...2, 0.01),
        .slider("Fast gamma", "film_render.density_curves_morph.gamma_factor_fast", 0.5...2, 0.01),
        .slider("Slow gamma", "film_render.density_curves_morph.gamma_factor_slow", 0.5...2, 0.01),
        .slider("Red gamma", "film_render.density_curves_morph.gamma_factor_red", 0.5...2, 0.01),
        .slider("Green gamma", "film_render.density_curves_morph.gamma_factor_green", 0.5...2, 0.01),
        .slider("Blue gamma", "film_render.density_curves_morph.gamma_factor_blue", 0.5...2, 0.01),
        .slider("Developer exhaustion", "film_render.density_curves_morph.developer_exhaustion", 0...1, 0.01)
    ]),
    .init(title: "Grain", symbol: "circle.dotted", section: .film, enable: "film_render.grain.active", basic: 3, controls: [
        .stockSlider("Red granularity", "film_render.grain.rms_granularity", 0, 0...80, 0.1, bw: "Granularity"),
        .stockSlider("Green granularity", "film_render.grain.rms_granularity", 1, 0...80, 0.1, bw: nil),
        .stockSlider("Blue granularity", "film_render.grain.rms_granularity", 2, 0...80, 0.1, bw: nil),
        .stockSlider("Red uniformity", "film_render.grain.uniformity", 0, 0...1, 0.01, bw: "Uniformity"),
        .stockSlider("Green uniformity", "film_render.grain.uniformity", 1, 0...1, 0.01, bw: nil),
        .stockSlider("Blue uniformity", "film_render.grain.uniformity", 2, 0...1, 0.01, bw: nil),
        .stockSlider("Coarse grain size", "film_render.grain.particle_scale_sublayers", 0, 0.05...2, 0.01, bw: "Coarse grain size"),
        .stockSlider("Medium grain size", "film_render.grain.particle_scale_sublayers", 1, 0.05...2, 0.01, bw: "Medium grain size"),
        .stockSlider("Fine grain size", "film_render.grain.particle_scale_sublayers", 2, 0.05...2, 0.01, bw: "Fine grain size"),
        .slider("Dye clouds (µm)", "film_render.grain.blur_dye_clouds_um", 0...5, 0.01),
        .slider("Blur (px)", "film_render.grain.blur", 0...3, 0.01),
        .slider("Sharpen amount", "film_render.grain.mult_usm_amount", 0...3, 0.01),
        .slider("Sharpen radius (px)", "film_render.grain.mult_usm_sigma", 0...3, 0.01),
        .slider("Clump blur (µm)", "film_render.grain.micro_structure.0", 0...1, 0.01),
        .slider("Clump size (nm)", "film_render.grain.micro_structure.1", 0...100, 1)
    ]),
    .init(title: "Halation", symbol: "sun.haze", section: .film, enable: "film_render.halation.active", basic: 1, controls: [
        .slider("Amount", "film_render.halation.halation_amount", 0...3, 0.01),
        .slider("Spatial scale", "film_render.halation.halation_spatial_scale", 0.1...5, 0.01),
        .slider("Scatter amount", "film_render.halation.scatter_amount", 0...3, 0.01),
        .slider("Scatter scale", "film_render.halation.scatter_spatial_scale", 0.1...5, 0.01),
        .slider("Bounces", "film_render.halation.halation_n_bounces", 1...5, 1),
        .slider("Bounce decay", "film_render.halation.halation_bounce_decay", 0...1, 0.01)
    ]),
    .init(title: "DIR Couplers", symbol: "circle.hexagongrid", section: .film, enable: "film_render.dir_couplers.active", basic: 1, controls: [
        .slider("Amount", "film_render.dir_couplers.amount", 0...2, 0.01),
        .slider("Diffusion (µm)", "film_render.dir_couplers.diffusion_size_um", 0...100, 0.1),
        .slider("Tail (µm)", "film_render.dir_couplers.diffusion_tail_um", 0...400, 1),
        .slider("Tail weight", "film_render.dir_couplers.diffusion_tail_weight", 0...1, 0.01)
    ]),
    .init(title: "Film Base", symbol: "square.stack.3d.down.right", section: .film, enable: "film_render.base.active", basic: 1, controls: [
        .slider("Density", "film_render.base.scale", 0...2, 0.01),
        .slider("Tilt", "film_render.base.tilt", -1...1, 0.01),
        .slider("Cyan", "film_render.base.cyan", 0...2, 0.01),
        .slider("Magenta", "film_render.base.magenta", 0...2, 0.01),
        .slider("Yellow", "film_render.base.yellow", 0...2, 0.01)
    ]),
    .init(title: "Enlarger", symbol: "light.overhead.left", section: .print, basic: 5, controls: [
        .slider("Print exposure", "enlarger.print_exposure", 0.1...5, 0.01),
        .slider("Magenta shift", "enlarger.m_filter_shift", -50...50, 0.1),
        .slider("Yellow shift", "enlarger.y_filter_shift", -50...50, 0.1),
        .filterLink("How the magenta and yellow shifts move. Together moves both the same way: more of both makes the print more cyan, less of both redder. Opposite ways moves one up as the other goes down. Linked, resetting either resets both. Each keeps its own value, so presets are unchanged."),
        .balancePrint("Balance Print", "Sets the magenta and yellow shifts so a mid-grey prints neutral with the current film, bases, paper and enlarger. Use it after changing the film base."),
        .toggle("Exposure compensation", "enlarger.print_exposure_compensation"),
        .slider("Preflash exposure", "enlarger.preflash_exposure", 0...0.5, 0.01),
        .slider("Preflash magenta", "enlarger.preflash_m_filter_shift", -50...50, 0.1),
        .slider("Preflash yellow", "enlarger.preflash_y_filter_shift", -50...50, 0.1)
    ]),
    .init(title: "Print Curves", symbol: "chart.xyaxis.line", section: .print, enable: "print_render.density_curves_morph.active", basic: 1, controls: [
        .slider("Gamma", "print_render.density_curves_morph.gamma_factor", 0.5...2, 0.01),
        .slider("Fast gamma", "print_render.density_curves_morph.gamma_factor_fast", 0.5...2, 0.01),
        .slider("Slow gamma", "print_render.density_curves_morph.gamma_factor_slow", 0.5...2, 0.01),
        .slider("Red gamma", "print_render.density_curves_morph.gamma_factor_red", 0.5...2, 0.01),
        .slider("Green gamma", "print_render.density_curves_morph.gamma_factor_green", 0.5...2, 0.01),
        .slider("Blue gamma", "print_render.density_curves_morph.gamma_factor_blue", 0.5...2, 0.01),
        .slider("Developer exhaustion", "print_render.density_curves_morph.developer_exhaustion", 0...1, 0.01)
    ]),
    .init(title: "Print Base", symbol: "square.stack.3d.down.right", section: .print, enable: "print_render.base.active", basic: 1, controls: [
        .slider("Density", "print_render.base.scale", 0...2, 0.01),
        .slider("Cyan", "print_render.base.cyan", 0...2, 0.01),
        .slider("Magenta", "print_render.base.magenta", 0...2, 0.01),
        .slider("Yellow", "print_render.base.yellow", 0...2, 0.01)
    ]),
    .init(title: "Glare", symbol: "light.max", section: .print, enable: "print_render.glare.active", basic: 1, controls: [
        .slider("Amount", "print_render.glare.percent", 0...0.2, 0.001),
        .slider("Roughness", "print_render.glare.roughness", 0...2, 0.01),
        .slider("Blur (px)", "print_render.glare.blur", 0...5, 0.01)
    ]),
    .init(title: "Sharpening", symbol: "viewfinder", section: .scan, basic: 3, controls: [
        .slider("Amount", "scanner.unsharp_mask.1", 0...2, 0.01),
        .slider("Radius (px)", "scanner.unsharp_mask.0", 0...3, 0.01),
        .slider("Noise threshold", "scanner.unsharp_threshold", 0...0.08, 0.001)
    ]),
    .init(title: "Scanner", symbol: "scanner", section: .scan, controls: [
        .slider("Lens blur (px)", "scanner.lens_blur", 0...5, 0.01),
        .toggle("White correction", "scanner.white_correction"),
        .slider("White level", "scanner.white_level", 0.5...1, 0.01),
        .toggle("Black correction", "scanner.black_correction"),
        .slider("Black level", "scanner.black_level", 0...0.5, 0.01)
    ]),
    .init(title: "Color Management", symbol: "paintpalette", section: .scan, controls: [
        .choice("Output gamut", "io.output_gamut_compress.algorithm", ["off", "oklch", "oklrab", "cam16ucs", "aces_rgc"]),
        .choice("Input gamut", "io.input_gamut_compress.algorithm", ["off", "xy"]),
        .toggle("CAT16 spectral conversion", "settings.use_cat16"),
        .choice("Spectral upsampling", "settings.rgb_to_raw_method", ["hanatos2025", "arctic2026beta04", "mallett2019"])
    ])
]

// MARK: Rows for the adjustments

struct AdjustmentControl: View {
    let model: EditorModel
    let adjustment: Adjustment

    var body: some View {
        switch adjustment {
        case .toggle(let title, let path):
            TickRow(title: title, isOn: model.toggle(path), changed: model.isModified(path), help: ControlHelp.text(path))
                .resettable(model, path)
        case .choice(let title, let path, let options):
            ChoiceRow(title: title, items: options.map { .option(optionTitle($0), tag: $0) }, selection: model.value(path).string,
                      changed: model.isModified(path), help: ControlHelp.text(path)) { model.set(path, .string($0)) }
                .resettable(model, path)
        case .slider(let title, let path, let range, let step):
            SliderRow(model: model, title: title, path: path, range: range, step: step)
        case .stockSlider(let title, let path, let index, let range, let step, let bwTitle):
            let reason = adjustment.unavailableReason(filmIsBW: model.filmIsBW, scanningFilm: model.value("io.scan_film").bool)
            VStack(alignment: .leading, spacing: 0) {
                LabeledSlider(title: model.filmIsBW ? bwTitle ?? title : title,
                              value: model.stockNumber(path, index, range: range, step: step), range: range, step: step,
                              defaultValue: model.stockDefault(path, index), modified: model.isStockModified(path, index),
                              reset: { model.resetStock(path, index) },
                              editing: { $0 ? model.beginInteraction() : model.endInteraction() },
                              help: reason ?? ControlHelp.text(path))
                    .disabled(reason != nil)
                    .opacity(reason == nil ? 1 : Theme.disabledOpacity)
                if let reason { UnavailableAdjustmentNote(reason: reason) }
            }
        case .silverRetention:
            let path = "film_render.silver_retention"
            let reason = adjustment.unavailableReason(filmIsBW: model.filmIsBW, scanningFilm: model.value("io.scan_film").bool)
            VStack(alignment: .leading, spacing: 0) {
                LabeledSlider(title: "Silver retention",
                              value: Binding(get: { model.value(path).double * 80 },
                                             set: { model.set(path, .number(min(max($0, 0), 80) / 80)) }),
                              range: 0...80, step: 1, defaultValue: 0, modified: model.isModified(path),
                              reset: { model.resetValue(path) },
                              editing: { $0 ? model.beginInteraction() : model.endInteraction() },
                              help: reason ?? ControlHelp.text(path))
                    .disabled(reason != nil)
                    .opacity(reason == nil ? 1 : Theme.disabledOpacity)
                if let reason { UnavailableAdjustmentNote(reason: reason) }
            }
        case .balancePrint(let title, let help):
            HStack {
                Spacer()
                Button { model.balancePrint() } label: {
                    if model.balancingPrint {
                        VStack(spacing: 2) {
                            Text("Balancing").italic()
                            RunningLine().frame(width: 44)
                        }
                    } else {
                        Text(title)
                    }
                }
                .buttonStyle(OutlinedButtonStyle())
                .disabled(!model.canBalancePrint)
                .inkFocus(activate: { if model.canBalancePrint { model.balancePrint() } })
                .help(help)
            }
            .padding(.horizontal, Theme.Size.gutter)
            .padding(.vertical, 4)
        case .filterLink(let help):
            ChoiceRow(title: "Shifts move", items: FilterLink.allCases.map { .option($0.title, tag: $0.rawValue) },
                      selection: model.filterLink.rawValue, help: help) { model.filterLink = FilterLink(rawValue: $0) ?? .separate }
        }
    }
}

private struct UnavailableAdjustmentNote: View {
    let reason: String

    var body: some View {
        Text(reason)
            .font(Theme.ui(10))
            .foregroundStyle(Theme.dim)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Size.gutter)
            .padding(.bottom, 4)
            .accessibilityLabel("Unavailable. \(reason)")
    }
}

struct SliderRow: View {
    let model: EditorModel
    let title: String
    let path: String
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        let linked = path == FilterLink.magenta || path == FilterLink.yellow
        LabeledSlider(title: title, value: linked ? model.filterShift(path, step: step) : model.number(path, range: range, step: step),
                      range: range, step: step,
                      defaultValue: model.defaultValue(path).double, modified: model.isModified(path),
                      reset: { linked ? model.resetFilterShift(path) : model.resetValue(path) },
                      editing: { $0 ? model.beginInteraction() : model.endInteraction() },
                      help: ControlHelp.text(path),
                      resetAfterClick: linked ? { model.resetFilterShiftAfterClick(path) } : nil)
    }
}

/// Rows a choice reveals: indented under it, on a 1 pt `track` rule (§4.9).
struct RevealedRows<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                Rectangle().fill(Theme.track).frame(width: 1).padding(.leading, Theme.Size.gutter).padding(.vertical, 4)
            }
    }
}

/// The film frame as a stills format, which writes the frame's long edge in
/// mm; Custom shows the slider. A value no format has reads as Custom, so
/// presets and older edits need no setting of their own.
struct FilmFormatPicker: View {
    let model: EditorModel
    static let path = "camera.film_format_mm"
    static let range: ClosedRange<Double> = 4...120
    /// Long edges of the image area. 135 stays at the engine's 35 (not the
    /// gate's 36) so existing edits render as before; 6×4.5 and 6×6 share 56.
    static let formats: [(name: String, mm: Double)] = [
        ("110", 17), ("Half frame", 24), ("35 mm (135)", 35),
        ("6×4.5 / 6×6", 56), ("6×7", 70), ("6×9", 84), ("4×5", 120),
    ]
    static func format(mm: Double) -> String? { formats.first { abs($0.mm - mm) < 0.05 }?.name }
    private static let custom = "Custom"

    var body: some View {
        let mm = model.value(Self.path).double
        let custom = model.customFilmFormat || Self.format(mm: mm) == nil
        let items: [ChoiceItem] = Self.formats.map { .option($0.name, tag: $0.name) } + [.divider, .option("Custom…", tag: Self.custom)]
        ChoiceRow(title: "Film format", items: items, selection: custom ? Self.custom : Self.format(mm: mm) ?? Self.custom,
                  changed: model.isModified(Self.path), help: ControlHelp.text(Self.path)) { name in
            if let format = Self.formats.first(where: { $0.name == name }) {
                model.customFilmFormat = false
                model.set(Self.path, .number(format.mm))
            } else {
                model.customFilmFormat = true
            }
        }
        if custom {
            RevealedRows { SliderRow(model: model, title: "Long edge (mm)", path: Self.path, range: Self.range, step: 0.1) }
        }
    }
}

/// The short running line that says work is under way: a 1 pt `track` line
/// with a yellow segment crossing it every 1.1 s (§4.14).
struct RunningLine: View {
    @State private var phase = false
    /// With Reduce Motion the segment stands still, a third of the way along.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.track).frame(height: 1)
                Rectangle().fill(Theme.accent).frame(width: width * 0.3, height: 1)
                    .offset(x: reduceMotion ? width * 0.3 : phase ? width : -width * 0.3)
            }
            .clipped()
        }
        .frame(height: 1)
        .onAppear { if !reduceMotion { withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { phase = true } } }
        .accessibilityHidden(true)
    }
}

/// Image Size, in Output: the photograph's resolution before the film
/// develops it. Reads only its own parameters, the crop and the source's
/// size, so other edits don't redraw it.
struct ImageSizeSection: View {
    let model: EditorModel
    @State private var fieldError: String?

    var body: some View {
        let params: JSONValue = .object(["io": .object(["photo_long_side_px": model.value(ImageSize.targetPath)])])
        let mode = ImageSize.mode(of: params)
        let source = model.sourceSize
        let working = source == .zero ? CGSize.zero : ImageSize.working(source: source, params: params, crop: model.crop)
        let photograph = model.crop.size(of: working)
        InkSection(title: "Image Size", edited: model.isModified(ImageSize.targetPath)) {
            ChoiceRow(title: "Size", items: [.option("Original", tag: ImageSize.Mode.original.rawValue), .option("Longest side", tag: ImageSize.Mode.longestSide.rawValue)],
                      selection: mode.rawValue, changed: mode != .original,
                      help: "Original develops the photograph’s own pixels. Longest side enlarges or reduces it first, so the cropped photograph has that many pixels on its longest side.") {
                fieldError = nil
                model.chooseImageSize(ImageSize.Mode(rawValue: $0) ?? .original)
            }
            if mode == .longestSide {
                RevealedRows {
                    NumberRow(title: "Longest side", unit: "px", error: fieldError != nil,
                              help: "The cropped photograph’s longest side, before any border. Exports can still be reduced in the save panel.") {
                        PixelField(title: "Longest side", value: ImageSize.target(of: params) ?? 0, error: fieldError != nil) { pixels in
                            fieldError = model.setLongestSide(pixels)
                            return fieldError == nil
                        }
                    }
                    if let fieldError { HintText(fieldError, warning: true) }
                }
            }
            // Verbatim, so pixel counts read like the status bar's, without grouping.
            ReadoutRow(title: "Photograph", value: photograph == .zero ? "—" : "\(Int(photograph.width)) × \(Int(photograph.height)) · \(ImageSize.megapixels(photograph)) MP",
                       help: "The exported photograph, cropped, before rotation, the border, and any export size.")
            if ImageSize.exceedsLimit(working: working, source: source) {
                HintText(ImageSize.limitMessage(working: working), warning: true)
            } else if model.previewScale < 1, model.image != nil {
                HintText("The preview shows \(EditorModel.percent(model.previewScale)) of these pixels. Exports develop all of them; inspect grain in an exported file.")
            }
            HintText("Resizes before film simulation, including halation and grain.")
        }
    }
}

/// A number field's row: the label, then the field on a rule and its unit
/// in italic `dim` (§4.9).
struct NumberRow<Field: View>: View {
    let title: String
    let unit: String
    var error = false
    var help: String? = nil
    @ViewBuilder let field: Field

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            RowLabel(title: title)
            Spacer(minLength: 8)
            field.frame(minWidth: 78, maxWidth: 96).frame(height: 20)
            Text(unit).font(Theme.text(13, italic: true)).foregroundStyle(Theme.dim)
        }
        .padding(.horizontal, Theme.Size.gutter)
        .frame(height: Theme.Size.row)
        .tooltip(help)
    }
}

/// A whole number of pixels, committed on Return or when focus leaves. An
/// invalid value stays in the field until corrected; Escape restores the
/// current one. AppKit, like `ValueField`, so the inspector column can
/// focus it. The serif on a rule: `track`, `paper` while typing, `warn`
/// when the number can't be used.
struct PixelField: NSViewRepresentable {
    let title: String
    let value: Int
    var error = false
    /// Applies a typed value; false keeps the typing for correction.
    let commit: (Int) -> Bool

    func makeNSView(context: Context) -> RuledField {
        let field = RuledField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Theme.textFont(14.5) as NSFont
        field.textColor = Theme.NS.paper
        field.alignment = .right
        field.setAccessibilityLabel(title)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: RuledField, context: Context) {
        context.coordinator.parent = self
        field.error = error
        if field.currentEditor() == nil, !context.coordinator.rejected { field.stringValue = "\(value)" }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PixelField
        /// The field holds a value that wasn't applied.
        var rejected = false
        init(_ parent: PixelField) { self.parent = parent }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            rejected = false
            (control as? NSTextField)?.stringValue = "\(parent.value)"
            control.window?.makeFirstResponder(nil)
            return true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
            guard text != "\(parent.value)" || rejected else { return }
            rejected = !parent.commit(Int(text) ?? -1)
        }
    }
}

/// A borderless text field on a 1 pt rule: `track`, `paper` while it has the
/// keys, `warn` while its text can't be used; caret and selection never blue.
final class RuledField: NSTextField {
    var error = false { didSet { if error != oldValue { needsDisplay = true } } }
    private var editing = false { didSet { needsDisplay = true } }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            editing = true
            if let editor = currentEditor() as? NSTextView { InkTextField.style(editor) }
        }
        return became
    }
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        editing = false
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        (error ? Theme.NS.warn : editing ? Theme.NS.paper : Theme.NS.track).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

/// A colour: a 14 pt swatch in a `track` ring, then its name; a click opens
/// the macOS Colours panel (§4.9).
struct ColourWellRow: View {
    let title: String
    let color: Binding<CGColor>
    var help: String? = nil
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            RowLabel(title: title, bright: hovered)
            Spacer(minLength: 8)
            Circle().fill(Color(cgColor: color.wrappedValue)).frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(Theme.track, lineWidth: 1))
            Text(Self.name(color.wrappedValue)).font(Theme.text(14.5)).foregroundStyle(Theme.paper)
        }
        .padding(.horizontal, Theme.Size.gutter)
        .frame(height: Theme.Size.row)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: open)
        .inkFocus(activate: open)
        .tooltip(help)
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue(Self.name(color.wrappedValue))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
    }

    private func open() { ColourPanelLink.shared.open(color.wrappedValue, title: title) { color.wrappedValue = $0 } }

    /// White, Black, or the colour's hex code.
    static func name(_ color: CGColor) -> String {
        let hex = BorderColor(color).hex.uppercased()
        switch hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")) {
        case "FFFFFF": return "White"
        case "000000": return "Black"
        default: return hex.hasPrefix("#") ? hex : "#" + hex
        }
    }
}

/// Points the shared Colours panel at one colour well at a time.
@MainActor final class ColourPanelLink: NSObject {
    static let shared = ColourPanelLink()
    private var set: ((CGColor) -> Void)?

    func open(_ color: CGColor, title: String, set: @escaping (CGColor) -> Void) {
        let panel = NSColorPanel.shared
        self.set = nil
        panel.showsAlpha = false
        panel.color = NSColor(cgColor: color) ?? .white
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.title = title
        self.set = set
        panel.orderFront(nil)
    }
    @objc private func changed(_ panel: NSColorPanel) { set?(panel.color.cgColor) }
}

extension View {
    /// A native tooltip, or none.
    @ViewBuilder func tooltip(_ text: String?) -> some View {
        if let text { help(text) } else { self }
    }
}

private extension View {
    func resettable(_ model: EditorModel, _ path: String) -> some View {
        contextMenu {
            Button("Reset to Default") { model.resetValue(path) }.disabled(!model.isModified(path))
        }
    }
}

// MARK: What the Lab shows

/// Which controls the Lab keeps back (round 11, B). Each module shows its
/// first `basic` controls; the rest wait behind "N more", as do the expert
/// modules of each section. View › Show All Controls shows everything, and
/// a control that is off its default always shows.
struct InspectorReveal: Equatable {
    /// View › Show All Controls.
    var all: Bool
    /// The modules (by title) and sections ("section:Print") whose "N more" was clicked.
    var revealed: Set<String>

    init(all: Bool, revealed: Set<String> = []) { self.all = all; self.revealed = revealed }
    /// From the comma-separated default.
    init(all: Bool, stored: String) { self.init(all: all, revealed: Set(stored.split(separator: ",").map(String.init))) }

    static func sectionKey(_ section: InspectorSection) -> String { "section:" + section.rawValue }
    /// The default's new value once `key`'s "N more" is clicked.
    func revealing(_ key: String) -> String { revealed.union([key]).sorted().joined(separator: ",") }
    /// The default's new value once `key`'s "Hide" is clicked: it folds back.
    func concealing(_ key: String) -> String { revealed.subtracting([key]).sorted().joined(separator: ",") }

    func shows(section: InspectorSection) -> Bool { all || revealed.contains(Self.sectionKey(section)) }
    /// Whether a section's "N more" was clicked, so its end offers to hide
    /// them again. Not under Show All Controls: the menu item undoes that.
    func folds(section: InspectorSection) -> Bool { !all && revealed.contains(Self.sectionKey(section)) }
    /// How many of a module's controls its "Hide" line would fold away:
    /// those past the basics that are at their defaults, once it was revealed.
    func foldable(_ group: AdjustmentGroup, visible: [Adjustment], isModified: (Adjustment) -> Bool) -> Int {
        guard !all, revealed.contains(group.title) else { return 0 }
        let basics = Set(group.controls.prefix(group.basic).map(\.id))
        return visible.filter { !basics.contains($0.id) && !isModified($0) }.count
    }
    /// A module shows when it has basics, its section's extras are revealed, or something in it changed.
    func shows(_ group: AdjustmentGroup, edits: Int) -> Bool { group.basic > 0 || shows(section: group.section) || edits > 0 }
    /// A module's controls: its basics, then the rest once revealed, or any changed.
    func controls(_ group: AdjustmentGroup, isModified: (Adjustment) -> Bool) -> [Adjustment] {
        let every = all || revealed.contains(group.title)
        return group.controls.enumerated().filter { every || $0.offset < group.basic || isModified($0.element) }.map(\.element)
    }
    /// "2 more: Scanner, Color Management", or nil when nothing is kept back.
    static func moreText(_ hidden: [String]) -> String? {
        hidden.isEmpty ? nil : "\(hidden.count) more: \(hidden.joined(separator: ", "))"
    }
    /// "Hide Scanner, Color Management", the same line folded back; nil when
    /// everything it opened has changed and so shows anyway.
    static func hideText(_ shown: [String]) -> String? {
        shown.isEmpty ? nil : "Hide \(shown.joined(separator: ", "))"
    }
}

extension AdjustmentInspector {
    /// View › Show All Controls. Returns the new state.
    @discardableResult static func toggleAllControls(in defaults: UserDefaults = .standard) -> Bool {
        let on = !defaults.bool(forKey: allControlsKey)
        defaults.set(on, forKey: allControlsKey)
        return on
    }
}

// MARK: Counting edits

/// What each tab holds, for the dots and counts on the tabs, sections and
/// modules (§4.8): every control that differs from its default.
@MainActor enum InspectorEdits {
    static func isModified(_ adjustment: Adjustment, _ model: EditorModel) -> Bool {
        switch adjustment {
        case .slider(_, let path, _, _), .toggle(_, let path), .choice(_, let path, _): model.isModified(path)
        case .stockSlider(_, let path, let index, _, _, _): model.isStockModified(path, index)
        case .silverRetention: model.isModified("film_render.silver_retention")
        case .balancePrint, .filterLink: false
        }
    }
    static func count(_ group: AdjustmentGroup, _ model: EditorModel) -> Int {
        (group.enable.map(model.isModified) == true ? 1 : 0) + group.controls.filter { isModified($0, model) }.count
    }
    static func count(_ section: InspectorSection, _ model: EditorModel) -> Int {
        var count = adjustmentGroups.filter { $0.section == section }.map { Self.count($0, model) }.reduce(0, +)
        switch section {
        case .camera: count += ["camera.exposure_compensation_ev", FilmFormatPicker.path, "camera.lens_blur_um"].filter(model.isModified).count
        case .film: count += model.isModified(filmDevelopmentPath) ? 1 : 0
        case .print: count += (scanFilmModified(model) ? 1 : 0) + (model.isModified(printDevelopmentPath) ? 1 : 0)
        case .scan: count += outputCount(model)
        }
        return count
    }
    static let filmDevelopmentPath = "film_render.development_time", printDevelopmentPath = "print_render.development_time"
    /// "Profile default", then each time the stock was measured at.
    static func developmentItems(_ stock: Stock) -> [ChoiceItem] {
        [.option("Profile default", tag: "")] + stock.times.map { .option("\($0.formatted()) min", tag: "\($0)") }
    }
    /// The menu tag for a development time: empty for the profile's default (null or 0).
    static func developmentTag(_ value: JSONValue) -> String {
        let minutes = value.double
        return value == .null || minutes == 0 ? "" : "\(minutes)"
    }
    static func scanFilmModified(_ model: EditorModel) -> Bool {
        model.value("io.scan_film").bool != (model.films.first { $0.id == model.film }?.positive ?? false)
    }
    static func outputCount(_ model: EditorModel) -> Int {
        (model.previewSpace != SaveSettings.colorSpaces[0] ? 1 : 0) + (model.isModified("io.output_cctf_encoding") ? 1 : 0)
    }

    static let whiteBalancePaths = ["io.raw_white_balance.mode", "io.raw_white_balance.temperature", "io.raw_white_balance.tint", "io.raw_white_balance.method", "io.raw_white_balance.camera_preset", "io.raw_white_balance.camera_tuning"]
    static let inputPaths = ["io.input_interpretation.mode", "io.input_interpretation.color_space", "io.input_interpretation.linear",
                             "io.input_color_space", "io.input_cctf_decoding"]
    static func brightnessCount(_ model: EditorModel) -> Int {
        (model.matchesBrightness != model.autoPlaceNewImages ? 1 : 0) + (model.exposureOffsetModified ? 1 : 0)
            + ["camera.auto_exposure", "camera.auto_exposure_method"].filter(model.isModified).count
    }
    static func prepCount(_ model: EditorModel) -> Int {
        var count = brightnessCount(model)
        count += (prepToneControls + prepDetailControls).filter { isModified($0, model) }.count
        if model.isModified("film_render.silver_retention") { count += 1 }
        return count
    }
    static func whiteBalanceCount(_ model: EditorModel) -> Int {
        var count = whiteBalancePaths.filter(model.isModified).count
        if model.isRaw {
            if model.lensCorrectionSupported, model.isModified(EditorModel.lensCorrectionPath) { count += 1 }
        } else {
            count += inputPaths.filter(model.isModified).count
            count += ["prep.color_correction_offset"].filter(model.isModified).count
        }
        return count
    }
    static func labCount(_ model: EditorModel) -> Int {
        InspectorSection.allCases.filter { $0 != .scan }.map { count($0, model) }.reduce(0, +)
    }
    static func colorCount(_ model: EditorModel) -> Int {
        let separation = ["strength", "target_hue", "complementary_hue", "target_saturation", "luminance_mask", "neutral_protection", "method", "color_wash"]
        let density = ["master", "red", "yellow", "green", "cyan", "blue", "magenta"]
        let skinShaper = ["global_sat", "global_dens", "hue_rotate", "hue_center", "hue_range",
                          "sigmoid_shift", "bellcurve_width", "phighlighter"]
        let relight = ["post.relight.enabled", "post.relight.strength"]
            + (0..<3).flatMap { index in
                ["enabled", "x", "y", "radius", "intensity", "color.0", "color.1", "color.2"]
                    .map { "post.relight.lights.\(index).\($0)" }
            }
        let colorPaths = ["prep.color_correction_saturation"]
        let colorPathCount = colorPaths.filter { model.isModified($0) }.count
        let separationCount = separation.filter { model.isModified("post.color_separation.\($0)") }.count
        let densityCount = density.filter { model.isModified("post.color_density.\($0)") }.count
        let skinShaperCount = skinShaper.filter { model.isModified("post.skin_shaper.\($0)") }.count
        let relightCount = relight.filter(model.isModified).count
        let correctionOffsetCount = model.isRaw && model.isModified("prep.color_correction_offset") ? 1 : 0
        let prepColorCount = prepColorControls.filter { isModified($0, model) }.count
        return whiteBalanceCount(model) + prepColorCount + colorPathCount + correctionOffsetCount
            + separationCount + densityCount + skinShaperCount + relightCount
    }
    static func maskCount(_ model: EditorModel) -> Int {
        let fields = ["exposure_ev", "temperature", "tint", "saturation"]
        var total = model.backgroundMaskLabels.count
        if total == 0 && model.hasBackgroundMask { total = 1 }
        for index in model.backgroundMaskLabels.indices {
            total += fields.filter { model.isModified("post.background_masks.\(index).\($0)") }.count
        }
        if model.backgroundMaskLabels.isEmpty {
            total += fields.filter { model.isModified("post.background_\($0)") }.count
        }
        return total
    }
    static func outputTabCount(_ model: EditorModel) -> Int {
        let finishPaths = ["io.render_look", "io.referent_logc3_enabled", "io.referent_logc3_path",
                           "post.hncs.clahe_strength", "post.hncs.skin_protection"]
        return (model.isModified(ImageSize.targetPath) ? 1 : 0) + (model.border.enabled ? 1 : 0)
            + finishPaths.filter(model.isModified).count + count(.scan, model)
    }
    static func count(_ tab: InspectorTab, _ model: EditorModel) -> Int {
        switch tab {
        case .exposure: prepCount(model)
        case .color: colorCount(model)
        case .lab: labCount(model)
        case .mask: maskCount(model)
        case .output: outputTabCount(model)
        }
    }
}

// MARK: The panel

/// The top of the inspector column: Adjustments · Presets as words, then
/// the edit count and Reset, or New and Import… beside the presets (§4.8).
struct PaneHeader: View {
    let model: EditorModel
    @AppStorage("negs.reset.keepGroups") private var resetKeepGroups = ""
    @State private var showingResetOptions = false

    var body: some View {
        let presets = model.inspectorPane == .presets
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            paneWord("Adjust", pane: .adjustments, help: "Show the adjustments (⌥⌘I)")
            paneWord("Presets", pane: .presets, help: "Show the presets (⌥⌘P)")
            Spacer(minLength: 0)
            if presets {
                WordButton(title: "New", help: "Save the film, paper and Lab settings as a preset (⇧⌘S)", action: model.newPreset)
                    .disabled(!model.canChangePresets)
                WordButton(title: "Import…", help: "Import presets (⇧⌘O)", action: model.importPresetsPanel)
                    .disabled(!model.canChangePresets)
            } else if model.source != nil {
                let hasResetBaseline = model.globalResetSavedAt != nil
                let edits = InspectorTab.allCases.map { InspectorEdits.count($0, model) }.reduce(0, +)
                if edits > 0 {
                    (Text("\(edits)").font(Theme.text(14, weight: 700, italic: true)).foregroundColor(Theme.paper)
                        + Text(edits == 1 ? " edit" : " edits").font(Theme.text(14, italic: true)).foregroundColor(Theme.dim))
                        .accessibilityLabel("\(edits) \(edits == 1 ? "edit" : "edits")")
                }
                WordButton(title: "Reset",
                           help: !hasResetBaseline
                                ? "Restore defaults on all tabs while keeping the film, paper, rotation, crop, border, and Image Size. You can undo this."
                                : "Apply your saved global reset defaults and restore the rest. You can undo this.",
                           action: model.reset)
                    .disabled(!model.hasCatalog || model.cropping)
                Button { showingResetOptions.toggle() } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                    .buttonStyle(InkPressStyle())
                    .accessibilityLabel("Keep on Reset options")
                    .popover(isPresented: $showingResetOptions, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("GLOBAL RESET DEFAULTS")
                                .font(Theme.ui(10, weight: .semibold)).tracking(0.7).foregroundStyle(Theme.dim)
                            Text("Choose groups, then save their current values as a preset used when resetting any photo.")
                                .font(Theme.ui(11)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                            ForEach(ResetKeepGroup.allCases) { group in
                                Toggle(group.rawValue, isOn: Binding(
                                    get: { ResetKeepGroup.selected(from: resetKeepGroups).contains(group) },
                                    set: { enabled in
                                        var groups = ResetKeepGroup.selected(from: resetKeepGroups)
                                        if enabled { groups.insert(group) } else { groups.remove(group) }
                                        resetKeepGroups = ResetKeepGroup.allCases.filter { groups.contains($0) }.map(\.rawValue).joined(separator: "|")
                                    }))
                                .toggleStyle(.checkbox)
                                .font(Theme.ui(11))
                            }
                            Divider().padding(.vertical, 2)
                            Button("Save Current Values as Global Default") {
                                model.saveGlobalResetDefaults()
                            }
                            .disabled(resetKeepGroups.isEmpty || model.source == nil)
                            .buttonStyle(.borderedProminent)
                            if model.globalResetSavedAt != nil {
                                Text("Global reset preset saved")
                                    .font(Theme.ui(10)).foregroundStyle(Theme.dim)
                            }
                        }
                        .padding(14).frame(width: 230, alignment: .leading)
                    }
                    .help("Choose and save global reset defaults")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .frame(maxWidth: .infinity, minHeight: Theme.Size.paneHeader, maxHeight: Theme.Size.paneHeader, alignment: .topLeading)
    }

    private func paneWord(_ title: String, pane: InspectorPane, help: String) -> some View {
        let chosen = model.inspectorPane == pane
        return Button { model.inspectorPane = pane } label: {
            Text(title).font(Theme.ui(11, weight: .medium)).foregroundStyle(chosen ? Theme.paper : Theme.dim)
        }
        .buttonStyle(InkPressStyle())
        .inkFocus(activate: { model.inspectorPane = pane })
        .help(help)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// Balance, Film and Output are labeled as studio tasks with compact icons.
struct InspectorTabs: View {
    let model: EditorModel
    @Binding var tab: InspectorTab

    var body: some View {
        TabRow(counts: Dictionary(uniqueKeysWithValues: InspectorTab.allCases.map { ($0, InspectorEdits.count($0, model)) }), tab: $tab,
               edits: { item, dismiss in AnyView(TabEditsList(model: model, tab: item, dismiss: dismiss)) })
    }
}

/// The tabs' row, from their edit counts: the words one gap apart (from
/// the last ink of one, its count if it has one, to the next), on one
/// baseline, their capitals centred between the rules.
struct TabRow: View {
    let counts: [InspectorTab: Int]
    @Binding var tab: InspectorTab
    /// What a click on a tab's count shows: its edits, with ↺ and Reset.
    var edits: ((InspectorTab, @escaping () -> Void) -> AnyView)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(InspectorTab.focusOrder, id: \.self) { item in
                TabWord(title: item.title, symbol: item.symbol, chosen: tab == item, count: counts[item] ?? 0,
                        tab: item,
                        edits: edits.map { make in { dismiss in make(item, dismiss) } }) { tab = item }
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 52, maxHeight: 52, alignment: .center)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector tabs")
    }
}

/// A compact task tab with a clear selected state and a quiet edit marker.
struct TabWord: View {
    let title: String
    let symbol: String
    let chosen: Bool
    var count = 0
    /// The edit list opened from the small marker when this tab has changes.
    var edits: ((@escaping () -> Void) -> AnyView)? = nil
    var tab: InspectorTab? = nil
    let choose: () -> Void
    @State private var hovered = false
    @State private var listShown = false

    /// The space between one word (its count, if any) and the next.
    static let gap: CGFloat = 7
    static let size: CGFloat = 13

    /// How far below the row's top a title's line starts so that its
    /// capitals sit in the middle of the row: as much room over the
    /// capitals as under the baseline. The weights share these metrics.
    static func topInset(row: CGFloat) -> CGFloat {
        let font = Theme.textFont(size, weight: 700)
        let ascent = CTFontGetAscent(font), cap = CTFontGetCapHeight(font)
        return ((row - cap) / 2 - (ascent - cap)).rounded()
    }

    /// The title's width set in `weight`, without tracking.
    static func width(_ title: String, weight: CGFloat) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: title, attributes: [.font: Theme.textFont(size, weight: weight)]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
    /// The tracking that sets a title as wide in 500 as in 700: the 700
    /// closes up and the 500 opens out by the same fraction of a point
    /// (0.2 to 0.5 pt between letters), so choosing a tab neither moves
    /// the others nor leaves a chosen word's gaps wider than the rest.
    static func tracking(_ title: String, chosen: Bool) -> CGFloat {
        guard title.count > 1 else { return 0 }
        let half = (width(title, weight: 700) - width(title, weight: 500)) / CGFloat(title.count - 1) / 2
        return chosen ? -half : half
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: choose) {
                VStack(spacing: 3) {
                    Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                    Text(title).font(Theme.text(9.5, weight: chosen ? 600 : 500))
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, minHeight: 38, maxHeight: 38)
                .foregroundStyle(chosen ? Theme.accent : hovered ? Theme.paper : Theme.label)
                .padding(.horizontal, 2).padding(.vertical, 5)
                .background(chosen ? Theme.accent.opacity(0.13) : .clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    if chosen {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Theme.accent.opacity(0.32), lineWidth: 1)
                    }
                }
            }
            .buttonStyle(InkPressStyle())
            .onHover { hovered = $0 }
            .inkFocus(activate: choose)
            .modifier(TaskTabKeyboardShortcut(tab: tab))
            .accessibilityLabel(tab?.accessibilityLabel(editCount: count) ?? (count > 0 ? "\(title), \(count) \(count == 1 ? "edit" : "edits")" : title))
            .accessibilityValue(tab?.accessibilityValue(isSelected: chosen, editCount: count))
            .accessibilityHint(tab?.accessibilityHint ?? "")
            .help(tab?.accessibilityHint ?? "")
            .accessibilityAddTraits(chosen ? [.isSelected, .isButton] : .isButton)
            .frame(maxWidth: .infinity)
            if count > 0 {
                countMark.padding(.top, 2).padding(.trailing, 4)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var countMark: some View {
        let mark = Circle().fill(Theme.accent).frame(width: 5, height: 5)
            .frame(width: 12, height: 24, alignment: .center)
        if let edits {
            Button { listShown.toggle() } label: { mark }
                .buttonStyle(InkPressStyle())
                .popover(isPresented: $listShown, arrowEdge: .bottom) { edits { listShown = false } }
                .tooltip("Show \(count) \(count == 1 ? "edit" : "edits") on \(title)")
                .accessibilityLabel("\(count) \(count == 1 ? "edit" : "edits") on \(title)")
        } else {
            mark.accessibilityHidden(true)
        }
    }
}

private struct TaskTabKeyboardShortcut: ViewModifier {
    let tab: InspectorTab?

    @ViewBuilder func body(content: Content) -> some View {
        if let tab {
            content.keyboardShortcut(KeyEquivalent(tab.shortcutKey), modifiers: tab.shortcutModifiers)
        } else {
            content
        }
    }
}

struct AdjustmentInspector: View {
    let model: EditorModel
    @AppStorage("expandedAdjustments") private var expanded = "Enlarger"
    @AppStorage("inspectorTab") private var tab = InspectorTab.exposure
    @AppStorage("negs.whiteBalance.linkTemperatureTint") private var linkTemperatureTint = false
    @AppStorage("negs.whiteBalance.fineTuneExpanded") private var fineTuneWhiteBalance = false
    /// View › Show All Controls: every control, as the Lab's Advanced
    /// controls switch did. Off, each module shows the few most photographs
    /// need, plus any setting that is off its default.
    @AppStorage(Self.allControlsKey) private var allControls = false
    /// The modules and sections whose "N more" were opened.
    @AppStorage(Self.moreKey) private var moreShown = ""
    static let allControlsKey = "labAllControls", moreKey = "moreAdjustments"

    var body: some View {
        // The histogram, film and paper, and the tabs stay put above the
        // tab's scrolling sections, so every tab opens with the stocks in view.
        VStack(spacing: 0) {
            ScopePanelView(histogram: model.histogram, waveform: model.waveform,
                            vectorscope: model.vectorscope, skinAnalysis: model.skinAnalysis,
                            colorSample: model.colorSample,
                            isUpdating: model.scopesUpdating,
                            setScopeMode: { model.scopeModeChanged($0) },
                            clippingEnabled: model.clippingOverlayEnabled,
                            setClippingEnabled: { model.clippingOverlayEnabled = $0 },
                            falseColorEnabled: model.falseColorEnabled,
                            setFalseColorEnabled: { model.falseColorEnabled = $0 },
                            saturationOverlayEnabled: model.saturationOverlayEnabled,
                            setSaturationOverlayEnabled: { model.saturationOverlayEnabled = $0 },
                            saturationOverlayMode: model.saturationOverlayMode,
                            setSaturationOverlayMode: { model.setSaturationOverlayMode($0) },
                            skinToneOverlayEnabled: model.skinToneOverlayEnabled,
                            setSkinToneOverlayEnabled: { model.skinToneOverlayEnabled = $0 },
                            neutralCandidatesEnabled: model.neutralCandidatesEnabled,
                            setNeutralCandidatesEnabled: { model.neutralCandidatesEnabled = $0 })
                .padding(.horizontal, Theme.Size.gutter)
                .padding(.bottom, 10)
            InspectorTabs(model: model, tab: $tab)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case .exposure: exposure
                    case .color: color
                    case .lab: lab
                    case .mask: mask
                    case .output: output
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            if tab == .output { ExportFoot(model: model) }
        }
        .disabled(!model.hasCatalog)
    }

    // MARK: Exposure

    @ViewBuilder private var exposure: some View {
        InkSection(title: "Light", edited: InspectorEdits.brightnessCount(model) > 0) {
            TickRow(title: model.isRaw ? "Match camera brightness" : "Match original brightness",
                    isOn: Binding(get: { model.matchesBrightness }, set: model.setMatchesBrightness),
                    changed: model.matchesBrightness != model.autoPlaceNewImages,
                    help: model.isRaw
                        ? "Develops the RAW about as bright as the camera’s own preview, and keeps it there when you change film, paper or a preset. Exposure adds to it."
                        : "Develops the photograph about as bright as the file itself, and keeps it there when you change film, paper or a preset. Exposure adds to it.")
            LabeledSlider(title: "Exposure (EV)", value: model.exposureOffset, range: model.exposureOffsetRange, step: 0.05,
                          defaultValue: 0, modified: model.exposureOffsetModified, reset: model.resetExposureOffset,
                          editing: { $0 ? model.beginInteraction() : model.endInteraction() },
                          help: model.matchesBrightness
                              ? "Brighter or darker than the match, in stops. It stays when the match changes with the film, paper or a preset."
                              : "Brightens or darkens the scene before the film, in stops. Unlike Negative exposure, the print doesn’t make up for it.")
            if let note = model.brightnessMatchNote { HintText(note) }
            // While matched the meter only sets where the highlight limit
            // starts, so it shows when matching is off, or when changed.
            if !model.brightnessMatchActive || model.isModified("camera.auto_exposure") || model.isModified("camera.auto_exposure_method") {
                TickRow(title: "Auto exposure", isOn: model.toggle("camera.auto_exposure"), changed: model.isModified("camera.auto_exposure"),
                        help: "Meters the photograph and exposes the film so the metered area lands on mid-grey, as a camera's meter does. Exposure adds to it.")
                if model.value("camera.auto_exposure").bool {
                    RevealedRows {
                        control(.choice("Metering", "camera.auto_exposure_method", ["average", "median", "center_weighted", "partial", "matrix", "multi_zone", "highlight_weighted"]))
                    }
                }
            }
        }
        controlSection("Tone", prepToneControls)
        InkSection(title: "Silver Retention", edited: model.isModified("film_render.silver_retention")) {
            let path = "film_render.silver_retention"
            LabeledSlider(title: "Silver retention",
                          value: Binding(get: { model.value(path).double * 80 },
                                         set: { model.set(path, .number(min(max($0, 0), 80) / 80)) }),
                          range: 0...80, step: 1, defaultValue: 0,
                          modified: model.isModified(path), reset: { model.resetValue(path) },
                          editing: { $0 ? model.beginInteraction() : model.endInteraction() },
                          help: ControlHelp.text(path))
                .disabled(model.filmIsBW || model.value("io.scan_film").bool)
        }
        filmExpand
        controlSection("Detail", prepDetailControls)
    }

    // MARK: Color

    @ViewBuilder private var color: some View {
        VStack(alignment: .leading, spacing: 0) {
            wb
        InkSection(title: "Color", edited: ["prep.color_correction_saturation"].contains(where: model.isModified)
                   || prepColorControls.contains { InspectorEdits.isModified($0, model) }
                   || ["strength", "target_hue", "complementary_hue", "target_saturation", "luminance_mask", "neutral_protection", "method", "color_wash"]
                    .contains { model.isModified("post.color_separation.\($0)") }
                   || ["master", "red", "yellow", "green", "cyan", "blue", "magenta"]
                    .contains { model.isModified("post.color_density.\($0)") }) {
            LabeledSlider(title: "Correction saturation", value: model.number("prep.color_correction_saturation", range: -100...100, step: 1),
                          range: -100...100, step: 1, defaultValue: 0,
                          modified: model.isModified("prep.color_correction_saturation"),
                          reset: { model.resetValue("prep.color_correction_saturation") },
                          editing: { $0 ? model.beginInteraction() : model.endInteraction() },
                          help: "Adjust overall colour saturation before the film scan.")
            ForEach(prepColorControls) { control($0) }
            Divider().overlay(Theme.line)
            Text("Color Separation").font(Theme.ui(10, weight: .semibold)).foregroundStyle(Theme.label)
                .padding(.top, 3)
            LabeledSlider(title: "Strength", value: model.number("post.color_separation.strength", range: 0...100, step: 1),
                          range: 0...100, step: 1, unit: "%", defaultValue: 0,
                          modified: model.isModified("post.color_separation.strength"), reset: { model.resetValue("post.color_separation.strength") },
                          editing: { $0 ? model.beginInteraction() : model.endInteraction(action: "Change Color Separation") },
                          help: "Separates two selected hue families in the finished scan. Set this above zero to activate the remaining controls.")
            LabeledSlider(title: "Target hue", value: model.number("post.color_separation.target_hue", range: 0...360, step: 1),
                          range: 0...360, step: 1, unit: "°", defaultValue: 35,
                          modified: model.isModified("post.color_separation.target_hue"), reset: { model.resetValue("post.color_separation.target_hue") },
                          editing: { $0 ? model.beginInteraction() : model.endInteraction(action: "Change Color Separation") },
                          help: "Hue angle of the first colour family, measured in the displayed scan's encoded RGB hue wheel.")
            HStack(spacing: 7) {
                Spacer(minLength: 0)
                Button { model.beginColorSeparationHuePick() } label: {
                    Image(systemName: "eyedropper")
                        .foregroundStyle(model.colorSeparationHuePickActive ? Theme.accent : Theme.label)
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Pick the target hue from the photograph")
                .accessibilityLabel("Pick target hue from photograph")
                if let sample = model.colorSample {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(red: Double(sample.red) / 255, green: Double(sample.green) / 255, blue: Double(sample.blue) / 255))
                        .frame(width: 28, height: 16)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.line, lineWidth: 1))
                        .help(sample.hex)
                }
            }
            LabeledSlider(title: "Complement", value: model.number("post.color_separation.complementary_hue", range: 0...360, step: 1),
                          range: 0...360, step: 1, unit: "°", defaultValue: 215,
                          modified: model.isModified("post.color_separation.complementary_hue"), reset: { model.resetValue("post.color_separation.complementary_hue") },
                          editing: { $0 ? model.beginInteraction() : model.endInteraction(action: "Change Color Separation") },
                          help: "Hue angle of the opposing colour family. The default pair is warm orange and cool blue.")
            LabeledSlider(title: "Saturation floor", value: model.number("post.color_separation.target_saturation", range: 0...100, step: 1),
                          range: 0...100, step: 1, unit: "%", defaultValue: 20,
                          modified: model.isModified("post.color_separation.target_saturation"), reset: { model.resetValue("post.color_separation.target_saturation") },
                          editing: { $0 ? model.beginInteraction() : model.endInteraction(action: "Change Color Separation") },
                          help: "Leaves low-saturation pixels alone so neutrals stay neutral.")
            LabeledSlider(title: "Luminance focus", value: model.number("post.color_separation.luminance_mask", range: -100...100, step: 1),
                          range: -100...100, step: 1, defaultValue: 0,
                          modified: model.isModified("post.color_separation.luminance_mask"), reset: { model.resetValue("post.color_separation.luminance_mask") },
                          editing: { $0 ? model.beginInteraction() : model.endInteraction(action: "Change Color Separation") },
                          help: "Moves the luminance range where the hue separation is strongest. Zero centers it on midtones.")
            LabeledSlider(title: "Protect neutrals", value: model.number("post.color_separation.neutral_protection", range: 0...100, step: 1),
                          range: 0...100, step: 1, unit: "%", defaultValue: 70,
                          modified: model.isModified("post.color_separation.neutral_protection"), reset: { model.resetValue("post.color_separation.neutral_protection") },
                          editing: { $0 ? model.beginInteraction() : model.endInteraction(action: "Change Color Separation") },
                          help: "Reduces the effect on weakly coloured pixels.")
            LabeledSlider(title: "Method", value: model.number("post.color_separation.method", range: 0...100, step: 1),
                          range: 0...100, step: 1, unit: "%", defaultValue: 50,
                          modified: model.isModified("post.color_separation.method"), reset: { model.resetValue("post.color_separation.method") },
                          editing: { $0 ? model.beginInteraction() : model.endInteraction(action: "Change Color Separation") },
                          help: "Blends hue separation with saturation emphasis.")
            TickRow(title: "Color wash", isOn: model.toggle("post.color_separation.color_wash"),
                    changed: model.isModified("post.color_separation.color_wash"),
                    help: "Pushes the selected hue family toward the target instead of separating it from the complement.")
            Divider().overlay(Theme.line)
            Text("Color Density · ME deSatch").font(Theme.ui(10, weight: .semibold)).foregroundStyle(Theme.label)
                .padding(.top, 3)
            HintText("Zero leaves the image unchanged. Move left to reduce color density globally or in one hue family.")
            ForEach([
                ("Global deSatch", "master"), ("Red deSatch", "red"), ("Yellow deSatch", "yellow"),
                ("Green deSatch", "green"), ("Cyan deSatch", "cyan"), ("Blue deSatch", "blue"),
                ("Magenta deSatch", "magenta")
            ], id: \.1) { title, channel in
                let path = "post.color_density.\(channel)"
                LabeledSlider(title: title,
                              value: model.number(path, range: -1...0, step: 0.0001),
                              range: -1...0, step: 0.0001, defaultValue: 0,
                              modified: model.isModified(path), reset: { model.resetValue(path) },
                              editing: { $0 ? model.beginInteraction() : model.endInteraction(action: "Change Color Density") },
                              help: channel == "master"
                                  ? "ME deSatch global density control. Zero is identity; move left to darken and de-saturate color density."
                                  : "ME deSatch hue-family density control using the original cone-coordinate falloff.")
            }
            HintText("ME deSatch behavior · SpektraFilm Studio · GPL-3.0")
        }
        let relightFields = (0..<3).flatMap { index in
            ["enabled", "x", "y", "radius", "intensity", "color.0", "color.1", "color.2"]
                .map { "post.relight.lights.\(index).\($0)" }
        }
        InkSection(title: "Relight", edited: model.isModified("post.relight.enabled")
                   || model.isModified("post.relight.strength") || relightFields.contains(where: model.isModified)) {
            HintText("Three soft radial lights. Color and light falloff are evaluated in the active output color space.")
            TickRow(title: "Enable relighting", isOn: model.toggle("post.relight.enabled"),
                    changed: model.isModified("post.relight.enabled"),
                    help: "Adds editable soft lights to the developed image.")
            LabeledSlider(title: "Overall strength", value: model.number("post.relight.strength", range: 0...1, step: 0.01),
                          range: 0...1, step: 0.01, defaultValue: 1,
                          modified: model.isModified("post.relight.strength"), reset: { model.resetValue("post.relight.strength") },
                          editing: { $0 ? model.beginInteraction() : model.endInteraction(action: "Change Relighting") },
                          help: "Scales the combined light contribution.")
            ForEach(0..<3, id: \.self) { index in
                let base = "post.relight.lights.\(index)"
                Divider().overlay(Theme.line)
                TickRow(title: "Light \(index + 1)", isOn: model.toggle("\(base).enabled"),
                        changed: model.isModified("\(base).enabled"), help: "Enable this soft radial light.")
                if model.value("\(base).enabled").bool {
                    LabeledSlider(title: "Horizontal position", value: model.number("\(base).x", range: 0...1, step: 0.01),
                                  range: 0...1, step: 0.01, defaultValue: 0.5,
                                  modified: model.isModified("\(base).x"), reset: { model.resetValue("\(base).x") },
                                  editing: { $0 ? model.beginInteraction() : model.endInteraction(action: "Move Relight") },
                                  help: "Position from left to right.")
                    LabeledSlider(title: "Vertical position", value: model.number("\(base).y", range: 0...1, step: 0.01),
                                  range: 0...1, step: 0.01, defaultValue: 0.5,
                                  modified: model.isModified("\(base).y"), reset: { model.resetValue("\(base).y") },
                                  editing: { $0 ? model.beginInteraction() : model.endInteraction(action: "Move Relight") },
                                  help: "Position from top to bottom.")
                    LabeledSlider(title: "Radius", value: model.number("\(base).radius", range: 0.02...1.5, step: 0.01),
                                  range: 0.02...1.5, step: 0.01, defaultValue: 0.45,
                                  modified: model.isModified("\(base).radius"), reset: { model.resetValue("\(base).radius") },
                                  editing: { $0 ? model.beginInteraction() : model.endInteraction(action: "Size Relight") },
                                  help: "Soft falloff radius relative to the shorter image dimension.")
                    LabeledSlider(title: "Intensity", value: model.number("\(base).intensity", range: -1...1, step: 0.01),
                                  range: -1...1, step: 0.01, defaultValue: 0,
                                  modified: model.isModified("\(base).intensity"), reset: { model.resetValue("\(base).intensity") },
                                  editing: { $0 ? model.beginInteraction() : model.endInteraction(action: "Change Relight") },
                                  help: "Positive values add light; negative values create negative fill.")
                    ForEach(0..<3, id: \.self) { channel in
                        let path = "\(base).color.\(channel)"
                        LabeledSlider(title: ["Red", "Green", "Blue"][channel], value: model.number(path, range: 0...1, step: 0.01),
                                      range: 0...1, step: 0.01, defaultValue: [1.0, 0.82, 0.66][channel],
                                      modified: model.isModified(path), reset: { model.resetValue(path) },
                                      editing: { $0 ? model.beginInteraction() : model.endInteraction(action: "Tint Relight") },
                                      help: "Linear channel value in the selected output color space.")
                    }
                }
            }
            HintText("Based on the MIT-licensed radial-light method in ComfyUI-ReLight.")
        }
        let skinShaperFields = ["global_sat", "global_dens", "hue_rotate", "hue_center", "hue_range",
                                "sigmoid_shift", "bellcurve_width", "phighlighter"]
        InkSection(title: "Skin Shaper", edited: skinShaperFields.contains { model.isModified("post.skin_shaper.\($0)") }) {
            HintText("Shapes a soft hue and luminance range around skin tones in the developed image.")
            LabeledSlider(title: "Skin saturation", value: model.number("post.skin_shaper.global_sat", range: -1...1, step: 0.001),
                          range: -1...1, step: 0.001, defaultValue: 0,
                          modified: model.isModified("post.skin_shaper.global_sat"), reset: { model.resetValue("post.skin_shaper.global_sat") },
                          editing: { $0 ? model.beginInteraction() : model.endInteraction(action: "Change Skin Shaper") },
                          help: "Raises or lowers color in the selected skin hue and luminance range.")
            LabeledSlider(title: "Skin density", value: model.number("post.skin_shaper.global_dens", range: -1...1, step: 0.001),
                          range: -1...1, step: 0.001, defaultValue: 0,
                          modified: model.isModified("post.skin_shaper.global_dens"), reset: { model.resetValue("post.skin_shaper.global_dens") },
                          editing: { $0 ? model.beginInteraction() : model.endInteraction(action: "Change Skin Shaper") },
                          help: "Changes the six-color density map within the selected range.")
            LabeledSlider(title: "Skin hue", value: model.number("post.skin_shaper.hue_rotate", range: -60...60, step: 0.1),
                          range: -60...60, step: 0.1, unit: "°", defaultValue: 0,
                          modified: model.isModified("post.skin_shaper.hue_rotate"), reset: { model.resetValue("post.skin_shaper.hue_rotate") },
                          editing: { $0 ? model.beginInteraction() : model.endInteraction(action: "Change Skin Shaper") },
                          help: "Rotates the shaped hue range.")
            LabeledSlider(title: "Hue center", value: model.number("post.skin_shaper.hue_center", range: -30...30, step: 0.1),
                          range: -30...30, step: 0.1, unit: "°", defaultValue: 0,
                          modified: model.isModified("post.skin_shaper.hue_center"), reset: { model.resetValue("post.skin_shaper.hue_center") },
                          editing: { $0 ? model.beginInteraction() : model.endInteraction(action: "Change Skin Shaper") },
                          help: "Moves the center of the skin hue selection.")
            LabeledSlider(title: "Hue range", value: model.number("post.skin_shaper.hue_range", range: 15...65, step: 0.1),
                          range: 15...65, step: 0.1, unit: "°", defaultValue: 40,
                          modified: model.isModified("post.skin_shaper.hue_range"), reset: { model.resetValue("post.skin_shaper.hue_range") },
                          editing: { $0 ? model.beginInteraction() : model.endInteraction(action: "Change Skin Shaper") },
                          help: "Controls how broadly the hue adjustment fades around its center.")
            LabeledSlider(title: "Luma center", value: model.number("post.skin_shaper.sigmoid_shift", range: 0...1, step: 0.001),
                          range: 0...1, step: 0.001, defaultValue: 0.5,
                          modified: model.isModified("post.skin_shaper.sigmoid_shift"), reset: { model.resetValue("post.skin_shaper.sigmoid_shift") },
                          editing: { $0 ? model.beginInteraction() : model.endInteraction(action: "Change Skin Shaper") },
                          help: "Centers the luminance selection from shadows to highlights.")
            LabeledSlider(title: "Luma range", value: model.number("post.skin_shaper.bellcurve_width", range: 0.25...1.75, step: 0.01),
                          range: 0.25...1.75, step: 0.01, defaultValue: 1,
                          modified: model.isModified("post.skin_shaper.bellcurve_width"), reset: { model.resetValue("post.skin_shaper.bellcurve_width") },
                          editing: { $0 ? model.beginInteraction() : model.endInteraction(action: "Change Skin Shaper") },
                          help: "Controls the luminance falloff around the center.")
            TickRow(title: "Highlight selected hues", isOn: model.toggle("post.skin_shaper.phighlighter"),
                    changed: model.isModified("post.skin_shaper.phighlighter"),
                    help: "Shows the selected hue and luminance range against a dim neutral image.")
        }
        }
    }

    // MARK: AI Masks

    @ViewBuilder private var mask: some View {
        VStack(alignment: .leading, spacing: 0) {
            InkSection(title: "Selection", edited: model.hasBackgroundMask) {
                HStack(spacing: 7) {
                    Menu {
                        ForEach(BackgroundMask.Selection.allCases.filter { $0 != .custom }) { selection in
                            Button { model.addBackgroundMask(selection: selection) } label: {
                                Label(selection.title, systemImage: selection.symbol)
                            }
                            .disabled(model.backgroundMaskGenerating)
                        }
                    } label: {
                        Label("Select", systemImage: "sparkle.magnifyingglass")
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.small)
                    .disabled(model.backgroundMaskGenerating)
                    .help("Create an on-device selection")
                    Button { model.createBrushBackgroundMask() } label: {
                        Image(systemName: "paintbrush.pointed")
                    }
                    .buttonStyle(SquareOutlinedButtonStyle(height: 25))
                    .controlSize(.small)
                    .disabled(model.backgroundMaskGenerating || model.image == nil)
                    .accessibilityLabel("New Brush")
                    .help("Create a new mask and paint directly on the photograph")
                    Menu {
                        ForEach(DepthMask.Preset.allCases) { preset in
                            Button { model.addDepthMask(preset) } label: {
                                Label("\(preset.title) depth", systemImage: preset.symbol)
                            }
                            .disabled(model.backgroundMaskGenerating || model.image == nil)
                        }
                    } label: {
                        Label("Depth", systemImage: "square.3.layers.3d")
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.small)
                    .disabled(model.backgroundMaskGenerating || model.image == nil)
                    .help("Estimate an on-device depth map, then select a near, middle, or far range.")
                }
                HStack(spacing: 12) {
                    TickRow(title: "Mask overlay", isOn: Binding(
                        get: { model.backgroundMaskOverlayVisible },
                        set: { model.backgroundMaskOverlayVisible = $0 }),
                            help: "Show or hide the mask preview on the photograph. This never changes the mask or its adjustments.")
                    Spacer(minLength: 8)
                    Text("Opacity").font(Theme.ui(10)).foregroundStyle(Theme.dim)
                    Slider(value: Binding(
                        get: { model.backgroundMaskOverlayOpacity },
                        set: { model.backgroundMaskOverlayOpacity = $0 }), in: 0.15...1, step: 0.05)
                        .frame(maxWidth: 94)
                        .disabled(!model.backgroundMaskOverlayVisible)
                        .help("Mask overlay opacity")
                    Text("\(Int(model.backgroundMaskOverlayOpacity * 100))%")
                        .font(Theme.metadata(9)).foregroundStyle(Theme.dim).monospacedDigit()
                        .frame(width: 30, alignment: .trailing)
                }
                .padding(.top, 4)
                if model.hasSelectedDepthMask {
                    HStack(spacing: 8) {
                        Text("Depth range").font(Theme.ui(10)).foregroundStyle(Theme.dim)
                        Text("\(Int(model.depthMaskLower * 100))")
                            .font(Theme.metadata(9)).foregroundStyle(Theme.dim).monospacedDigit()
                        Slider(value: Binding(get: { model.depthMaskLower }, set: { model.setDepthMaskLower($0) }),
                               in: 0...max(0.02, model.depthMaskUpper - 0.02))
                            .help("Nearest included depth")
                        Text("\(Int(model.depthMaskUpper * 100))")
                            .font(Theme.metadata(9)).foregroundStyle(Theme.dim).monospacedDigit()
                        Slider(value: Binding(get: { model.depthMaskUpper }, set: { model.setDepthMaskUpper($0) }),
                               in: min(0.98, model.depthMaskLower + 0.02)...1)
                            .help("Farthest included depth")
                    }
                    .padding(.top, 5)
                    HStack(spacing: 6) {
                        TickRow(title: "Depth map preview", isOn: Binding(
                            get: { model.depthMapPreviewEnabled },
                            set: { model.depthMapPreviewEnabled = $0 }),
                                 help: "Cyan marks farther depth and amber marks nearer depth. Turn this off to see the selected mask overlay.")
                        Spacer(minLength: 4)
                        Circle().fill(Color.cyan).frame(width: 7, height: 7)
                        Text("Far").font(Theme.metadata(9)).foregroundStyle(Theme.dim)
                        Circle().fill(Color.orange).frame(width: 7, height: 7)
                        Text("Near").font(Theme.metadata(9)).foregroundStyle(Theme.dim)
                    }
                    .padding(.top, 4)
                }
                if model.backgroundMaskGenerating {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text(model.backgroundMaskStatus.isEmpty ? "Working…" : model.backgroundMaskStatus)
                            .font(Theme.ui(10)).foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.tail)
                    }
                    .padding(.top, 5)
                }
                if !model.backgroundMaskLabels.isEmpty {
                    HStack(spacing: 6) {
                        Menu {
                            ForEach(Array(model.backgroundMaskLabels.enumerated()), id: \.offset) { index, label in
                                Button {
                                    model.selectBackgroundMask(at: index)
                                    model.backgroundMaskBrushActive = false
                                } label: {
                                    if index == model.selectedBackgroundMaskIndex {
                                        Label(label, systemImage: "checkmark")
                                    } else { Text(label) }
                                }
                            }
                            Divider()
                            Button("Remove All Masks", systemImage: "trash", role: .destructive) {
                                model.clearBackgroundMask()
                            }
                            .disabled(model.backgroundMaskGenerating)
                        } label: {
                            Label(model.backgroundMaskLabels.indices.contains(model.selectedBackgroundMaskIndex)
                                  ? model.backgroundMaskLabels[model.selectedBackgroundMaskIndex] : "Select Mask",
                                  systemImage: "square.dashed.inset.filled")
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .menuStyle(.borderlessButton)
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button(role: .destructive) { model.removeSelectedBackgroundMask() } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove selected mask")
                        .disabled(model.backgroundMaskGenerating)
                        Button { model.invertSelectedBackgroundMask() } label: {
                            Label("Invert", systemImage: "circle.lefthalf.filled")
                        }
                        .buttonStyle(SquareOutlinedButtonStyle(height: 25))
                        .help("Invert the selected and unselected areas")
                        .disabled(model.backgroundMaskGenerating)
                        Button { model.invertSelectedBackgroundMask() } label: {
                            Label("Invert", systemImage: "circle.lefthalf.filled")
                        }
                        .buttonStyle(SquareOutlinedButtonStyle(height: 25))
                        .controlSize(.small)
                        .help("Invert the selected and unselected areas")
                        .disabled(model.backgroundMaskGenerating)
                    }
                    .padding(.top, 6)
                    HStack(spacing: 6) {
                        Button {
                            model.backgroundMaskBrushActive.toggle()
                        } label: {
                            Label(model.backgroundMaskBrushActive ? "Done" : "Brush",
                                  systemImage: model.backgroundMaskBrushActive ? "checkmark" : "paintbrush.pointed")
                        }
                        .buttonStyle(SquareOutlinedButtonStyle())
                        .controlSize(.small)
                        .help("Paint directly on the image to add or remove areas from this mask")
                        .disabled(model.backgroundMaskGenerating)
                        if model.backgroundMaskBrushActive {
                            Picker("Brush mode", selection: Binding(
                                get: { model.backgroundMaskBrushSubtract },
                                set: { model.backgroundMaskBrushSubtract = $0 })) {
                                Text("Add").tag(false)
                                Text("Erase").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 116)
                            Slider(value: Binding(
                                get: { model.backgroundMaskBrushSize },
                                set: { model.backgroundMaskBrushSize = $0 }), in: 8...180, step: 1)
                                .help("Brush diameter")
                            Text("\(Int(model.backgroundMaskBrushSize)) px")
                                .font(Theme.metadata(9)).foregroundStyle(Theme.dim).monospacedDigit()
                                .frame(width: 38, alignment: .trailing)
                        }
                    }
                    .padding(.top, 5)
                    if model.backgroundMaskBrushActive {
                        HintText("Paint on the photo. Add fills the mask; Erase subtracts from it.")
                            .padding(.top, 3)
                    }
                } else {
                    HintText("Use AI Select or paint a new mask directly on the photo.")
                        .padding(.top, 6)
                }
                if model.backgroundMaskLabels.indices.contains(model.selectedBackgroundMaskIndex) {
                    Picker("Erase with", selection: Binding(
                        get: { model.backgroundMaskRemovalProvider },
                        set: { model.backgroundMaskRemovalProvider = $0 })) {
                        ForEach(BackgroundMaskRemovalProvider.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                    .pickerStyle(.menu)
                    .help("Choose GPT Image online or local LaMa for removal")
                    if model.backgroundMaskRemovalProvider == .openAI {
                        HintText("GPT Image uploads the selected area to OpenAI. API usage is billed separately.")
                            .padding(.top, 3)
                    }
                    Button {
                        model.removeSelectedBackgroundObject()
                    } label: {
                        Label("Remove Selected Area", systemImage: "eraser")
                            .frame(maxWidth: .infinity, minHeight: 31)
                    }
                    .buttonStyle(PencilButtonStyle(height: 34))
                    .controlSize(.regular)
                    .disabled(model.backgroundMaskGenerating || model.rendering || model.saving)
                    .help(model.backgroundMaskRemovalProvider == .openAI
                          ? "Remove the selected area with GPT Image through OpenAI"
                          : "Inpaint the selected area on this Mac with LaMa")
                }
            }
            InkSection(title: "Selected Mask Adjustments", edited: ["exposure_ev", "temperature", "tint", "saturation"]
                .contains { model.isModified(model.backgroundMaskPath($0)) }) {
                let exposurePath = model.backgroundMaskPath("exposure_ev")
                let temperaturePath = model.backgroundMaskPath("temperature")
                let tintPath = model.backgroundMaskPath("tint")
                let saturationPath = model.backgroundMaskPath("saturation")
                LabeledSlider(title: "Exposure", value: model.backgroundMaskNumber("exposure_ev", range: -5...5, step: 0.05),
                              range: -5...5, step: 0.05, unit: " EV", defaultValue: 0,
                              modified: model.isModified(exposurePath), reset: { model.resetValue(exposurePath) },
                              editing: { $0 ? model.beginInteraction() : model.endInteraction(action: "Adjust Mask") },
                              help: "Brighten or darken pixels selected by this mask.")
                LabeledSlider(title: "Temperature", value: model.backgroundMaskNumber("temperature", range: -100...100, step: 1),
                              range: -100...100, step: 1, defaultValue: 0,
                              modified: model.isModified(temperaturePath), reset: { model.resetValue(temperaturePath) },
                              editing: { $0 ? model.beginInteraction() : model.endInteraction(action: "Adjust Mask") },
                              help: "Shift this mask cooler or warmer.", endLabels: ("Cooler", "Warmer"))
                LabeledSlider(title: "Tint", value: model.backgroundMaskNumber("tint", range: -100...100, step: 1),
                              range: -100...100, step: 1, defaultValue: 0,
                              modified: model.isModified(tintPath), reset: { model.resetValue(tintPath) },
                              editing: { $0 ? model.beginInteraction() : model.endInteraction(action: "Adjust Mask") },
                              help: "Shift this mask toward magenta or green.", endLabels: ("Magenta", "Green"))
                LabeledSlider(title: "Saturation", value: model.backgroundMaskNumber("saturation", range: -100...100, step: 1),
                              range: -100...100, step: 1, defaultValue: 0,
                              modified: model.isModified(saturationPath), reset: { model.resetValue(saturationPath) },
                              editing: { $0 ? model.beginInteraction() : model.endInteraction(action: "Adjust Mask") },
                              help: "Increase or reduce colour within this mask.")
            }
            .disabled(!model.hasBackgroundMask)
        }
    }

    // MARK: White Balance

    @ViewBuilder private var wb: some View {
        if model.isRaw {
            let whiteBalanceMode = model.value("io.raw_white_balance.mode").string
            let cameraPreset = model.value("io.raw_white_balance.camera_preset").string
            let cameraPresetIndex = model.value("io.raw_white_balance.camera_preset_index").integer ?? 0
            let cameraProfile = model.cameraWhiteBalance
            let cameraPresets = cameraProfile["presets"].array
            let hasCameraWhiteBalance = !cameraPresets.isEmpty
            let cameraModelName = cameraProfile["model"].string
            let cameraMakerName = cameraProfile["maker"].string
            let normalizedCameraPreset = cameraPreset.lowercased().filter { $0.isLetter || $0.isNumber }
            let selectedPreset = (cameraPresetIndex > 0 ? cameraPresets.first { $0["index"].integer == cameraPresetIndex - 1 } : nil) ?? cameraPresets.first {
                $0["name"].string.lowercased().filter { $0.isLetter || $0.isNumber } == normalizedCameraPreset
            }
            let selectedCameraPreset = selectedPreset?["name"].string ?? cameraPreset
            let selectedIndex = selectedPreset?["index"].integer ?? 0
            let selectedWhiteBalance = whiteBalanceMode == "camera_preset" ? "camera:\(selectedIndex)"
                : whiteBalanceMode == "as_shot" ? "as_shot"
                : "custom"
            let cameraWhiteBalanceOptions = cameraPresets.map { preset in
                let name = preset["name"].string
                return ChoiceItem.option("\(cameraMakerName) \(cameraModelName) · \(name)", tag: "camera:\(preset["index"].integer ?? 0)")
            }
            let whiteBalanceOptions: [ChoiceItem] = [.option("As Shot", tag: "as_shot")]
                + cameraWhiteBalanceOptions + [.option("Custom", tag: "custom")]
            InkSection(title: "RAW White Balance", edited: ["io.raw_white_balance.mode", "io.raw_white_balance.temperature", "io.raw_white_balance.tint", "io.raw_white_balance.method", "io.raw_white_balance.camera_preset_index", "io.raw_white_balance.camera_tuning"].contains(where: model.isModified)) {
                if let gains = model.asShotWhiteBalance {
                    let channels = ["R", "G1", "B", "G2"].enumerated().compactMap { index, label in
                        gains.indices.contains(index) ? gains[index].map { "\(label) \($0.formatted(.number.precision(.fractionLength(0...3))))×" } : nil
                    }
                    HStack(spacing: 6) {
                        Text("AS SHOT").font(Theme.metadata(9, weight: .semibold)).foregroundStyle(Theme.dim)
                        Text(channels.joined(separator: "  ·  ")).font(Theme.metadata(10)).foregroundStyle(Theme.label)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .padding(.horizontal, Theme.Size.gutter)
                    .padding(.vertical, 5)
                } else {
                    HintText("Camera white balance recorded in this RAW.")
                }
                ChoiceRow(title: "Target white balance", items: whiteBalanceOptions, selection: selectedWhiteBalance,
                   changed: model.isModified("io.raw_white_balance.mode"),
                   help: hasCameraWhiteBalance
                    ? "Camera presets and fine tuning come from Darktable's WB data for the camera recorded in this RAW."
                    : "Choose As Shot or Custom temperature and tint. No matching Darktable camera WB entry was found for this RAW.") { option in
                    switch option {
                    case "as_shot": model.setWhiteBalanceMode(option)
                    case let value where value.hasPrefix("camera:"):
                        if let index = Int(value.dropFirst("camera:".count)) { model.setCameraWhiteBalancePreset(index: index) }
                    default: model.setWhiteBalanceMode("custom")
                    }
                }
                if hasCameraWhiteBalance {
                    cameraWhiteBalanceFineTune(active: whiteBalanceMode == "camera_preset", presets: cameraPresets,
                                              selected: selectedCameraPreset, camera: "\(cameraMakerName) \(cameraModelName)")
                    if whiteBalanceMode == "custom" { whiteBalanceFineTune }
                } else {
                    ChoiceRow(title: "Chromatic adaptation", items: [
                        .option("CAT16", tag: "cat16"),
                        .option("CAT02", tag: "cat02"),
                        .option("XYZ Scaling", tag: "xyz_scaling")
                    ], selection: model.value("io.raw_white_balance.method").string.isEmpty ? "cat16" : model.value("io.raw_white_balance.method").string,
                       changed: model.isModified("io.raw_white_balance.method"),
                       help: "Adapts the RAW illuminant to neutral in cone-response space. CAT16 is the modern CAT transform; CAT02 preserves older edits; XYZ Scaling is direct channel scaling.") {
                        model.set("io.raw_white_balance.method", .string($0))
                    }
                    whiteBalanceFineTune
                }
            }
        } else {
            InkSection(title: "White Balance", edited: model.isModified("prep.color_correction_offset")) {
                ColorCorrectionWheel(model: model)
            }
        }
        sourceSetup
    }

    /// File interpretation and lens corrections stay with RAW development inputs.
    @ViewBuilder private var sourceSetup: some View {
        if model.isRaw {
            if model.lensCorrectionSupported {
                InkSection(title: "Input", edited: model.isModified(EditorModel.lensCorrectionPath)) {
                    TickRow(title: "Lens corrections", isOn: model.toggle(EditorModel.lensCorrectionPath),
                            changed: model.isModified(EditorModel.lensCorrectionPath),
                            help: "Corrects distortion and vignetting with the data the camera recorded for its lens.")
                }
            }
        } else {
            inputColour
        }
    }

    @ViewBuilder private var whiteBalanceFineTune: some View {
        let whiteBalanceMode = model.value("io.raw_white_balance.mode").string
        DisclosureGroup(whiteBalanceMode == "camera_preset" ? "Camera fine tuning" : "Temperature and tint", isExpanded: $fineTuneWhiteBalance) {
            VStack(alignment: .leading, spacing: 7) {
                if whiteBalanceMode == "camera_preset" {
                    LabeledSlider(title: "Fine tuning", value: model.number("io.raw_white_balance.camera_tuning", range: -9...9, step: 1),
                                  range: -9...9, step: 1, defaultValue: 0,
                                  modified: model.isModified("io.raw_white_balance.camera_tuning"),
                                  reset: { model.set("io.raw_white_balance.camera_tuning", .number(0)) },
                                  editing: { $0 ? model.beginInteraction() : model.endInteraction() },
                                  help: "Camera-specific fine tuning from -9 to +9, following the Darktable EOS R5 WB table.",
                                  endLabels: ("-9", "+9"))
                } else if whiteBalanceMode == "custom" {
                    let defaultTemperature = model.defaultValue("io.raw_white_balance.temperature").double
                    LabeledSlider(title: "Temperature", value: model.whiteBalanceTemperature(linkTint: linkTemperatureTint),
                                  range: 1667...25000, step: 1, unit: " K", defaultValue: defaultTemperature,
                                  modified: model.isModified("io.raw_white_balance.temperature"),
                                  reset: { model.resetValue("io.raw_white_balance.temperature") },
                                  editing: { $0 ? model.beginInteraction() : model.endInteraction() },
                                  help: "Lower Kelvin settings cool the image; higher settings warm it. Click the readout to type an exact Kelvin value.",
                                  endLabels: ("Cooler", "Warmer"),
                                  trackValue: model.whiteBalanceTemperaturePosition(linkTint: linkTemperatureTint),
                                  trackRange: -400...400, trackStep: 1, trackScale: 4,
                                  trackNeutral: model.whiteBalanceTemperaturePosition(defaultTemperature) * 4,
                                  trackDefault: model.whiteBalanceTemperaturePosition(defaultTemperature) * 4)
                    LabeledSlider(title: "Tint", value: model.whiteBalanceTintAmount(),
                                  range: -100...100, step: 0.1, defaultValue: 0,
                                  modified: model.isModified("io.raw_white_balance.tint"),
                                  reset: { model.set("io.raw_white_balance.tint", .number(model.defaultValue("io.raw_white_balance.tint").double)) },
                                  editing: { $0 ? model.beginInteraction() : model.endInteraction() },
                                  help: "Zero is neutral. Drag left toward magenta or right toward green. Click the readout to type a correction.",
                                  endLabels: ("Magenta", "Green"),
                                  trackValue: model.whiteBalanceTintAmount(), trackRange: -400...400,
                                  trackStep: 1, trackScale: 4, trackNeutral: 0, trackDefault: 0)
                    TickRow(title: "Link tint to temperature", isOn: $linkTemperatureTint, changed: false,
                            help: "When enabled, warming shifts tint toward green; cooling shifts it toward magenta.")
                } else {
                    HintText("Choose Custom above to adjust temperature and tint.")
                }
                ColorCorrectionWheel(model: model)
            }
            .padding(.top, 4)
        }
        .font(Theme.ui(11, weight: .medium))
        .padding(.horizontal, Theme.Size.gutter)
        .padding(.top, 4)
    }

    @ViewBuilder private func cameraWhiteBalanceFineTune(active: Bool, presets: [JSONValue], selected: String, camera: String) -> some View {
        let presetKey = selected.lowercased().filter { $0.isLetter || $0.isNumber }
        let preset = presets.first { $0["name"].string.lowercased().filter { $0.isLetter || $0.isNumber } == presetKey }
        let tunings = preset?["tunings"].array ?? []
        let tuningValues = tunings.compactMap { $0["tuning"].integer }
        let supportsFineTuning = Set(tuningValues).count > 1
        let lower = Double(tuningValues.min() ?? 0)
        let upper = Double(tuningValues.max() ?? 0)
        let tuning = Int(model.number("io.raw_white_balance.camera_tuning", range: lower...upper, step: 1).wrappedValue.rounded())
        let target = tunings.first { $0["tuning"].integer == tuning }?["channels"].array ?? []
        let targetText = ["R", "G1", "B", "G2"].enumerated().compactMap { index, label in
            target.indices.contains(index) ? "\(label) \(target[index].double.formatted(.number.precision(.fractionLength(0...3))))×" : nil
        }.joined(separator: "  ·  ")
        VStack(alignment: .leading, spacing: 5) {
            if !targetText.isEmpty {
                HStack {
                    Text("DARKTABLE TARGET").font(Theme.metadata(9, weight: .semibold)).foregroundStyle(Theme.dim)
                    Spacer(minLength: 4)
                    Text(targetText).font(Theme.metadata(10)).foregroundStyle(Theme.label).lineLimit(1).minimumScaleFactor(0.75)
                }
                Text("\(camera) · \(preset?["name"].string ?? selected)").font(Theme.metadata(9)).foregroundStyle(Theme.dim)
            }
            if supportsFineTuning {
                LabeledSlider(title: "Fine tuning", value: model.number("io.raw_white_balance.camera_tuning", range: lower...upper, step: 1),
                              range: lower...upper, step: 1, defaultValue: 0,
                              modified: model.isModified("io.raw_white_balance.camera_tuning"),
                              reset: { model.set("io.raw_white_balance.camera_tuning", .number(0)) },
                              editing: { $0 ? model.beginInteraction() : model.endInteraction() },
                              help: "Camera-specific tuning values recorded in Darktable's WB table.",
                              endLabels: ("\(Int(lower))", "+\(Int(upper))"))
                    .disabled(!active)
            } else if active {
                HintText("Darktable has no fine-tuning data for this camera preset.")
            } else {
                HintText("Choose a camera preset to enable fine tuning.")
            }
        }
    }

    private func controlSection(_ title: String, _ controls: [Adjustment]) -> some View {
        InkSection(title: title, edited: controls.contains { InspectorEdits.isModified($0, model) }) {
            ForEach(controls) { control($0) }
        }
    }

    /// How long the film or paper develops, for stocks measured at several
    /// times. The stocks themselves are chosen from the label under the photograph.
    @ViewBuilder private func developmentTime(stock: Stock?, path: String, label: String, help: String) -> some View {
        if let stock, stock.times.count > 1 {
            let current = model.value(path)
            ChoiceRow(title: label, items: InspectorEdits.developmentItems(stock), selection: InspectorEdits.developmentTag(current),
                      changed: model.isModified(path), help: help) { tag in
                model.set(path, Double(tag).map { .number($0) } ?? .null)
            }
        }
    }

    // MARK: Lab

    @ViewBuilder private var lab: some View {
        let scanning = model.value("io.scan_film").bool
        // Show All Controls is a menu item, and the Lab's old Advanced
        // controls switch set the same default: say so where it shows,
        // with the way back.
        if allControls {
            MoreLine(text: "Showing all controls. Show fewer", ellipsis: false,
                     help: "Turns off View › Show All Controls: each module shows the few controls most photographs need, and any that you or a preset changed.") {
                allControls = false
            }
            .padding(.top, 10)
        }
        InkSection(title: "Camera", edited: InspectorEdits.count(.camera, model) > 0) {
            control(.slider("Negative exposure (EV)", "camera.exposure_compensation_ev", -5...5, 0.1))
            let lensBlur = shows("camera.lens_blur_um", section: .camera)
            if lensBlur { control(.slider("Lens blur (µm)", "camera.lens_blur_um", 0...100, 0.1)) }
            modules(.camera, ruledFirst: true)
            moreLine(.camera, loose: model.isModified("camera.lens_blur_um") ? [] : ["Lens blur"])
        }
        let filmStock = model.films.first { $0.id == model.film }
        InkSection(title: "Film", edited: InspectorEdits.count(.film, model) > 0) {
            developmentTime(stock: filmStock, path: InspectorEdits.filmDevelopmentPath, label: "Development",
                            help: "How long the film develops, from the times the stock was measured at. Longer gives more density and contrast.")
            modules(.film, ruledFirst: (filmStock?.times.count ?? 0) > 1)
            moreLine(.film)
        }
        let scanSwitch = scanning || shows(section: .print)
        let paperStock = scanning ? nil : model.papers.first { $0.id == model.paper }
        let printTime = (paperStock?.times.count ?? 0) > 1
        InkSection(title: "Print", edited: InspectorEdits.count(.print, model) > 0, skipped: scanning ? "skipped" : nil) {
            developmentTime(stock: paperStock, path: InspectorEdits.printDevelopmentPath, label: "Print development",
                            help: "How long the paper develops, from the times it was measured at. Longer gives deeper blacks and more contrast.")
            // Here rather than beside the stocks: few photographs want it.
            if scanSwitch {
                TickRow(title: "Scan film directly", isOn: model.toggle("io.scan_film"), changed: InspectorEdits.scanFilmModified(model),
                        help: "Skip printing and scan the developed film, as for slides.")
            }
            if scanning { HintText("Printing and the paper are skipped while scanning film directly.") }
            modules(.print, ruledFirst: scanSwitch || printTime, skipped: scanning)
            if !scanning { moreLine(.print, loose: ["Scan film directly"]) }
        }
    }

    @ViewBuilder private var filmExpand: some View {
        InkSection(title: "Expand", edited: ["post.film_expand.enabled", "post.film_expand.blacks", "post.film_expand.whites", "post.film_expand.mode"].contains(where: model.isModified)) {
            TickRow(title: "Enable Expand", isOn: model.toggle("post.film_expand.enabled"),
                    changed: model.isModified("post.film_expand.enabled"),
                    help: "Remap the black and white points after the film look, preserving highlight and shadow detail.")
            Group {
                LabeledSlider(title: "Black Point", value: model.number("post.film_expand.blacks", range: -20...30, step: 0.1),
                              range: -20...30, step: 0.1, unit: "%", defaultValue: model.defaultValue("post.film_expand.blacks").double,
                              modified: model.isModified("post.film_expand.blacks"), reset: { model.resetValue("post.film_expand.blacks") },
                              editing: { $0 ? model.beginInteraction() : model.endInteraction() },
                              help: "Move right to raise the black point and deepen shadows. Move left to lower it and retain shadow detail.")
                LabeledSlider(title: "White Point", value: model.number("post.film_expand.whites", range: 30...120, step: 0.1),
                              range: 30...120, step: 0.1, unit: "%", defaultValue: model.defaultValue("post.film_expand.whites").double,
                              modified: model.isModified("post.film_expand.whites"), reset: { model.resetValue("post.film_expand.whites") },
                              editing: { $0 ? model.beginInteraction() : model.endInteraction() },
                              help: "Move right to raise the white point and hold back highlights. Move left to lower it and brighten highlights.")
                control(.choice("Color Mode", "post.film_expand.mode", ["Luminance", "RGB"]))
            }
            .disabled(!model.value("post.film_expand.enabled").bool)
        }
    }

    /// The output transform is the final film-workflow step, after scan and
    /// colour-space controls. Export sizing and borders live in the Export tab.
    @ViewBuilder private var outputTransform: some View {
        let renderLookPath = "io.render_look"
        let legacyReferentEnabled = "io.referent_logc3_enabled"
        let renderLookValue = model.value(renderLookPath).string
        let renderLook = ["off", "hasselblad_hncs", "hasselblad_hncs_smooth", "referent_output", "referent_output_hncs_tone", "referent_output_hncs_smooth_tone"].contains(renderLookValue)
            ? renderLookValue
            : "referent_output"
        let referentPath = model.value("io.referent_logc3_path").string
        InkSection(title: "Output Transform",
                   edited: model.isModified(renderLookPath) || model.isModified(legacyReferentEnabled) || model.isModified("io.referent_logc3_path")
                    || model.isModified("post.hncs.clahe_strength") || model.isModified("post.hncs.skin_protection")) {
            ChoiceRow(title: "Output look",
                      items: [
                        .option("Original Tone Mapper", tag: "off"),
                        .option("HNCS Reference", tag: "hasselblad_hncs"),
                        .option("HNCS Smooth", tag: "hasselblad_hncs_smooth"),
                        .option("Full Output Transform", tag: "referent_output"),
                        .option("Full Output + HNCS", tag: "referent_output_hncs_tone"),
                        .option("Full Output + HNCS Smooth", tag: "referent_output_hncs_smooth_tone")
                      ],
                      selection: renderLook,
                      changed: model.isModified(renderLookPath) || model.isModified(legacyReferentEnabled),
                      help: "Choose the transform applied after the film scan. The preview updates immediately.",
                      choose: { model.set(renderLookPath, .string($0)) })
            if ["referent_output", "referent_output_hncs_tone", "referent_output_hncs_smooth_tone"].contains(renderLook) {
                ReadoutRow(title: "Referent LUT", value: referentPath.isEmpty ? "Not selected" : URL(fileURLWithPath: referentPath).lastPathComponent)
                WordButton(title: "Choose .cube…", help: "Choose the Referent LogC3-to-Rec.709 3D LUT", action: model.chooseReferentLUT)
                if !referentPath.isEmpty && !FileManager.default.fileExists(atPath: referentPath) {
                    HintText("Referent LUT not found. Choose the installed Referent_LogC3_to_Rec709.cube file.", warning: true)
                }
                if renderLook == "referent_output" {
                    HintText("Applies the complete LogC3/AWG3-to-BT.1886 LUT after the film scan.")
                } else if renderLook == "referent_output_hncs_tone" {
                    HintText("Applies the Referent LUT, then the reference HNCS tone with local CLAHE contrast. Both tone mappings remain active.")
                } else {
                    HintText("Applies the Referent LUT, then a smooth global HNCS-style tone without local CLAHE contrast.")
                }
            } else if renderLook == "off" {
                HintText("Uses Negs’ original output path without the Referent transform or HNCS tone mapping.")
            } else if renderLook == "hasselblad_hncs" || renderLook == "hasselblad_hncs_smooth" {
                HintText(renderLook == "hasselblad_hncs"
                         ? "Applies the reference HNCS-style gamma lift, local CLAHE contrast, and film curve to finished-image luminance."
                         : "Applies a smooth global HNCS-style gamma lift and film curve to finished-image luminance, without tile-local contrast.")
            }
            if renderLook.contains("hncs") && !renderLook.contains("smooth") {
                LabeledSlider(title: "Local contrast", value: model.number("post.hncs.clahe_strength", range: 0...100, step: 1),
                              range: 0...100, step: 1, unit: "%", defaultValue: 55,
                              modified: model.isModified("post.hncs.clahe_strength"), reset: { model.resetValue("post.hncs.clahe_strength") },
                              editing: { $0 ? model.beginInteraction() : model.endInteraction(action: "Adjust HNCS") },
                              help: "Controls how strongly the reference HNCS option uses local CLAHE contrast.")
            }
            if renderLook.contains("hncs") {
                LabeledSlider(title: "Skin / highlight protection", value: model.number("post.hncs.skin_protection", range: 0...100, step: 1),
                              range: 0...100, step: 1, unit: "%", defaultValue: 55,
                              modified: model.isModified("post.hncs.skin_protection"), reset: { model.resetValue("post.hncs.skin_protection") },
                              editing: { $0 ? model.beginInteraction() : model.endInteraction(action: "Adjust HNCS") },
                              help: "Softly reduces upward HNCS lift in warm skin-like tones and bright highlights to retain color and texture.")
            }
        }
    }

    // MARK: "N more"

    private var reveal: InspectorReveal { InspectorReveal(all: allControls, stored: moreShown) }
    private func revealMore(_ key: String) { moreShown = reveal.revealing(key) }
    private func hideMore(_ key: String) { moreShown = reveal.concealing(key) }
    /// Whether a section's extra controls (the expert modules, loose rows) show.
    private func shows(section: InspectorSection) -> Bool { reveal.shows(section: section) }
    /// Whether a section's loose control shows: it's revealed, or changed.
    private func shows(_ path: String, section: InspectorSection) -> Bool { shows(section: section) || model.isModified(path) }
    private func shows(_ group: AdjustmentGroup) -> Bool { reveal.shows(group, edits: InspectorEdits.count(group, model)) }
    private func shownControls(_ group: AdjustmentGroup) -> [Adjustment] {
        reveal.controls(group) { InspectorEdits.isModified($0, model) }
    }
    /// Whether a control draws: a B&W film has one grain lane, not three.
    private func isVisible(_ adjustment: Adjustment) -> Bool {
        if case .stockSlider(_, _, _, _, _, let bw) = adjustment { return !model.filmIsBW || bw != nil }
        return true
    }
    private func visibleCount(_ group: AdjustmentGroup) -> Int { group.controls.filter(isVisible).count }

    /// "2 more: Scanner, Color Management…" at a section's end, for the
    /// modules and rows it keeps back (round 11, B). Once clicked, the same
    /// place reads "Hide Scanner, Color Management" to fold them back.
    /// `loose` names the section's rows that hide when folded (unchanged).
    @ViewBuilder private func moreLine(_ section: InspectorSection, loose: [String] = []) -> some View {
        let key = InspectorReveal.sectionKey(section)
        let modules = adjustmentGroups.filter { $0.section == section }
        let hidden = modules.filter { !shows($0) }.map(\.title) + loose
        // What folding would hide: the expert modules nobody changed.
        let foldable = modules.filter { $0.basic == 0 && InspectorEdits.count($0, model) == 0 }.map(\.title) + loose
        if !shows(section: section), let text = InspectorReveal.moreText(hidden) {
            MoreLine(text: text) { revealMore(key) }
                .padding(.top, 6)
        } else if reveal.folds(section: section), let text = InspectorReveal.hideText(foldable) {
            MoreLine(text: text, ellipsis: false, help: MoreLine.hideHelp) { hideMore(key) }
                .padding(.top, 6)
        }
    }

    // MARK: Modules

    @ViewBuilder private func modules(_ section: InspectorSection, ruledFirst: Bool, skipped: Bool = false) -> some View {
        let groups = adjustmentGroups.filter { $0.section == section && shows($0) }
        ForEach(Array(groups.enumerated()), id: \.element.id) { offset, group in
            let shown = shownControls(group)
            let enabled = group.enable.map { model.toggle($0) }
            let fewer = reveal.foldable(group, visible: shown.filter(isVisible)) { InspectorEdits.isModified($0, model) }
            module(group.title, help: ControlHelp.group(group.title), enabled: enabled, summary: summary(group),
                   edited: InspectorEdits.count(group, model) > 0, skipped: skipped, ruled: offset > 0 || ruledFirst,
                   more: visibleCount(group) - shown.count, showMore: { revealMore(group.title) },
                   fewer: fewer, showFewer: { hideMore(group.title) }) {
                if group.title == "Print Curves" { ToneGraphView(model: model).padding(.horizontal, Theme.Size.gutter).padding(.vertical, 6) }
                ForEach(shown) { control($0) }
            }
        }
    }

    private func module<Content: View>(_ title: String, help: String?, enabled: Binding<Bool>? = nil, summary: String?, edited: Bool,
                                       skipped: Bool = false, ruled: Bool = true, more: Int = 0, showMore: @escaping () -> Void = {},
                                       fewer: Int = 0, showFewer: @escaping () -> Void = {},
                                       @ViewBuilder content: @escaping () -> Content) -> some View {
        let open = Binding(
            get: { expanded.split(separator: ",").contains(Substring(title)) },
            set: { open in
                var titles = expanded.split(separator: ",").map(String.init).filter { $0 != title }
                if open { titles.append(title) }
                expanded = titles.joined(separator: ",")
            })
        return InkModule(title: title, help: help, enabled: enabled, summary: summary, edited: edited, skipped: skipped, ruled: ruled,
                         open: open, more: more, showMore: showMore, fewer: fewer, showFewer: showFewer, content: content)
    }

    /// A folded module's summary: its first slider's value.
    private func summary(_ group: AdjustmentGroup) -> String? {
        for control in group.controls {
            switch control {
            case .slider(_, let path, _, let step):
                return model.value(path).double.formatted(.number.precision(.fractionLength(0...LabeledSlider.decimals(step))))
            case .stockSlider(_, let path, let index, let range, let step, _):
                return model.stockNumber(path, index, range: range, step: step).wrappedValue
                    .formatted(.number.precision(.fractionLength(0...LabeledSlider.decimals(step))))
            case .choice(_, let path, _):
                return optionTitle(model.value(path).string)
            case .silverRetention:
                return (model.value("film_render.silver_retention").double * 80)
                    .formatted(.number.precision(.fractionLength(0)))
            default: continue
            }
        }
        return nil
    }

    /// How a non-RAW photograph's values are read: automatically from its
    /// profile and tags, as an assumed colour space, or (Manual) by the input
    /// colour space and curve, as Negs 0.8 read every file.
    @ViewBuilder private var inputColour: some View {
        let colour = model.inputColour
        let edited = InspectorEdits.inputPaths.contains(where: model.isModified)
        module("Input Colour", help: ControlHelp.group("Input Colour"), summary: colour == .null ? nil : colour["summary"].string, edited: edited, ruled: false) {
            let assumed = ["sRGB", "Display P3", "Adobe RGB (1998)", "ProPhoto RGB", "ITU-R BT.2020"]
            ChoiceRow(title: "Read as", items: [.option("Automatic", tag: "auto"), .header("Assume")] + assumed.map { .option($0, tag: "assume:" + $0) } + [.divider, .option("Manual", tag: "manual")],
                      selection: model.inputInterpretation.wrappedValue, changed: model.isModified("io.input_interpretation.mode"),
                      help: "Automatic reads the embedded profile or tags; untagged files are read as sRGB. Assume overrides them. Manual uses the colour space and curve below, as Negs 0.8 did.") {
                model.inputInterpretation.wrappedValue = $0
            }
            switch model.value("io.input_interpretation.mode").string {
            case "assume":
                RevealedRows {
                    TickRow(title: "Linear values", isOn: model.toggle("io.input_interpretation.linear"),
                            changed: model.isModified("io.input_interpretation.linear"), help: ControlHelp.text("io.input_interpretation.linear"))
                }
            case "manual":
                RevealedRows {
                    control(.choice("Colour space", "io.input_color_space", ["sRGB", "Display P3", "Adobe RGB (1998)", "ProPhoto RGB", "ITU-R BT.2020", "ACES2065-1", "ACEScg"]))
                    TickRow(title: "Decode the curve", isOn: model.toggle("io.input_cctf_decoding"),
                            changed: model.isModified("io.input_cctf_decoding"), help: ControlHelp.text("io.input_cctf_decoding"))
                }
            default: EmptyView()
            }
            if colour != .null {
                ReadoutRow(title: "Reads", value: colour["summary"].string, italic: true)
                if colour["automatic"].string != colour["summary"].string { ReadoutRow(title: "Automatic", value: colour["automatic"].string, italic: true) }
                if !colour["warning"].string.isEmpty { HintText(colour["warning"].string, warning: true) }
            }
        }
    }

    // MARK: Output

    /// Delivery sizing and framing stay together after the film workflow.
    @ViewBuilder private var output: some View {
        scanOutput
        outputTransform
        ImageSizeSection(model: model)
        InkSection(title: "Border", edited: model.border.enabled) {
            TickRow(title: "Add border", isOn: model.border(\.enabled), changed: model.border.enabled,
                    help: "Frames the photograph in a mat or a film frame. The preview always shows it; Include in export decides whether files get it.")
            Group {
                let photo = model.photoSize == .zero ? nil : model.photoSize
                BorderStylePicker(selection: model.border(\.style), photo: photo, colors: (model.border.color, model.border.lineColor))
                    .padding(.horizontal, Theme.Size.gutter).padding(.vertical, 6)
                if let photo, !BorderStyle.film35.fits(photo) {
                    HintText("35mm needs a 3:2 or 3:4 photograph. This one is \(Self.ratio(photo)); crop it to 3:2 or 4:3 to use it.")
                }
                borderControls
                TickRow(title: "Extend to 3:4 for Instagram", isOn: model.border(\.instagram), changed: model.border.instagram != BorderSettings().instagram,
                        help: "Adds white above and below, or at the sides, so Instagram shows the whole photograph in a 3:4 portrait post.")
                TickRow(title: "Include in export", isOn: model.border(\.export), changed: model.border.export != BorderSettings().export,
                        help: "Adds the border to exported photographs and saved previews.")
            }
            .inkDisabled(!model.border.enabled)
        }
    }

    /// Final scan encoding and output look belong with the rendered file.
    @ViewBuilder private var scanOutput: some View {
        let outputChanged = InspectorEdits.outputCount(model) > 0
        let outputShown = outputChanged || shows(section: .scan)
        InkSection(title: "Scan & Color", edited: InspectorEdits.count(.scan, model) > 0) {
            modules(.scan, ruledFirst: false)
            if outputShown {
                module("Output", help: ControlHelp.group("Output"), summary: model.previewSpace, edited: outputChanged,
                       ruled: adjustmentGroups.contains { $0.section == .scan && shows($0) }) {
                    ChoiceRow(title: "Colour space", items: SaveSettings.colorSpaces.map { .option($0, tag: $0) }, selection: model.previewSpace,
                              changed: model.previewSpace != SaveSettings.colorSpaces[0],
                              help: "The preview develops in this colour space, so it shows the colours an export in it can hold. Save and Export use it next, and switch it when you pick another.",
                              choose: model.choosePreviewSpace)
                    TickRow(title: "Encode with the colour space’s curve", isOn: model.toggle("io.output_cctf_encoding"),
                            changed: model.isModified("io.output_cctf_encoding"), help: "Off writes linear values, for further processing.")
                }
            }
            moreLine(.scan, loose: outputChanged ? [] : ["Output"])
        }
    }

    /// The chosen style's width and colours. Solid and Keyline share the
    /// mat; the film frame's width adds black around it.
    @ViewBuilder private var borderControls: some View {
        switch model.border.style {
        case .solid, .keyline:
            let keyline = model.border.style == .keyline
            borderSlider("Width", \.width, 0...15, step: 0.1, help: "The mat’s width, in percent of the photograph’s long edge.")
            if keyline { borderSlider("Line width", \.line, 0.05...2, step: 0.05, help: "The line’s width, in percent of the photograph’s long edge.") }
            ColourWellRow(title: "Color", color: model.borderColor(\.color), help: "The mat’s colour.")
            if keyline { ColourWellRow(title: "Line color", color: model.borderColor(\.lineColor), help: "The line’s colour.") }
        case .film:
            borderSlider("Width", \.filmWidth, 0...15, step: 0.1, help: "Adds black around the film frame, in percent of the photograph’s long edge.")
        case .film35:
            EmptyView()
        }
    }

    /// A border width in percent of the photograph's long edge.
    private func borderSlider(_ title: String, _ setting: WritableKeyPath<BorderSettings, Double>, _ range: ClosedRange<Double>, step: Double,
                              help: String) -> some View {
        let initial = BorderSettings()[keyPath: setting]
        return LabeledSlider(title: title, value: model.borderPercent(setting, range: range, step: step), range: range, step: step, unit: "%",
                             defaultValue: initial * 100, modified: abs(model.border[keyPath: setting] - initial) > 1e-9,
                             reset: { model.border(setting).wrappedValue = initial },
                             editing: { $0 ? model.beginInteraction() : model.endInteraction(action: "Change Border") },
                             help: help)
    }

    private func control(_ adjustment: Adjustment) -> some View { AdjustmentControl(model: model, adjustment: adjustment) }
    /// A photograph's aspect ratio as people name it, such as 16:9.
    static func ratio(_ size: CGSize) -> String {
        let ratio = max(size.width, size.height) / min(size.width, size.height)
        let named = [(1.0, "1:1"), (5.0 / 4, "5:4"), (7.0 / 5, "7:5"), (16.0 / 9, "16:9"), (2.0, "2:1"), (21.0 / 9, "21:9")]
        if let (_, name) = named.first(where: { abs(ratio / $0.0 - 1) <= 0.01 }) { return name }
        return String(format: "%.2f:1", Double(ratio))
    }
}

/// A global chroma-offset wheel, like Resolve's HDR Offset control: angle
/// selects the tint and distance from neutral selects the amount.
private struct ColorCorrectionWheel: View {
    let model: EditorModel
    @State private var eventStarted = false
    private let path = "prep.color_correction_offset"

    var body: some View {
        let values = model.value(path).array
        let rawWhiteBalance = model.isRaw
        let whiteBalanceWheel = model.whiteBalanceWheelPosition()
        let hue = rawWhiteBalance ? whiteBalanceWheel.hue : values.first?.double ?? 0
        let strength = rawWhiteBalance ? whiteBalanceWheel.strength : values.dropFirst().first?.double ?? 0
        let mode = model.value("io.raw_white_balance.mode").string
        let temperature = mode == "custom" ? model.value("io.raw_white_balance.temperature").double
            : mode == "tungsten" ? 2850 : 6504
        let tint = model.whiteBalanceTintAmount(for: mode == "custom" ? model.value("io.raw_white_balance.tint").double : 1)
        let whiteBalanceModified = rawWhiteBalance && [
            "io.raw_white_balance.mode", "io.raw_white_balance.temperature", "io.raw_white_balance.tint"
        ].contains(where: model.isModified)
        let strengthBinding = Binding<Double>(
            get: {
                let raw = rawWhiteBalance ? model.whiteBalanceWheelPosition().strength : model.value(path).array.dropFirst().first?.double ?? 0
                return rawWhiteBalance ? sqrt(raw / 100) * 100 : raw
            },
            set: { amount in
                if rawWhiteBalance {
                    model.setWhiteBalanceWheel(hue: model.whiteBalanceWheelPosition().hue, strength: amount * amount / 100)
                } else {
                    let current = model.value(path).array
                    model.set(path, .array([current.first ?? .number(0), .number(amount)]))
                }
            })
        VStack(spacing: 10) {
            HStack {
                Text(rawWhiteBalance ? "RAW balance · before film" : "Color offset · before film scan")
                    .font(Theme.ui(11, weight: .medium)).foregroundStyle(Theme.dim)
                Spacer()
                Button("Reset") {
                    model.beginInteraction()
                    if rawWhiteBalance {
                        model.resetColorCorrection()
                    } else {
                        model.set(path, .array([.number(0), .number(0)]))
                        model.resetValue("prep.color_correction_saturation")
                    }
                    model.endInteraction(action: "Reset Color Correction")
                }
                .buttonStyle(InkPressStyle())
                .disabled(hue == 0 && strength == 0 && !whiteBalanceModified
                          && !model.isModified(path) && !model.isModified("prep.color_correction_saturation"))
                .accessibilityLabel("Reset color correction")
            }
            HStack(alignment: .center, spacing: 12) {
                GeometryReader { geometry in
                    let side = min(geometry.size.width, geometry.size.height)
                    let radius = side / 2 - 9
                    let radians = hue * .pi / 180
                    let marker = CGPoint(x: side / 2 + cos(radians) * radius * strength / 100,
                                         y: side / 2 + sin(radians) * radius * strength / 100)
                    if rawWhiteBalance {
                        let dominant = max(abs(cos(radians)), abs(sin(radians)))
                        let temperatureOffset = dominant > 0 ? cos(radians) / dominant * strength : 0
                        let tintOffset = dominant > 0 ? sin(radians) / dominant * strength : 0
                        RawWhiteBalancePad(model: model, temperature: temperature, tint: tint,
                                           temperatureOffset: temperatureOffset, tintOffset: tintOffset)
                    } else {
                        ZStack {
                            Circle()
                                .fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                                .overlay(Circle().fill(RadialGradient(colors: [.white, .clear], center: .center, startRadius: 0, endRadius: radius)))
                            ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { fraction in
                                Circle().stroke(.white.opacity(fraction == 1 ? 0.72 : 0.25), lineWidth: fraction == 1 ? 1.2 : 0.6)
                                    .scaleEffect(fraction)
                            }
                            Circle().fill(.white).frame(width: 11, height: 11)
                                .overlay(Circle().stroke(.black.opacity(0.8), lineWidth: 1.5))
                                .position(marker)
                        }
                        .frame(width: side, height: side)
                        .contentShape(Circle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { event in
                                if !eventStarted { eventStarted = true; model.beginInteraction() }
                                let dx = event.location.x - side / 2
                                let dy = event.location.y - side / 2
                                if hypot(dx, dy) > radius * 0.12 {
                                    let angle = (atan2(dy, dx) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
                                    model.set(path, .array([.number(Double(angle)), .number(strength)]))
                                }
                            }
                            .onEnded { _ in eventStarted = false; model.endInteraction(action: "Color Correction") })
                    }
                }
                .frame(width: 168, height: 168)

                VStack(alignment: .leading, spacing: 5) {
                    if rawWhiteBalance {
                        Text("\(Int(temperature.rounded())) K  ·  Tint \(Int(tint.rounded()))")
                            .font(Theme.metadata(11, weight: .medium)).foregroundStyle(Theme.paper)
                        Text("Temperature  ← →   ·   Tint  ↑ ↓")
                            .foregroundStyle(Theme.dim)
                    } else {
                        Text("Hue \(Int(hue.rounded()))°  ·  \(Int(strength.rounded()))%")
                            .font(Theme.metadata(11, weight: .medium)).foregroundStyle(Theme.paper)
                        Text("Wheel: hue  ·  Strength: amount")
                            .foregroundStyle(Theme.dim)
                    }
                }
                .font(Theme.ui(11))
                Spacer(minLength: 0)
            }
            .frame(height: 168)
            LabeledSlider(title: rawWhiteBalance ? "WB amount" : "Strength", value: strengthBinding,
                          range: 0...100, step: 0.1, unit: "%", defaultValue: 0,
                          modified: rawWhiteBalance ? whiteBalanceModified : model.isModified(path),
                          reset: {
                              if rawWhiteBalance {
                                  model.setWhiteBalanceWheel(hue: hue, strength: 0)
                              } else {
                                  let current = model.value(path).array
                                  model.set(path, .array([current.first ?? .number(0), .number(0)]))
                              }
                          },
                          editing: { $0 ? model.beginInteraction() : model.endInteraction(action: "Color Correction Strength") },
                          help: rawWhiteBalance
                            ? "Make smaller WB changes near neutral. The full temperature and tint range remains available at the ends; changing amount preserves the selected direction."
                            : "Adjust the global color correction strength from neutral. The response is finer near zero and ramps up smoothly; changing strength does not alter the selected hue.")
        }
        .padding(.horizontal, Theme.Size.gutter)
        .padding(.vertical, 8)
    }
}

private struct RawWhiteBalancePad: View {
    let model: EditorModel
    let temperature: Double
    let tint: Double
    let temperatureOffset: Double
    let tintOffset: Double
    @State private var eventStarted = false

    var body: some View {
        VStack(spacing: 4) {
            axisHeader
            controlPad
            axisFooter
        }
    }

    private var axisHeader: some View {
        HStack {
            Text("MAGENTA").foregroundStyle(Color.pink)
            Spacer()
            Text("TINT").foregroundStyle(Theme.dim)
            Spacer()
            Text("GREEN").foregroundStyle(Color.green)
        }
        .font(Theme.ui(8, weight: .semibold))
    }

    private var axisFooter: some View {
        HStack {
            Text("COOL").foregroundStyle(Color.blue)
            Spacer()
            Text("\(Int(temperature.rounded())) K").foregroundStyle(Theme.label)
            Spacer()
            Text("WARM").foregroundStyle(Color.orange)
        }
        .font(Theme.ui(8, weight: .semibold).monospacedDigit())
    }

    private var controlPad: some View {
        GeometryReader { geometry in
            padSurface(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func padSurface(width: CGFloat, height: CGFloat) -> some View {
        let point = CGPoint(x: width / 2 + temperatureOffset / 100 * (width / 2 - 8),
                            y: height / 2 - tintOffset / 100 * (height / 2 - 8))
        return ZStack {
            padBackground
            centerAxes(width: width, height: height)
            marker.position(point)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .gesture(padGesture(width: width, height: height))
        .accessibilityElement()
        .accessibilityLabel("RAW white balance: horizontal changes temperature from cool to warm; vertical changes tint from magenta to green")
        .accessibilityValue("\(Int(temperature.rounded())) Kelvin, tint \(Int(tint.rounded()))")
    }

    private func padGesture(width: CGFloat, height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { event in
                if !eventStarted { eventStarted = true; model.beginInteraction() }
                let x = min(max((event.location.x / width - 0.5) * 200, -100), 100)
                let y = min(max((0.5 - event.location.y / height) * 200, -100), 100)
                model.setWhiteBalancePad(temperatureOffset: x, tintAmount: y)
            }
            .onEnded { _ in
                eventStarted = false
                model.endInteraction(action: "RAW White Balance")
            }
    }

    private var padBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(LinearGradient(colors: [.blue.opacity(0.72), Color(red: 0.42, green: 0.43, blue: 0.42), .orange.opacity(0.82)], startPoint: .leading, endPoint: .trailing))
            .overlay(RoundedRectangle(cornerRadius: 8).fill(LinearGradient(colors: [.green.opacity(0.68), .clear, .pink.opacity(0.68)], startPoint: .top, endPoint: .bottom)))
    }

    private func centerAxes(width: CGFloat, height: CGFloat) -> some View {
        Path { path in
            path.move(to: CGPoint(x: width / 2, y: 0)); path.addLine(to: CGPoint(x: width / 2, y: height))
            path.move(to: CGPoint(x: 0, y: height / 2)); path.addLine(to: CGPoint(x: width, y: height / 2))
        }
        .stroke(.white.opacity(0.72), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
    }

    private var marker: some View {
        Circle().fill(.white).frame(width: 13, height: 13)
            .overlay(Circle().stroke(.black.opacity(0.85), lineWidth: 1.5))
    }
}

/// Export, pinned to the foot of the Output tab: what an export makes, over
/// the yellow button (§4.11). A batch's progress is in the status line.
struct ExportFoot: View {
    let model: EditorModel

    var body: some View {
        VStack(spacing: 8) {
            Text(Self.summary(photo: model.photoSize))
                .font(Theme.text(14, italic: true)).foregroundStyle(Theme.label).lineLimit(1)
            Button(model.exportTitle, action: model.exportPanel)
                .buttonStyle(PencilButtonStyle())
                .disabled(!model.canExport || model.cropping)
                .inkFocus(activate: { if model.canExport && !model.cropping { model.exportPanel() } })
                .help(model.exportTitle == "Export Photograph…" ? "Export photograph (⇧⌘E)" : "Export the selected photographs (⇧⌘E)")
        }
        .padding(.horizontal, Theme.Size.gutter)
        .padding(.top, 11)
        .padding(.bottom, 16)
        .overlay(alignment: .top) { InkRule() }
    }

    /// "3984 × 2656 · JPEG 95 · sRGB": the photograph's size, then the
    /// format and colour space the save panel will offer first.
    static func summary(photo: CGSize, format: OutputFormat = .last, quality: Int = SaveSettings.lastQuality, chosenSpace: Int = SaveSettings.chosenSpace) -> String {
        let depth = SaveSettings.bitDepth(for: format)
        let kind = switch format {
        case .jpeg: "JPEG \(quality)"
        case .png: "PNG \(depth)-bit"
        case .tiff: "TIFF \(depth)-bit"
        }
        let space = SaveSettings.colorSpaces[SaveSettings.effectiveSpace(chosenSpace, bitDepth: format == .jpeg ? 8 : depth)]
        let size = photo == .zero ? nil : "\(Int(photo.width)) × \(Int(photo.height))"
        return ([size, kind, space].compactMap { $0 }).joined(separator: " · ")
    }
}

// Crop's Angle slider, until crop gets its dial (step 6).
/// A small slider that double-click or Option-click resets, as in Lightroom
/// and Capture One. AppKit, because NSSlider tracks the mouse itself and
/// SwiftUI's tap gestures on a Slider never fire. A double-click's first
/// click still moves the knob; the second resets.
struct ResettableSlider: NSViewRepresentable {
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    /// The default: on macOS 26 the track fills from here to the knob, so a
    /// moved slider shows where it started.
    var neutral: Double? = nil
    let editing: (Bool) -> Void
    let reset: () -> Void
    /// AppKit's tooltip: SwiftUI's `.help` doesn't reach a hosted NSView.
    var toolTip: String? = nil

    func makeNSView(context: Context) -> NSSlider {
        let slider = Control()
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        let slider = slider as! Control
        slider.editing = editing
        slider.reset = reset
        slider.setAccessibilityLabel(title)
        if slider.toolTip != toolTip { slider.toolTip = toolTip }
        // SwiftUI applies its environment's control size after makeNSView.
        if slider.controlSize != .small { slider.controlSize = .small }
        if slider.minValue != range.lowerBound { slider.minValue = range.lowerBound }
        if slider.maxValue != range.upperBound { slider.maxValue = range.upperBound }
        // neutralValue needs the macOS 26 SDK, which release CI's Xcode 16
        // lacks; builds from it fill the track from the minimum, as before.
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            let neutral = min(max(neutral ?? range.lowerBound, range.lowerBound), range.upperBound)
            if slider.neutralValue != neutral { slider.neutralValue = neutral }
        }
        #endif
        slider.wanted = value.wrappedValue
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: ResettableSlider
        init(_ parent: ResettableSlider) { self.parent = parent }
        @objc func changed(_ slider: NSSlider) {
            parent.value.wrappedValue = slider.doubleValue
            // Read back the snapped value at once rather than waiting for
            // updateNSView, so the knob's target is current when a drag ends.
            (slider as! Control).wanted = parent.value.wrappedValue
        }
    }

    final class Control: NSSlider {
        var editing: (Bool) -> Void = { _ in }
        var reset: () -> Void = {}
        /// The model's value, snapped to the step, which the knob shows.
        var wanted = 0.0 {
            didSet { if !tracking { show() } }
        }
        private var tracking = false
        private var settling: Timer?

        private func show() {
            if doubleValue != wanted { doubleValue = wanted }
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 || event.modifierFlags.contains(.option) {
                reset()
                return
            }
            settling?.invalidate()
            // NSSlider tracks the drag inside mouseDown, so it returns when the mouse is released.
            tracking = true
            editing(true)
            super.mouseDown(with: event)
            tracking = false
            editing(false)
            show()
            // On macOS 26 the slider writes its last tracked value back about
            // 0.25 s after release, which undoes the step snap and a
            // double-click's reset. Keep showing the model's value until then.
            // A default-mode timer, so it never fires during a drag.
            let until = Date(timeIntervalSinceNow: 0.6)
            settling = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] timer in
                guard let self, Date() < until else { return timer.invalidate() }
                self.show()
            }
        }
    }
}

/// Takes focus as it appears, selecting its text, in the inspector column
/// where SwiftUI focus doesn’t reach.
class FocusingTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }
}
