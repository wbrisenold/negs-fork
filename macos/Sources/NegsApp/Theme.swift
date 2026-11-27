import AppKit
import CoreText
import os
import SwiftUI

/// The Negs studio design tokens. Keep the chrome neutral around the image;
/// use the warm Omarchy accent for navigation and selection, never image data.
enum Theme {
    /// AppKit views and layers refresh their one-time colours after the theme changes.
    static let didChange = Notification.Name("NegsThemeDidChange")
    static var palette: Palette { ThemeStore.shared.palette }
    static var colorScheme: ColorScheme { palette.dark ? .dark : .light }
    static var appearance: NSAppearance? { NSAppearance(named: palette.dark ? .darkAqua : .aqua) }

    // MARK: Colour, sRGB

    /// The colour tokens as 0xRRGGBB, for the contrast tests and the hex
    /// lookups below.
    enum Hex {
        /// The sheet the photograph lies on (canvas, grid).
        static let bg: UInt32 = 0x1B1B1B
        static let panel: UInt32 = 0x262626
        /// Warm raised surface for inspector cards, distinct from the rail.
        static let card: UInt32 = 0x2B2B2B
        static let cardLine: UInt32 = 0x3A3A3A
        static let film: UInt32 = 0x121212
        static let line: UInt32 = 0x3A3A3A
        static let track: UInt32 = 0x555555
        static let dim: UInt32 = 0x969696
        static let label: UInt32 = 0xC8C8C8
        static let paper: UInt32 = 0xF1F1F1
        /// Omarchy / Gruvbox inspired amber over Resolve graphite.
        static let accent: UInt32 = 0xD79921
        static let warn: UInt32 = 0xEF7265
        static let onAccent: UInt32 = 0x171717
        static let blank: UInt32 = 0x222222
    }

    static let bg = color(Hex.bg), panel = color(Hex.panel), film = color(Hex.film)
    static let card = color(Hex.card), cardLine = color(Hex.cardLine)
    static let line = color(Hex.line), track = color(Hex.track), dim = color(Hex.dim)
    static let label = color(Hex.label), paper = color(Hex.paper), accent = color(Hex.accent)
    static let warn = color(Hex.warn), onAccent = color(Hex.onAccent), blank = color(Hex.blank)

    /// The same tokens for AppKit and Core Animation.
    enum NS {
        static let bg = nsColor(Hex.bg), panel = nsColor(Hex.panel), film = nsColor(Hex.film)
        static let card = nsColor(Hex.card), cardLine = nsColor(Hex.cardLine)
        static let line = nsColor(Hex.line), track = nsColor(Hex.track), dim = nsColor(Hex.dim)
        static let label = nsColor(Hex.label), paper = nsColor(Hex.paper), accent = nsColor(Hex.accent)
        static let warn = nsColor(Hex.warn), onAccent = nsColor(Hex.onAccent), blank = nsColor(Hex.blank)
    }

    /// Text selection: the pencil at 0.32, never system blue (§4.9).
    static let selection = accent.opacity(0.32)
    /// Outside the crop box the photograph darkens with this (§4.10).
    static let cropShade = Color(.sRGB, red: 8 / 255, green: 7 / 255, blue: 6 / 255, opacity: 0.6)
    /// Disabled controls fade to this opacity (§2.1: 0.35–0.38).
    static let disabledOpacity = 0.36
    /// Strip frames other than the current one (§4.4).
    static let stripDim = 0.42

    static func color(_ hex: UInt32, opacity: Double = 1) -> Color {
        let (r, g, b) = components(hex)
        return Color(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
    static func nsColor(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        let (r, g, b) = components(hex)
        return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
    static func components(_ hex: UInt32) -> (Double, Double, Double) {
        (Double((hex >> 16) & 0xff) / 255, Double((hex >> 8) & 0xff) / 255, Double(hex & 0xff) / 255)
    }

    /// The WCAG 2 contrast ratio between two sRGB colours, 1…21.
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (hi, lo) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (hi + 0.05) / (lo + 0.05)
    }
    /// The WCAG 2 relative luminance of an sRGB colour, 0…1.
    static func luminance(_ hex: UInt32) -> Double {
        let (r, g, b) = components(hex)
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    // MARK: Layout, points

    enum Size {
        static let titleBar: CGFloat = 44
        static let inspector: CGFloat = 404
        static let inspectorSmallest: CGFloat = 340
        static let gutter: CGFloat = 22
        static let row: CGFloat = 29
        /// Fitted to the longest slider label (“Developer exhaustion”, 122 pt)
        /// and the widest value in bold, so the track gets the rest (round 26);
        /// `InspectorLayoutTests` checks every slider still fits.
        static let sliderLabel: CGFloat = 132
        static let valueWidth: CGFloat = 46
        static let strip: CGFloat = 132
        static let stripTopPadding: CGFloat = 6
        static let stripRebate: CGFloat = 12
        static let stripGap: CGFloat = 4
        /// The develop workspace's thumbnail and stock rail.
        static let photoRail: CGFloat = 196
        static let photoRailThumbnail: CGFloat = 168
        static let statusLine: CGFloat = 28
        static let tray: CGFloat = strip + statusLine
        static let gridGap: CGFloat = 6
        static let gridThumbnail: CGFloat = 176
        /// Space round the photograph: the caption above, two label rows below, always.
        static let stageHorizontal: CGFloat = 48
        static let stageTop: CGFloat = 54
        static let stageBottom: CGFloat = 68
        static let smallestWindow = CGSize(width: 980, height: 560)
        static let sectionHead: CGFloat = 34
        static let tabRow: CGFloat = 50
        static let paneHeader: CGFloat = 42
        static let moduleRow: CGFloat = 37
        /// The keyboard focus box: 1.5 pt `paper`, 5 pt outside, radius 3 (§4.13).
        static let focusOutset: CGFloat = 5
        static let focusLine: CGFloat = 1.5
        static let focusRadius: CGFloat = 3
    }

    // MARK: Type

    /// JetBrains Mono supplies the compact, deliberate Omarchy typography.
    static func text(_ size: CGFloat, weight: CGFloat = 400, italic: Bool = false) -> Font {
        ensureJetBrainsMonoRegistered()
        let name = italic ? "JetBrainsMono-Italic" : "JetBrainsMono-Regular"
        return Font.custom(name, size: size, relativeTo: .body).weight(swiftWeight(weight)).monospacedDigit()
    }
    /// The same system face as a Core Text font, for AppKit controls.
    static func textFont(_ size: CGFloat, weight: CGFloat = 400, italic: Bool = false) -> CTFont {
        let key = FontKey(size: size, weight: weight, italic: italic)
        if let font = fontCache.withLock({ $0[key] }) { return font }
        ensureJetBrainsMonoRegistered()
        let name = italic ? "JetBrainsMono-Italic" : "JetBrainsMono-Regular"
        let font = NSFont(name: name, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: nsWeight(weight))
        let result = font as CTFont
        fontCache.withLock { $0[key] = result }
        return result
    }
    /// Compatibility for stored tests and older call sites during migration.
    static func serif(_ size: CGFloat, weight: CGFloat = 400, italic: Bool = false) -> Font {
        text(size, weight: weight, italic: italic)
    }
    static func serifFont(_ size: CGFloat, weight: CGFloat = 400, italic: Bool = false) -> CTFont {
        textFont(size, weight: weight, italic: italic)
    }
    /// Compact technical values such as dimensions, paths and render timings.
    static func metadata(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        ensureJetBrainsMonoRegistered()
        return Font.custom("JetBrainsMono-Regular", size: size, relativeTo: .body).weight(weight).monospacedDigit()
    }
    private static func swiftWeight(_ value: CGFloat) -> Font.Weight {
        value >= 700 ? .bold : value >= 600 ? .semibold : value >= 500 ? .medium : .regular
    }
    private static func nsWeight(_ value: CGFloat) -> NSFont.Weight {
        value >= 700 ? .bold : value >= 600 ? .semibold : value >= 500 ? .medium : .regular
    }
    /// Proportional UI copy keeps controls and help readable; section heads
    /// and technical values use JetBrains Mono for the Omarchy character.
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }

    private static let jetBrainsMonoRegistration: Void = {
        guard let directory = Fonts.directory() else { return }
        for name in ["JetBrainsMono-Negs.ttf", "JetBrainsMono-Negs-Italic.ttf"] {
            let fontURL = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: fontURL.path) else { continue }
            CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
        }
    }()
    private static func ensureJetBrainsMonoRegistered() { _ = jetBrainsMonoRegistration }

    struct FontKey: Hashable { let size: CGFloat, weight: CGFloat, italic: Bool }
    private static let fontCache = OSAllocatedUnfairLock(initialState: [FontKey: CTFont]())

    /// Finding and reading the bundled fonts.
    enum Fonts {
        static let upright = "Newsreader-Negs.ttf", italic = "Newsreader-Negs-Italic.ttf"

        /// The folder holding the fonts: Contents/Resources/Fonts in the app,
        /// else macos/Fonts under SPEKTRAFILM_ROOT or the working directory
        /// (`swift run`), else beside this source file (tests).
        static func directory(environment env: [String: String] = ProcessInfo.processInfo.environment,
                              resourceDir: URL? = Bundle.main.resourceURL,
                              workingDir: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) -> URL? {
            let root = env["SPEKTRAFILM_ROOT"].map { URL(fileURLWithPath: $0) } ?? workingDir
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Fonts").standardizedFileURL
            let candidates = [resourceDir?.appendingPathComponent("Fonts"), root.appendingPathComponent("macos/Fonts"),
                              root.appendingPathComponent("Fonts"), source].compactMap { $0 }
            return candidates.first {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("JetBrainsMono-Negs.ttf").path)
                    || FileManager.default.fileExists(atPath: $0.appendingPathComponent(upright).path)
            }
        }

        private static let descriptors = OSAllocatedUnfairLock<(upright: CTFontDescriptor, italic: CTFontDescriptor)?>(initialState: nil)
        private static let loading = DispatchGroup()
        private static let started = OSAllocatedUnfairLock(initialState: false)

        /// Starts reading Newsreader on another thread, at launch
        /// (applicationWillFinishLaunching). The fonts are made from the
        /// files' own descriptors, which needs no registration: registering
        /// for the process cost ≈10 ms of the main thread at launch, reading
        /// the descriptors ≈3 ms, and that now happens off it. The first font
        /// asked for waits for it (`make`).
        static func prepare(in directory: URL? = directory()) {
            guard started.withLock({ let was = $0; $0 = true; return !was }) else { return }
            loading.enter()
            DispatchQueue.global(qos: .userInteractive).async {
                load(in: directory)
                loading.leave()
            }
        }

        /// Reads both faces now. Returns whether both were found; without
        /// them the serif falls back to the system's serif (New York).
        @discardableResult
        static func load(in directory: URL? = directory()) -> Bool {
            guard let directory else { return false }
            let found = [upright, italic].compactMap {
                (CTFontManagerCreateFontDescriptorsFromURL(directory.appendingPathComponent($0) as CFURL) as? [CTFontDescriptor])?.first
            }
            guard found.count == 2 else { return false }
            let pair = (upright: found[0], italic: found[1])
            descriptors.withLock { $0 = pair }
            return true
        }
        static var loaded: Bool { descriptors.withLock { $0 != nil } }

        static func make(_ key: FontKey) -> CTFont {
            // A slow disk never holds a view up for long: past 0.2 s the
            // fallback draws, and later fonts are Newsreader once it's read.
            if started.withLock({ $0 }), !loaded { _ = loading.wait(timeout: .now() + 0.2) }
            let base = descriptors.withLock { $0.map { key.italic ? $0.italic : $0.upright } }
            guard let base else { return fallback(key) }
            let variation: [NSNumber: NSNumber] = [
                NSNumber(value: axis("wght")): NSNumber(value: Double(min(max(key.weight, 400), 700))),
                NSNumber(value: axis("opsz")): NSNumber(value: Double(min(max(key.size, 6), 72))),
            ]
            let features: [[CFString: Any]] = ["tnum", "lnum"].map { [kCTFontOpenTypeFeatureTag: $0, kCTFontOpenTypeFeatureValue: 1] }
            let descriptor = CTFontDescriptorCreateCopyWithAttributes(base, [
                kCTFontVariationAttribute: variation,
                kCTFontFeatureSettingsAttribute: features,
            ] as CFDictionary)
            return CTFontCreateWithFontDescriptor(descriptor, key.size, nil)
        }
        private static func fallback(_ key: FontKey) -> CTFont {
            let weight: NSFont.Weight = key.weight >= 650 ? .bold : key.weight >= 550 ? .semibold : key.weight >= 450 ? .medium : .regular
            var descriptor = NSFont.systemFont(ofSize: key.size, weight: weight).fontDescriptor
            descriptor = descriptor.withDesign(.serif) ?? descriptor
            if key.italic { descriptor = descriptor.withSymbolicTraits(.italic) }
            return (NSFont(descriptor: descriptor, size: key.size) ?? .systemFont(ofSize: key.size)) as CTFont
        }
        static func axis(_ tag: String) -> UInt32 { tag.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
    }

    // MARK: Marks (§2.1)

    /// The pencil stroke's width: 2.1 pt, not scaled with the stroke.
    static let pencilWidth: CGFloat = 2.1
    /// The pencil's height under a word: drawn 5–6 pt tall under the baseline.
    static let pencilHeight: CGFloat = 6
}

/// The one hand-drawn stroke reused for every underline mark: the SVG path
/// `M1 3.6 C 22 1.2, 47 5.2, 70 2.6 S 93 2.2, 99 3.4` in a 100 × 6 box,
/// stretched to the rect. Stroke it with `Theme.pencilWidth`, round caps,
/// in `accent` (`.pencil()` below).
struct PencilStroke: Shape {
    func path(in rect: CGRect) -> Path { Path(Self.cgPath(in: rect)) }

    /// For `CAShapeLayer`s: the same path, stretched to `rect`.
    static func cgPath(in rect: CGRect) -> CGPath {
        let sx = rect.width / 100, sy = rect.height / 6
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
        let path = CGMutablePath()
        path.move(to: p(1, 3.6))
        path.addCurve(to: p(70, 2.6), control1: p(22, 1.2), control2: p(47, 5.2))
        // S: the first control point mirrors (47, 5.2) about (70, 2.6).
        path.addCurve(to: p(99, 3.4), control1: p(93, 0), control2: p(93, 2.2))
        return path
    }
}

extension Shape {
    /// Strokes this shape as the pencil: 2.1 pt in `accent` (or the sheet's
    /// pencil, on the canvas), round caps.
    func pencil(_ color: Color = Theme.accent, width: CGFloat = Theme.pencilWidth) -> some View {
        stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
}

/// A loose ellipse drawn in pencil: a rounded rectangle whose four corners
/// each have their own elliptical radii, as CSS `border-radius` draws them
/// (radii that don't fit are all scaled down together, as CSS does). Draw it
/// 2 pt wide in `accent`, rotated a little (`PencilRing.tilt`).
struct PencilRing: Shape {
    /// Horizontal and vertical radii per corner, clockwise from the top left.
    struct Radii: Equatable {
        var horizontal: (CGFloat, CGFloat, CGFloat, CGFloat)
        var vertical: (CGFloat, CGFloat, CGFloat, CGFloat)
        /// Whether the values are fractions of the width and height (CSS %)
        /// rather than points.
        var relative = false

        static func == (a: Radii, b: Radii) -> Bool {
            a.horizontal == b.horizontal && a.vertical == b.vertical && a.relative == b.relative
        }
        /// Round a picked frame, tile or thumbnail, 6–7 pt outside the
        /// picture: `30 40 28 44 / 34 26 40 28`.
        static let box = Radii(horizontal: (30, 40, 28, 44), vertical: (34, 26, 40, 28))
        /// Round a number: `47% 53% 50% 50% / 56% 44% 58% 42%`.
        static let number = Radii(horizontal: (0.47, 0.53, 0.50, 0.50), vertical: (0.56, 0.44, 0.58, 0.42), relative: true)
    }
    var radii: Radii = .box

    /// The rotation a ring is drawn at: −0.8° round thumbnails, −1° round tiles.
    static let tilt = Angle.degrees(-0.8)
    static let lineWidth: CGFloat = 2
    /// How far a ring sits outside the picture it rings.
    static let outset = CGSize(width: 7, height: 6)

    func path(in rect: CGRect) -> Path { Path(Self.cgPath(in: rect, radii: radii)) }

    static func cgPath(in rect: CGRect, radii: Radii = .box) -> CGPath {
        let (w, h) = (rect.width, rect.height)
        var rx = [radii.horizontal.0, radii.horizontal.1, radii.horizontal.2, radii.horizontal.3]
        var ry = [radii.vertical.0, radii.vertical.1, radii.vertical.2, radii.vertical.3]
        if radii.relative {
            rx = rx.map { $0 * w }
            ry = ry.map { $0 * h }
        }
        // CSS: scale every radius by the smallest side / (sum of its radii).
        let f = min(1, w / (rx[0] + rx[1]), w / (rx[3] + rx[2]), h / (ry[0] + ry[3]), h / (ry[1] + ry[2]))
        rx = rx.map { $0 * f }
        ry = ry.map { $0 * f }
        let path = CGMutablePath()
        // An elliptical quarter: from `start` round the corner, by a cubic
        // with the usual 0.5523 control length.
        let k: CGFloat = 0.5522847
        let (x0, y0, x1, y1) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
        path.move(to: CGPoint(x: x0 + rx[0], y: y0))
        path.addLine(to: CGPoint(x: x1 - rx[1], y: y0))
        path.addCurve(to: CGPoint(x: x1, y: y0 + ry[1]), control1: CGPoint(x: x1 - rx[1] * (1 - k), y: y0), control2: CGPoint(x: x1, y: y0 + ry[1] * (1 - k)))
        path.addLine(to: CGPoint(x: x1, y: y1 - ry[2]))
        path.addCurve(to: CGPoint(x: x1 - rx[2], y: y1), control1: CGPoint(x: x1, y: y1 - ry[2] * (1 - k)), control2: CGPoint(x: x1 - rx[2] * (1 - k), y: y1))
        path.addLine(to: CGPoint(x: x0 + rx[3], y: y1))
        path.addCurve(to: CGPoint(x: x0, y: y1 - ry[3]), control1: CGPoint(x: x0 + rx[3] * (1 - k), y: y1), control2: CGPoint(x: x0, y: y1 - ry[3] * (1 - k)))
        path.addLine(to: CGPoint(x: x0, y: y0 + ry[0]))
        path.addCurve(to: CGPoint(x: x0 + rx[0], y: y0), control1: CGPoint(x: x0, y: y0 + ry[0] * (1 - k)), control2: CGPoint(x: x0 + rx[0] * (1 - k), y: y0))
        path.closeSubpath()
        return path
    }
}
