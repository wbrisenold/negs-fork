import Foundation

/// Keep the full Rust schema, including fields the inspector doesn't expose.
/// Defaults come from the engine, so adding a Rust parameter cannot reset it here.
enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    subscript(_ path: String) -> JSONValue {
        get { value(at: path.split(separator: ".").map(String.init)[...]) }
        set { set(newValue, at: path.split(separator: ".").map(String.init)[...]) }
    }

    private func value(at path: ArraySlice<String>) -> JSONValue {
        guard let key = path.first else { return self }
        switch self {
        case .object(let values): return values[key]?.value(at: path.dropFirst()) ?? .null
        case .array(let values):
            guard let i = Int(key), values.indices.contains(i) else { return .null }
            return values[i].value(at: path.dropFirst())
        default: return .null
        }
    }

    private mutating func set(_ value: JSONValue, at path: ArraySlice<String>) {
        guard let key = path.first else { self = value; return }
        switch self {
        case .object(var values):
            var child = values[key] ?? .object([:])
            child.set(value, at: path.dropFirst()); values[key] = child; self = .object(values)
        case .array(var values):
            guard let i = Int(key), values.indices.contains(i) else { return }
            values[i].set(value, at: path.dropFirst()); self = .array(values)
        default: break
        }
    }

    var double: Double { if case .number(let v) = self { return v }; return 0 }
    var bool: Bool { if case .bool(let v) = self { return v }; return false }
    var string: String { if case .string(let v) = self { return v }; return "" }
    var array: [JSONValue] { if case .array(let v) = self { return v }; return [] }

    /// Keep new engine defaults, restore known fields, and discard removed fields.
    /// A saved `null` stays where `nullable` (the catalog's `nullable_paths`,
    /// `[*]` for every element) says it is a value, such as an infinite
    /// Langmuir knee, rather than falling back to the default.
    func restoring(_ saved: JSONValue, nullable: Set<String> = [], at path: String = "") -> JSONValue {
        switch (self, saved) {
        case (_, .null) where nullable.contains(path): return saved
        case (.object(let defaults), .object(let values)):
            var result = defaults
            for (key, value) in values {
                guard let fallback = defaults[key] else { continue }
                result[key] = fallback.restoring(value, nullable: nullable, at: path.isEmpty ? key : "\(path).\(key)")
            }
            return .object(result)
        case (.array(let defaults), .array(let values)) where defaults.count == values.count:
            return .array(zip(defaults, values).map { $0.restoring($1, nullable: nullable, at: "\(path)[*]") })
        case (.number, .number), (.bool, .bool), (.string, .string), (.null, _): return saved
        default: return self
        }
    }
}

struct Stock: Identifiable, Sendable {
    let id: String
    let name: String
    let paper: Bool
    let positive: Bool
    let bw: Bool
    let target: String
    let times: [Double]
    /// The resolved grain preset, per field of `Stock.grainFields`.
    let grain: JSONValue
    /// Ported from Fotufilm; and, for those, whether from the manufacturer's
    /// data rather than modelled from sample photographs (Settings › Fotufilm films).
    let fotufilm: Bool
    let manufacturerData: Bool
    /// Prepared by Negs itself from datasheets (Settings › Show Negs-built films).
    let negsBuilt: Bool
    /// How many stops each camera colour filter takes on this film, by key;
    /// empty for colour films and papers.
    let filterStops: [String: Double]
    static let grainFields = ["rms_granularity", "density_min", "uniformity", "particle_scale_sublayers"]
    /// The DIR gammas and halation baseline the film's presets fill while the
    /// edit leaves them unset (`null`).
    static let dirHalationPaths = [
        "film_render.dir_couplers.gamma_samelayer_rgb", "film_render.dir_couplers.gamma_interlayer_r_to_gb",
        "film_render.dir_couplers.gamma_interlayer_g_to_rb", "film_render.dir_couplers.gamma_interlayer_b_to_rg",
        "film_render.halation.halation_strength", "film_render.halation.halation_first_sigma_um"
    ]
    /// Every value a film's presets fill. Choosing a film resets them, as
    /// upstream re-applies its presets on a stock change.
    static let presetPaths = grainFields.map { "film_render.grain.\($0)" } + dirHalationPaths

    init(_ value: JSONValue) {
        id = value["id"].string; name = value["name"].string
        paper = value["paper"].bool; positive = value["positive"].bool; bw = value["bw"].bool
        target = value["target_print"].string
        times = value["development_times"].array.map(\.double)
        grain = value["grain"]
        // A catalog from before these fields lists every film.
        fotufilm = value["fotufilm"].bool
        manufacturerData = value["manufacturer_data"] != .bool(false)
        negsBuilt = value["negs_built"].bool
        filterStops = (value["color_filter_stops"].object ?? [:]).mapValues(\.double)
    }
}

/// Settings › Show Negs-built films: the films Negs prepared itself from
/// datasheets (catalog `negs_built`) stay out of the film menus and the tray
/// until shown. Only the lists, as for Fotufilm films: an edit, a preset or a
/// thumbnail with one keeps it.
enum NegsBuiltFilms {
    static let key = "showNegsBuiltFilms"
    static let hint = "Films Negs prepared itself from Fujifilm’s datasheets, still being checked: the Eterna cine films; Pro 160S, 160C and 800Z, Superia 1600 and True Definition 400; and the Velvia 100F, Provia 400F and 400X, Sensia and 64T slides. Photos already using one keep it."

    static func lists(_ stock: Stock, shown: Bool) -> Bool { shown || !stock.negsBuilt }
}

/// A camera colour filter from the catalog: its params key, the colour it's
/// named by, the measured glass, and the glass's colour for its disc.
struct ColorFilter: Identifiable, Equatable, Sendable {
    let key: String
    let name: String
    let glass: String
    let colour: UInt32
    var id: String { key }

    init(_ value: JSONValue) {
        key = value["key"].string; name = value["name"].string; glass = value["glass"].string
        colour = UInt32(value["colour"].string.dropFirst(), radix: 16) ?? 0x888888
    }

    static let path = "camera.color_filter"
    static let none = "none"
    /// What each filter does to a black-and-white photograph.
    static func effect(_ key: String) -> String {
        switch key {
        case "hoya_x1": return "Lightens foliage; darkens red lips and skin a little, for a tanned look."
        case "hoya_x0": return "Lightens foliage and darkens the sky a little. Kind to skin outdoors."
        case "hoya_y2": return "Darkens blue sky a touch so clouds stand out. The everyday filter."
        case "hoya_ya3": return "Darker sky, stronger clouds, less haze. Hides freckles and blemishes."
        case "hoya_r1": return "Near-black blue sky, bright red and brick, pale skin and lips. Cuts haze hard."
        default: return "No glass in front of the lens."
        }
    }
}

/// Enlarger › Shifts move: how the magenta and yellow shift sliders move
/// each other (bazdesh's three-way switch, forum #111). Together is the
/// red↔cyan axis (tiban, #106). Linked, they also reset together. A preference of the app, not of the edit:
/// the edit still holds just the two shifts, so presets are unchanged.
enum FilterLink: String, CaseIterable {
    case separate, together, opposite
    static let key = "filterShiftLink"
    static let magenta = "enlarger.m_filter_shift"
    static let yellow = "enlarger.y_filter_shift"
    static let range: ClosedRange<Double> = -50...50

    var title: String {
        switch self {
        case .separate: "Separately"
        case .together: "Together"
        case .opposite: "Opposite ways"
        }
    }

    /// The two shifts after moving `path` to `value` (already snapped). The
    /// other moves by the same change, so their gap (Together) or sum
    /// (Opposite) holds, with no jump on switching; at either end of the
    /// range both stop.
    func shifts(moving path: String, to value: Double, magenta: Double, yellow: Double) -> (magenta: Double, yellow: Double) {
        let movingMagenta = path == Self.magenta
        let (current, other) = movingMagenta ? (magenta, yellow) : (yellow, magenta)
        guard self != .separate else { return movingMagenta ? (value, yellow) : (magenta, value) }
        let sign: Double = self == .together ? 1 : -1
        // The other's room to move, in the moving slider's direction.
        let (low, high) = sign > 0 ? (Self.range.lowerBound - other, Self.range.upperBound - other)
                                   : (other - Self.range.upperBound, other - Self.range.lowerBound)
        let delta = min(max(value - current, min(low, 0)), max(high, 0))
        let (moved, followed) = (current + delta, other + sign * delta)
        return movingMagenta ? (moved, followed) : (followed, moved)
    }
}

/// Settings › Fotufilm films: which of the films ported from Fotufilm the
/// film menus and the tray list. Only the lists: an edit, a preset or a
/// thumbnail with a hidden film keeps it.
enum FotufilmFilms: String, CaseIterable {
    case all, datasheets, off
    static let key = "fotufilmFilms"

    var title: String {
        switch self {
        case .all: "All"
        case .datasheets: "From datasheets"
        case .off: "None"
        }
    }

    func lists(_ stock: Stock) -> Bool {
        switch self {
        case .all: true
        case .datasheets: !stock.fotufilm || stock.manufacturerData
        case .off: !stock.fotufilm
        }
    }
}

/// Stocks of one kind, in catalog order, for sectioned stock menus.
struct StockGroup: Identifiable {
    let title: String
    let stocks: [Stock]
    var id: String { title }

    static func films(_ films: [Stock], papers: [Stock]) -> [StockGroup] {
        let cinemaPrints = Set(papers.filter(\.isMotionPicturePrint).map(\.id))
        return group(films, order: ["Color Negative", "Color Slide", "Motion Picture", "Black & White"]) {
            $0.bw ? "Black & White" : $0.positive ? "Color Slide" : cinemaPrints.contains($0.target) ? "Motion Picture" : "Color Negative"
        }
    }

    static func papers(_ papers: [Stock]) -> [StockGroup] {
        group(papers, order: ["Color Paper", "Motion Picture Print", "Black & White"]) {
            $0.bw ? "Black & White" : $0.isMotionPicturePrint ? "Motion Picture Print" : "Color Paper"
        }
    }

    /// The stocks matching every word of `query` in their name, id or group
    /// title, ignoring case and accents ("portra 160", "kodak slide");
    /// groups left empty drop out.
    static func matching(_ query: String, in groups: [StockGroup]) -> [StockGroup] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return groups }
        return groups.compactMap { group in
            let stocks = group.stocks.filter { stock in
                let text = "\(stock.name) \(stock.id.replacingOccurrences(of: "_", with: " ")) \(group.title)"
                return words.allSatisfy { text.localizedStandardContains($0) }
            }
            return stocks.isEmpty ? nil : StockGroup(title: group.title, stocks: stocks)
        }
    }

    private static func group(_ stocks: [Stock], order: [String], kind: (Stock) -> String) -> [StockGroup] {
        let grouped = Dictionary(grouping: stocks, by: kind)
        return order.compactMap { title in grouped[title].map { StockGroup(title: title, stocks: $0) } }
    }
}

extension Stock {
    var isMotionPicturePrint: Bool { paper && (name.contains("Vision") || name.contains("Print Film")) }

    /// Short, photography-focused hover help for stock pickers and preview tiles.
    /// Specific notes are limited to well-documented stocks; the category
    /// fallback stays useful for profiles without manufacturer descriptions.
    var guidance: String {
        let known: [String: String] = [
            "kodak_portra_160": "A fine-grained color-negative profile with natural skin tones and smooth color. Commonly used for portraits, weddings, and detailed people photography.",
            "kodak_portra_400": "A versatile color-negative profile known for natural skin tones and smooth color. Commonly used for portraits, weddings, and mixed-light assignments.",
            "kodak_portra_800": "A faster color-negative profile with Portra-style natural color. Useful for portraits and events when light is limited or subjects are moving.",
            "kodak_ektar_100": "A fine-grained, sharply rendered color-negative profile with vivid, saturated color. Often used for landscapes, travel, fashion, products, and outdoor work.",
            "kodak_gold_200": "A warm, lively everyday color-negative profile. A familiar choice for daylight snapshots, family photos, and travel.",
            "fujifilm_c200": "A balanced everyday color-negative profile. Commonly used for family, travel, and daylight photography.",
            "fujifilm_pro_160ns": "A fine-grained professional color-negative profile with restrained, natural color. Often used for portraits, weddings, and studio work.",
            "fujifilm_pro_400h": "A soft, fine-grained color-negative profile with gentle color and skin tones. Often chosen for portraits and weddings.",
            "fujifilm_astia_100f": "A color-slide profile with softer contrast and more restrained color than vivid slide stocks. Often used for portraits and fashion.",
            "fujifilm_provia_100f": "A fine-grained color-slide profile with balanced, clean color. A versatile choice for travel, nature, editorial, and product photography.",
            "fujifilm_velvia_50": "A fine-grained color-slide profile with very vivid, saturated color. Often used for landscapes, nature, fashion, and products when bold color is wanted.",
            "fujifilm_velvia_100": "A vivid, saturated color-slide profile with fine detail. Often used for landscapes, nature, and travel photography.",
            "kodak_ektachrome_100": "A fine-grained daylight color-slide profile with clean, vibrant color. Often used for landscapes, nature, fashion, and products.",
            "ilford_hp5_plus": "A fast, flexible black-and-white negative profile. Commonly used for available-light, documentary, travel, action, and everyday photography.",
            "ilford_delta_3200": "A very high-speed black-and-white profile for dim conditions. Useful for concerts, interiors, night scenes, and available-light portraits.",
            "ilford_fp4_plus": "A fine-grained, moderate-speed black-and-white profile for detailed tonal rendering. Often used for portraits, still life, and landscapes.",
            "kodak_tri_x_400": "A classic, fast black-and-white negative profile with pronounced texture. Often used for street, documentary, and available-light photography.",
            "cinestill_800t": "A high-speed, tungsten-balanced color-negative profile. Often used for night scenes, interiors, and mixed artificial lighting.",
            "cinestill_400d": "A daylight-balanced color-negative profile with broad everyday flexibility. Useful for portraits, events, and outdoor scenes.",
            "kodak_portra_endura": "A professional color-print paper profile designed for color-negative prints. Commonly used for portraits, weddings, and exhibition prints.",
            "fujifilm_crystal_archive_typeii": "A color photographic-paper profile for finishing color-negative images. A general-purpose choice for portraits, events, and everyday prints.",
            "ilford_mgrc_deluxe_grade2": "A grade 2 black-and-white enlarging-paper profile for silver-gelatin-style monochrome prints with moderate contrast.",
        ]
        if let text = known[id] { return text }
        if paper {
            if isMotionPicturePrint {
                return "A motion-picture print-stock profile for making positive copies from cinema negatives. Typically used in film-printing and projection workflows."
            }
            if bw {
                return "A black-and-white photographic-paper profile for monochrome prints. Typically used for darkroom-style silver prints and tonal fine-art work."
            }
            return "A color photographic-paper profile used to finish color-negative images. Typically chosen for portraits, events, and general color prints."
        }
        if isMotionPicturePrint || name.localizedCaseInsensitiveContains("Eterna") || name.localizedCaseInsensitiveContains("Vision") {
            return "A motion-picture color-negative profile with a cinematic palette. Typically used for narrative scenes, controlled lighting, and film-style color work."
        }
        if positive {
            return "A color-reversal (slide) profile that produces a direct positive with vivid color and tighter exposure latitude than negative film. Often used for landscapes, travel, and product photography."
        }
        if bw {
            return "A black-and-white negative profile for monochrome images. Commonly used for documentary, street, portrait, and fine-art photography."
        }
        return "A color-negative profile with flexible tonal rendering. A versatile choice for portraits, everyday photography, and scenes intended for color printing."
    }
}

/// Human-readable names for engine option identifiers.
func optionTitle(_ option: String) -> String {
    let titles = [
        "average": "Average", "median": "Median", "center_weighted": "Center-Weighted", "partial": "Partial",
        "matrix": "Matrix", "multi_zone": "Multi-Zone", "highlight_weighted": "Highlight-Weighted",
        "as_shot": "As Shot", "daylight": "Daylight", "tungsten": "Tungsten", "custom": "Custom",
        "black_pro_mist": "Black Pro-Mist", "glimmerglass": "Glimmerglass", "pro_mist": "Pro-Mist", "cinebloom": "CineBloom",
        "off": "Off", "oklch": "OKLCh", "oklrab": "OKLrab", "cam16ucs": "CAM16-UCS", "aces_rgc": "ACES RGC", "xy": "xy Chromaticity",
        "hanatos2025": "Hanatos 2025", "arctic2026beta04": "Arctic 2026 (Beta 04)", "mallett2019": "Mallett 2019"
    ]
    return titles[option] ?? option.replacingOccurrences(of: "_", with: " ").capitalized
}

/// The exposure that matches the camera's brightness, solved live for the
/// settings it depends on. `prep.exposure_ev` holds the total the engine
/// sees; the Exposure slider shows and edits the part above `ev`.
struct BrightnessMatch: Codable, Equatable, Sendable {
    /// The solved Prep exposure; nil until the first solve.
    var ev: Double?
    /// `EditorModel.matchInputs` the value was solved for.
    var inputs: JSONValue?
    /// The solve held exposure back to keep highlights off paper white.
    var highlightLimited = false
}

struct EditState: Codable, Equatable, Sendable {
    var params: JSONValue = .object([:])
    var film = "kodak_gold_200"
    var paper = "kodak_portra_endura"
    var limitPreview = false
    /// Drawn around the developed photograph; not part of the render.
    var border = BorderSettings()
    /// Trims the developed photograph; not part of the render.
    var crop = CropSettings()
    /// Prep › Match camera brightness: present while it's on. Sessions from
    /// before it decode as off and keep their exposure.
    var brightnessMatch: BrightnessMatch?
    /// A scanned negative printed as a frame of a darkroom roll (§9.2).
    /// The frame's params hold what it prints with; this says which roll.
    var roll: NegativeRoll?

    /// The state without presentation-only settings, to decide whether an
    /// edit needs a new render. The preview is never rotated or flipped: the
    /// canvas turns it, and saving and exporting rotate the result. With an Image
    /// Size target the crop's extent sets the working size, so it stays; its
    /// position, angle and ratio never change the render.
    var rendered: EditState {
        var state = self; state.border = BorderSettings(); state.crop = CropSettings(); state.brightnessMatch = nil; state.roll = nil
        if ImageSize.mode(of: params) == .longestSide, crop.cropped {
            state.crop.rect = CGRect(origin: .zero, size: crop.rect.size)
        }
        state.params["io.rotate_cw"] = .null; state.params["io.flip"] = .null
        return state
    }
}

/// One of the two per-photograph comparison slots.
struct SavedEditVersion: Equatable, Sendable, Identifiable {
    var slot: Int
    var state: EditState
    var id: Int { slot }
    var name: String { "Version \(slot)" }
}
