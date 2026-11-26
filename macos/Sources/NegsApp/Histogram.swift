import Foundation
import CoreImage
import IOSurface
import SwiftUI
import Vision

/// The developed photograph's tones: 256 bins per channel of the cropped
/// photograph. The border is drawn on the canvas, never in the preview, so
/// it never counts.
struct Histogram: Equatable, Sendable {
    var red = [UInt32](repeating: 0, count: 256)
    var green = [UInt32](repeating: 0, count: 256)
    var blue = [UInt32](repeating: 0, count: 256)

    static func of(_ surface: IOSurface, crop: CropSettings, maxSamples: Int = 1 << 20) -> Histogram {
        ImageScopes.of(surface, crop: crop, maxSamples: maxSamples, mode: .histogram).histogram
    }

    /// The tallest bin across the full signal range. The view uses a log
    /// transfer curve so clipping spikes remain visible without hiding detail.
    var peak: UInt32 {
        [red, green, blue].map { $0.max() ?? 0 }.max() ?? 0
    }

    /// Each channel counts the same sampled preview pixels.
    var sampleCount: Int { red.reduce(0) { $0 + Int($1) } }
}

/// RGB signal level against horizontal position in the displayed crop.
/// Bins are row-major, with level 0 at row 0 and 255 at row 255.
struct Waveform: Equatable, Sendable {
    let width: Int
    let red: [UInt32]
    let green: [UInt32]
    let blue: [UInt32]
    /// Three side-by-side channel rasters keep the RGB parade drawing
    /// independent of photo size and prevent overlaid channels washing white.
    let rgba: [UInt8]
    let sampleCount: Int

    init(width: Int = 1, red: [UInt32] = Array(repeating: 0, count: 256),
         green: [UInt32] = Array(repeating: 0, count: 256), blue: [UInt32] = Array(repeating: 0, count: 256)) {
        self.width = width; self.red = red; self.green = green; self.blue = blue
        sampleCount = Int(red.reduce(0, +))
        let peak = max(red.max() ?? 0, green.max() ?? 0, blue.max() ?? 0)
        let normalizer = log1p(Double(peak))
        let paradeWidth = width * 3
        var pixels = [UInt8](repeating: 0, count: paradeWidth * 256 * 4)
        if peak > 0 {
            func intensity(_ count: UInt32) -> UInt8 {
                // A waveform is a density trace. The old 16–100% floor made
                // every occupied bin look equally loud, turning fine detail
                // into a noisy block on high-resolution previews.
                count == 0 ? 0 : UInt8((168 * (0.035 + 0.965 * log1p(Double(count)) / normalizer)).rounded())
            }
            // Keep the channel list out of the per-bin loop: constructing it
            // for all 65,536 bins creates needless arrays on Intel.
            for (channel, counts) in [red, green, blue].enumerated() {
                for level in 0..<256 {
                    for x in 0..<width {
                        let source = level * width + x
                        let row = (255 - level) * paradeWidth
                        let value = intensity(counts[source])
                        let pixel = (row + channel * width + x) * 4
                        pixels[pixel + channel] = value
                        pixels[pixel + 3] = value
                    }
                }
            }
        }
        rgba = pixels
    }

    var image: CGImage? {
        guard sampleCount > 0, let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width * 3, height: 256, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 3 * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

struct ColorSample: Equatable, Sendable {
    let red: UInt8, green: UInt8, blue: UInt8
    var hueDegrees: Double? {
        let (r, g, b) = (Double(red) / 255, Double(green) / 255, Double(blue) / 255)
        let high = max(r, g, b), low = min(r, g, b), delta = high - low
        guard delta > 0 else { return nil }
        let hue: Double
        if high == r { hue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
        else if high == g { hue = 60 * ((b - r) / delta + 2) }
        else { hue = 60 * ((r - g) / delta + 4) }
        return hue < 0 ? hue + 360 : hue
    }
    var xy: (Double, Double) {
        let r = Self.linear(Double(red) / 255), g = Self.linear(Double(green) / 255), b = Self.linear(Double(blue) / 255)
        let x = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b
        let sum = x + y + z
        return sum > 0 ? (x / sum, y / sum) : (0, 0)
    }
    static func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
}

/// Both scopes are derived from the same bounded grid and crop transform.
/// A single surface lock/pass avoids competing background scans on every edit.
struct ImageScopes: Equatable, Sendable {
    var histogram = Histogram()
    var waveform = Waveform()
    var vectorscope = Vectorscope()
    var skinAnalysis = SkinAnalysis()

    /// BT.709 luma from the developed display-referred 8-bit RGB values.
    /// Keep the viewer diagnostics on the same signal and rounding rule.
    private static func displayLuma(red: UInt8, green: UInt8, blue: UInt8) -> UInt8 {
        UInt8((54 * Int(red) + 183 * Int(green) + 19 * Int(blue)) >> 8)
    }
    private static func encodeSRGB(_ value: Double) -> Double {
        let index = Int((max(0, min(1, value)) * 4096).rounded())
        return linearSRGBTable[index]
    }
    private static let srgbLinearByteTable = (0...255).map { ColorSample.linear(Double($0) / 255) }
    private static let linearSRGBTable = (0...4096).map { index -> Double in
        let value = Double(index) / 4096
        return value <= 0.0031308 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055
    }
    private static func saturationFalseColor(_ s: Double) -> (Double, Double, Double) {
        switch s {
        case ..<0.01: (0.00, 0.04, 0.04)
        case ..<0.03: (0.03, 0.06, 0.12)
        case ..<0.05: (0.05, 0.09, 0.19)
        case ..<0.08: (0.05, 0.17, 0.28)
        case ..<0.12: (0.13, 0.29, 0.21)
        case ..<0.16: (0.18, 0.40, 0.27)
        case ..<0.22: (0.46, 0.46, 0.46)
        case ..<0.30: (0.67, 0.65, 0.22)
        case ..<0.39: (0.62, 0.39, 0.18)
        case ..<0.50: (0.52, 0.25, 0.22)
        case ..<0.62: (0.41, 0.19, 0.16)
        case ..<0.74: (0.37, 0.07, 0.07)
        default: (0.30, 0.01, 0.01)
        }
    }

    /// Continuous rendition of the MONO-Balance palette for the CIECAM02
    /// saturation correlate. The DCTL's numeric band boundaries describe its
    /// own HSV.S × HSV.V signal and are not reused as CIECAM02 thresholds.
    private static func ciecam02FalseColor(_ saturation: Double) -> (Double, Double, Double) {
        // The sRGB gamut maximum is approximately 107.35 for blue under these
        // viewing conditions (confirmed against Colour Science on a 65³ grid).
        let position = max(0, min(1, saturation / 107.4)) * Double(ciecam02Palette.count - 1)
        let lowerIndex = min(ciecam02Palette.count - 2, Int(position))
        let amount = position - Double(lowerIndex)
        let lower = ciecam02Palette[lowerIndex], upper = ciecam02Palette[lowerIndex + 1]
        return (lower.0 + (upper.0 - lower.0) * amount,
                lower.1 + (upper.1 - lower.1) * amount,
                lower.2 + (upper.2 - lower.2) * amount)
    }

    private static let ciecam02Palette: [(Double, Double, Double)] = [
        (0.00, 0.04, 0.04), (0.03, 0.06, 0.12), (0.05, 0.09, 0.19),
        (0.05, 0.17, 0.28), (0.13, 0.29, 0.21), (0.18, 0.40, 0.27),
        (0.46, 0.46, 0.46), (0.67, 0.65, 0.22), (0.62, 0.39, 0.18),
        (0.52, 0.25, 0.22), (0.41, 0.19, 0.16), (0.37, 0.07, 0.07),
        (0.30, 0.01, 0.01)
    ]

    private static let ciecam02LA = 64 / Double.pi * 0.2
    private static let ciecam02BackgroundRatio = 0.2
    private static let ciecam02SurroundC = 0.69
    private static let ciecam02Adaptation = 1 - exp((-ciecam02LA - 42) / 92) / 3.6
    private static let ciecam02K = 1 / (5 * ciecam02LA + 1)
    private static let ciecam02K4 = pow(ciecam02K, 4)
    private static let ciecam02FL = 0.2 * ciecam02K4 * (5 * ciecam02LA)
        + 0.1 * pow(1 - ciecam02K4, 2) * pow(5 * ciecam02LA, 1 / 3)
    private static let ciecam02FLQuarter = pow(ciecam02FL, 0.25)
    private static let ciecam02NBB = 0.725 * pow(1 / ciecam02BackgroundRatio, 0.2)
    private static let ciecam02ZFactor = 1.48 + sqrt(ciecam02BackgroundRatio)
    private static let ciecam02ChromaScale = pow(1.64 - pow(0.29, ciecam02BackgroundRatio), 0.73)

    private static func ciecam02CAT02(_ x: Double, _ y: Double, _ z: Double) -> (Double, Double, Double) {
        (0.7328 * x + 0.4296 * y - 0.1624 * z,
         -0.7036 * x + 1.6975 * y + 0.0061 * z,
         0.0030 * x + 0.0136 * y + 0.9834 * z)
    }

    private static func ciecam02HPE(_ value: (Double, Double, Double)) -> (Double, Double, Double) {
        let x = 1.09612382 * value.0 - 0.27886900 * value.1 + 0.18274518 * value.2
        let y = 0.45436904 * value.0 + 0.47353315 * value.1 + 0.07209780 * value.2
        let z = -0.00962761 * value.0 - 0.00569803 * value.1 + 1.01532564 * value.2
        return (0.38971 * x + 0.68898 * y - 0.07868 * z,
                -0.22981 * x + 1.18340 * y + 0.04641 * z, z)
    }

    private static let ciecam02CATWhite = ciecam02CAT02(95.04559271, 100, 108.90577508)
    private static let ciecam02WhiteAchromatic: Double = {
        let white = ciecam02CATWhite
        let adaptation = ciecam02Adaptation
        let whiteAdapted = (100 * adaptation + (1 - adaptation) * white.0,
                            100 * adaptation + (1 - adaptation) * white.1,
                            100 * adaptation + (1 - adaptation) * white.2)
        let whiteResponses = ciecam02HPE(whiteAdapted)
        func response(_ value: Double) -> Double {
            let compressed = pow(max(0, ciecam02FL * abs(value) / 100), 0.42)
            return 400 * (value < 0 ? -1 : 1) * compressed / (27.13 + compressed) + 0.1
        }
        let raw = response(whiteResponses.0)
        let gaw = response(whiteResponses.1)
        let baw = response(whiteResponses.2)
        return (2 * raw + gaw + baw / 20 - 0.305) * ciecam02NBB
    }()

    private static func ciecam02Response(_ value: Double) -> Double {
        let compressed = pow(max(0, ciecam02FL * abs(value) / 100), 0.42)
        return 400 * (value < 0 ? -1 : 1) * compressed / (27.13 + compressed) + 0.1
    }

    /// CIECAM02 saturation correlate s under the published sRGB reference
    /// viewing conditions: D65 white, average surround, Yb=20, La=64/pi*0.2.
    /// Input is linear sRGB and output is the CIECAM02 saturation correlate.
    private static func ciecam02Saturation(linearR r: Double, g: Double, b: Double) -> Double {
        let x = 41.24564 * r + 35.75761 * g + 18.04375 * b
        let y = 21.26729 * r + 71.51522 * g + 7.21750 * b
        let z = 1.93339 * r + 11.91920 * g + 95.03040 * b

        let rgb = Self.ciecam02CAT02(x, y, z)
        let white = Self.ciecam02CATWhite
        let adaptation = Self.ciecam02Adaptation
        let rgbc = ((100 * adaptation / white.0 + 1 - adaptation) * rgb.0,
                    (100 * adaptation / white.1 + 1 - adaptation) * rgb.1,
                    (100 * adaptation / white.2 + 1 - adaptation) * rgb.2)

        // HPE × inverse CAT02, as specified for the CIECAM02 post-adaptation
        // cone responses. Fixed viewing-condition values are cached above.
        let rgbp = Self.ciecam02HPE(rgbc)
        let whiteAchromatic = Self.ciecam02WhiteAchromatic
        let ra = Self.ciecam02Response(rgbp.0)
        let ga = Self.ciecam02Response(rgbp.1)
        let ba = Self.ciecam02Response(rgbp.2)
        let achromatic = (2 * ra + ga + ba / 20 - 0.305) * Self.ciecam02NBB
        guard achromatic > 0, whiteAchromatic > 0 else { return 0 }
        let j = 100 * pow(achromatic / whiteAchromatic, Self.ciecam02SurroundC * Self.ciecam02ZFactor)
        guard j > 0 else { return 0 }
        let q = (4 / Self.ciecam02SurroundC) * sqrt(j / 100) * (whiteAchromatic + 4) * Self.ciecam02FLQuarter
        let a = ra - 12 * ga / 11 + ba / 11
        let opponentB = (ra + ga - 2 * ba) / 9
        let hueRadians = atan2(opponentB, a)
        let eccentricity = 0.25 * (cos(hueRadians + 2) + 3.8)
        let denominator = ra + ga + 1.05 * ba
        guard denominator > 0, q > 0 else { return 0 }
        let tNumerator = (50000 / 13) * Self.ciecam02NBB * eccentricity * hypot(a, opponentB)
        let t = tNumerator / denominator
        let chroma = pow(max(0, t), 0.9) * sqrt(j / 100) * Self.ciecam02ChromaScale
        let colorfulness = chroma * Self.ciecam02FLQuarter
        let saturation = 100 * sqrt(max(0, colorfulness / q))
        return saturation.isFinite ? saturation : 0
    }


    private static func exposureFalseColor(_ luma: Double) -> (Double, Double, Double) {
        switch luma {
        case 0.956...: (0.19, 0.01, 0.01)
        case 0.911...: (0.26, 0.05, 0.05)
        case 0.836...: (0.33, 0.15, 0.07)
        case 0.728...: (0.44, 0.25, 0.13)
        case 0.596...: (0.62, 0.39, 0.18)
        case 0.457...: (0.67, 0.65, 0.22)
        case 0.328...: (0.46, 0.46, 0.46)
        case 0.222...: (0.18, 0.40, 0.27)
        case 0.140...: (0.13, 0.29, 0.21)
        case 0.077...: (0.05, 0.17, 0.28)
        case 0.038...: (0.05, 0.09, 0.19)
        case 0.019...: (0.04, 0.05, 0.10)
        default: (0.00, 0.04, 0.04)
        }
    }

    /// Transparent false-colour mask for clipped highlights (red) and
    /// crushed shadows (blue). Highlights include either clipped luma or an
    /// individually clipped RGB channel, so saturated colour clipping is
    /// visible even when the weighted luma remains below white. Generated
    /// only when the viewer overlay is on.
    static func clippingOverlay(_ surface: IOSurface, low: Double, high: Double,
                                clippedHighlights: Data? = nil) -> CGImage? {
        guard surface.width > 0, surface.height > 0, surface.bytesPerElement == 4,
              surface.planeCount <= 1, !Task.isCancelled else { return nil }
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let sourceWidth = surface.width, sourceHeight = surface.height
        // Two megapixels retains screen-scale clipping detail while keeping
        // slider-driven refreshes cheap enough to finish before the next frame.
        let scale = min(1.0, sqrt(Double(1 << 21) / Double(sourceWidth * sourceHeight)))
        let width = max(1, Int((Double(sourceWidth) * scale).rounded()))
        let height = max(1, Int((Double(sourceHeight) * scale).rounded()))
        let source = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        let rowBytes = surface.bytesPerRow
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            if Task.isCancelled { return nil }
            let sy = min(sourceHeight - 1, Int((Double(y) + 0.5) * Double(sourceHeight) / Double(height)))
            for x in 0..<width {
                let sx = min(sourceWidth - 1, Int((Double(x) + 0.5) * Double(sourceWidth) / Double(width)))
                let src = sy * rowBytes + sx * surface.bytesPerElement
                let r = source[src + 2], g = source[src + 1], b = source[src]
                let offset = (y * width + x) * 4
                // Match false colour's luma exactly. The red indicator still
                // means actual output clipping; false colour starts its top
                // highlight band earlier, at 96 IRE.
                let y = Double(displayLuma(red: r, green: g, blue: b)) / 255
                let channelClipped = Double(max(r, max(g, b))) / 255 >= high
                let scanClipped = clippedHighlights.flatMap { mask in
                    mask.count == sourceWidth * sourceHeight ? mask[sy * sourceWidth + sx] > 0 : nil
                } ?? false
                if y <= low {
                    rgba[offset] = 12; rgba[offset + 1] = 34; rgba[offset + 2] = 230; rgba[offset + 3] = 230
                } else if y >= high || channelClipped || scanClipped {
                    rgba[offset] = 230; rgba[offset + 1] = 18; rgba[offset + 2] = 12; rgba[offset + 3] = 230
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// False-colour exposure map for the developed display-referred frame.
    /// It is generated only while enabled and capped at one megapixel so it
    /// remains a lightweight diagnostic overlay rather than a develop stage.
    static func falseColorOverlay(_ surface: IOSurface) -> CGImage? {
        guard surface.width > 0, surface.height > 0, surface.bytesPerElement == 4,
              surface.planeCount <= 1, !Task.isCancelled else { return nil }
        let isRec2020 = EditorModel.displaySpace(of: surface) == "Rec. 2020 (sRGB transfer)"
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let sourceWidth = surface.width, sourceHeight = surface.height
        let scale = min(1.0, sqrt(Double(1 << 20) / Double(sourceWidth * sourceHeight)))
        let width = max(1, Int((Double(sourceWidth) * scale).rounded()))
        let height = max(1, Int((Double(sourceHeight) * scale).rounded()))
        let source = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        let rowBytes = surface.bytesPerRow
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            if Task.isCancelled { return nil }
            let sy = min(sourceHeight - 1, Int((Double(y) + 0.5) * Double(sourceHeight) / Double(height)))
            for x in 0..<width {
                let sx = min(sourceWidth - 1, Int((Double(x) + 0.5) * Double(sourceWidth) / Double(width)))
                let src = sy * rowBytes + sx * surface.bytesPerElement
                var r = Double(source[src + 2]) / 255
                var g = Double(source[src + 1]) / 255
                var b = Double(source[src]) / 255
                if isRec2020 {
                    r = Self.srgbLinearByteTable[Int(source[src + 2])]
                    g = Self.srgbLinearByteTable[Int(source[src + 1])]
                    b = Self.srgbLinearByteTable[Int(source[src])]
                    let xx = 0.636958 * r + 0.144617 * g + 0.168881 * b
                    let yy = 0.262700 * r + 0.677998 * g + 0.059302 * b
                    let zz = 0.028073 * r + 0.163020 * g + 0.808907 * b
                    r = Self.encodeSRGB(max(0, min(1, 3.240454 * xx - 1.537139 * yy - 0.498531 * zz)))
                    g = Self.encodeSRGB(max(0, min(1, -0.969266 * xx + 1.876011 * yy + 0.041556 * zz)))
                    b = Self.encodeSRGB(max(0, min(1, 0.055643 * xx - 0.204026 * yy + 1.057225 * zz)))
                }
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                let color = Self.exposureFalseColor(luma)
                let offset = (y * width + x) * 4
                rgba[offset] = UInt8((color.0 * 255).rounded())
                rgba[offset + 1] = UInt8((color.1 * 255).rounded())
                rgba[offset + 2] = UInt8((color.2 * 255).rounded())
                rgba[offset + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func saturationFalseColorOverlay(_ surface: IOSurface) -> CGImage? {
        saturationOverlay(surface, mode: .monoBalance)
    }

    static func ciecam02SaturationOverlay(_ surface: IOSurface) -> CGImage? {
        saturationOverlay(surface, mode: .ciecam02)
    }

    private static func saturationOverlay(_ surface: IOSurface, mode: SaturationOverlayMode) -> CGImage? {
        guard surface.width > 0, surface.height > 0, surface.bytesPerElement == 4,
              surface.planeCount <= 1, !Task.isCancelled else { return nil }
        let isRec2020 = EditorModel.displaySpace(of: surface) == "Rec. 2020 (sRGB transfer)"
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let sourceWidth = surface.width, sourceHeight = surface.height
        // Half a megapixel is enough to diagnose a full-window preview. Keep
        // this pass light enough to regenerate during slider interaction.
        let scale = min(1.0, sqrt(Double(1 << 19) / Double(sourceWidth * sourceHeight)))
        let width = max(1, Int((Double(sourceWidth) * scale).rounded()))
        let height = max(1, Int((Double(sourceHeight) * scale).rounded()))
        let source = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            if Task.isCancelled { return nil }
            let sy = min(sourceHeight - 1, Int((Double(y) + 0.5) * Double(sourceHeight) / Double(height)))
            for x in 0..<width {
                let sx = min(sourceWidth - 1, Int((Double(x) + 0.5) * Double(sourceWidth) / Double(width)))
                let src = sy * surface.bytesPerRow + sx * surface.bytesPerElement
                let encodedR = Double(source[src + 2]) / 255
                let encodedG = Double(source[src + 1]) / 255
                let encodedB = Double(source[src]) / 255
                var red = encodedR
                var green = encodedG
                var blue = encodedB
                if isRec2020 {
                    red = Self.srgbLinearByteTable[Int(source[src + 2])]
                    green = Self.srgbLinearByteTable[Int(source[src + 1])]
                    blue = Self.srgbLinearByteTable[Int(source[src])]
                    let x = 0.636958 * red + 0.144617 * green + 0.168881 * blue
                    let y = 0.262700 * red + 0.677998 * green + 0.059302 * blue
                    let z = 0.028073 * red + 0.163020 * green + 0.808907 * blue
                    red = max(0, min(1, 3.240454 * x - 1.537139 * y - 0.498531 * z))
                    green = max(0, min(1, -0.969266 * x + 1.876011 * y + 0.041556 * z))
                    blue = max(0, min(1, 0.055643 * x - 0.204026 * y + 1.057225 * z))
                    red = Self.encodeSRGB(red)
                    green = Self.encodeSRGB(green)
                    blue = Self.encodeSRGB(blue)
                }
                let color: (Double, Double, Double)
                switch mode {
                case .monoBalance:
                    // MONO-Balance computes S = HSV.S * HSV.V, which simplifies
                    // to the RGB channel spread for normalized RGB.
                    let maximum = max(red, max(green, blue))
                    let minimum = min(red, min(green, blue))
                    color = Self.saturationFalseColor(maximum - minimum)
                case .ciecam02:
                    let linearR = isRec2020 ? ColorSample.linear(red) : Self.srgbLinearByteTable[Int(source[src + 2])]
                    let linearG = isRec2020 ? ColorSample.linear(green) : Self.srgbLinearByteTable[Int(source[src + 1])]
                    let linearB = isRec2020 ? ColorSample.linear(blue) : Self.srgbLinearByteTable[Int(source[src])]
                    let saturation = Self.ciecam02Saturation(linearR: linearR, g: linearG, b: linearB)
                    color = Self.ciecam02FalseColor(saturation)
                }
                let offset = (y * width + x) * 4
                rgba[offset] = UInt8((color.0 * 255).rounded())
                rgba[offset + 1] = UInt8((color.1 * 255).rounded())
                rgba[offset + 2] = UInt8((color.2 * 255).rounded())
                rgba[offset + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Skin-hue guide inspired by the Mononodes balance DCTL: hue close to
    /// the traditional line is yellow, moving magenta is magenta, and moving
    /// green is green. This is a chroma guide, not semantic skin detection.
    static func skinToneFalseColorOverlay(_ surface: IOSurface) -> CGImage? {
        guard surface.width > 0, surface.height > 0, surface.bytesPerElement == 4,
              surface.planeCount <= 1, !Task.isCancelled else { return nil }
        let isRec2020 = EditorModel.displaySpace(of: surface) == "Rec. 2020 (sRGB transfer)"
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let sourceWidth = surface.width, sourceHeight = surface.height
        let scale = min(1.0, sqrt(Double(1 << 19) / Double(sourceWidth * sourceHeight)))
        let width = max(1, Int((Double(sourceWidth) * scale).rounded()))
        let height = max(1, Int((Double(sourceHeight) * scale).rounded()))
        let source = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            if Task.isCancelled { return nil }
            let sy = min(sourceHeight - 1, Int((Double(y) + 0.5) * Double(sourceHeight) / Double(height)))
            for x in 0..<width {
                let sx = min(sourceWidth - 1, Int((Double(x) + 0.5) * Double(sourceWidth) / Double(width)))
                let src = sy * surface.bytesPerRow + sx * surface.bytesPerElement
                var r = Double(source[src + 2]) / 255
                var g = Double(source[src + 1]) / 255
                var b = Double(source[src]) / 255
                if isRec2020 {
                    r = Self.srgbLinearByteTable[Int(source[src + 2])]
                    g = Self.srgbLinearByteTable[Int(source[src + 1])]
                    b = Self.srgbLinearByteTable[Int(source[src])]
                    let xx = 0.636958 * r + 0.144617 * g + 0.168881 * b
                    let yy = 0.262700 * r + 0.677998 * g + 0.059302 * b
                    let zz = 0.028073 * r + 0.163020 * g + 0.808907 * b
                    r = Self.encodeSRGB(max(0, min(1, 3.240454 * xx - 1.537139 * yy - 0.498531 * zz)))
                    g = Self.encodeSRGB(max(0, min(1, -0.969266 * xx + 1.876011 * yy + 0.041556 * zz)))
                    b = Self.encodeSRGB(max(0, min(1, 0.055643 * xx - 0.204026 * yy + 1.057225 * zz)))
                }
                let maximum = max(r, max(g, b)), minimum = min(r, min(g, b))
                let deltaRGB = maximum - minimum
                guard deltaRGB > 0.0001 else { continue }
                let lightness = (maximum + minimum) / 2
                var hue: Double
                if maximum == r { hue = ((g - b) / deltaRGB).truncatingRemainder(dividingBy: 6) }
                else if maximum == g { hue = (b - r) / deltaRGB + 2 }
                else { hue = (r - g) / deltaRGB + 4 }
                hue *= 60
                if hue < 0 { hue += 360 }

                // MONO-Balance defaults: target hue 18.7°, skin range 5.74°,
                // and magenta/green deviation range 18.53°. Outside that
                // neighborhood the image remains unchanged.
                let skinRange = 2 + (0.5 * 0.4) * 18.7
                let deviationRange = 1.7 + (1.0 * 0.9) * 18.7
                let hueDelta = wrappedDegrees(hue - 18.7)
                let mappedHue: Double, mappedSaturation: Double
                if abs(hueDelta) < skinRange {
                    (mappedHue, mappedSaturation) = (60, 0.9)
                } else if hueDelta > 0, abs(hueDelta) < deviationRange {
                    (mappedHue, mappedSaturation) = (140, 0.6)
                } else if hueDelta < 0, abs(hueDelta) < deviationRange {
                    (mappedHue, mappedSaturation) = (300, 0.7)
                } else { continue }

                let chroma = (1 - abs(2 * lightness - 1)) * mappedSaturation
                let sector = mappedHue / 60
                let xComponent = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
                let match = lightness - chroma / 2
                let vivid: (Double, Double, Double)
                switch sector {
                case ..<1: vivid = (chroma, xComponent, 0)
                case ..<2: vivid = (xComponent, chroma, 0)
                case ..<3: vivid = (0, chroma, xComponent)
                case ..<4: vivid = (0, xComponent, chroma)
                case ..<5: vivid = (xComponent, 0, chroma)
                default: vivid = (chroma, 0, xComponent)
                }
                let color = (vivid.0 + match, vivid.1 + match, vivid.2 + match)
                let offset = (y * width + x) * 4
                rgba[offset] = UInt8((color.0 * 255).rounded())
                rgba[offset + 1] = UInt8((color.1 * 255).rounded())
                rgba[offset + 2] = UInt8((color.2 * 255).rounded())
                rgba[offset + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Highlights low-chroma pixels as neutral candidates on the finished
    /// preview. This viewing aid leaves image brightness visible for judging.
    static func neutralCandidateOverlay(_ surface: IOSurface) -> CGImage? {
        guard surface.width > 0, surface.height > 0, surface.bytesPerElement == 4,
              surface.planeCount <= 1, !Task.isCancelled else { return nil }
        let isRec2020 = EditorModel.displaySpace(of: surface) == "Rec. 2020 (sRGB transfer)"
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let sourceWidth = surface.width, sourceHeight = surface.height
        let scale = min(1.0, sqrt(Double(1 << 20) / Double(sourceWidth * sourceHeight)))
        let width = max(1, Int((Double(sourceWidth) * scale).rounded()))
        let height = max(1, Int((Double(sourceHeight) * scale).rounded()))
        let source = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            if Task.isCancelled { return nil }
            let sy = min(sourceHeight - 1, Int((Double(y) + 0.5) * Double(sourceHeight) / Double(height)))
            for x in 0..<width {
                let sx = min(sourceWidth - 1, Int((Double(x) + 0.5) * Double(sourceWidth) / Double(width)))
                let src = sy * surface.bytesPerRow + sx * surface.bytesPerElement
                var red = Double(source[src + 2]) / 255
                var green = Double(source[src + 1]) / 255
                var blue = Double(source[src]) / 255
                if isRec2020 {
                    red = Self.srgbLinearByteTable[Int(source[src + 2])]
                    green = Self.srgbLinearByteTable[Int(source[src + 1])]
                    blue = Self.srgbLinearByteTable[Int(source[src])]
                    let xx = 0.636958 * red + 0.144617 * green + 0.168881 * blue
                    let yy = 0.262700 * red + 0.677998 * green + 0.059302 * blue
                    let zz = 0.028073 * red + 0.163020 * green + 0.808907 * blue
                    red = Self.encodeSRGB(max(0, min(1, 3.240454 * xx - 1.537139 * yy - 0.498531 * zz)))
                    green = Self.encodeSRGB(max(0, min(1, -0.969266 * xx + 1.876011 * yy + 0.041556 * zz)))
                    blue = Self.encodeSRGB(max(0, min(1, 0.055643 * xx - 0.204026 * yy + 1.057225 * zz)))
                }
                let brightness = (red + green + blue) / 3
                guard abs(red - green) < 0.02, abs(green - blue) < 0.02,
                      brightness > 0.1 else { continue }
                let index = (y * width + x) * 4
                rgba[index] = 0
                rgba[index + 1] = 230
                rgba[index + 2] = 0
                rgba[index + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func of(_ surface: IOSurface, crop: CropSettings, rotation: Int = 0, maxSamples: Int = 1 << 20,
                   mode: ScopeMode? = nil) -> ImageScopes {
        guard surface.width > 0, surface.height > 0, surface.bytesPerElement == 4,
              surface.planeCount <= 1, !Task.isCancelled else { return ImageScopes() }
        let size = CGSize(width: surface.width, height: surface.height)
        let area = crop.pixels(in: size)
        guard area.width >= 1, area.height >= 1, maxSamples > 0 else { return ImageScopes() }
        let wantsHistogram = mode == nil || mode == .histogram
        let wantsWaveform = mode == nil || mode == .waveform
        let wantsVectorscope = mode == nil || mode == .vectorscope || mode == .skin
        let wantsSkin = mode == nil || mode == .skin
        let width = Int(area.width), height = Int(area.height)
        // This also bounds very thin panoramas: a single common pixel stride
        // can exceed the budget when one of the dimensions is much shorter.
        let columns = min(width, maxSamples, max(1, Int((Double(maxSamples) * Double(width) / Double(height)).squareRoot())))
        let rows = min(height, max(1, maxSamples / columns))
        let turn = (rotation % 4 + 4) % 4
        let shownColumns = turn % 2 == 0 ? columns : rows
        let waveWidth = wantsWaveform ? min(256, shownColumns) : 1
        var red = [UInt32](repeating: 0, count: wantsWaveform ? waveWidth * 256 : 0)
        var green = red, blue = red
        var histogram = Histogram()
        let vectorSize = 128
        var vectorBins = [UInt32](repeating: 0, count: wantsVectorscope ? vectorSize * vectorSize : 0)
        var skinBins = [UInt32](repeating: 0, count: wantsSkin ? vectorSize * vectorSize : 0)
        var skinAngles: Double = 0
        var skinSamples = 0
        var onTarget = 0, tooMagenta = 0, tooGreen = 0
        let sampleCount = columns * rows
        if Task.isCancelled { return ImageScopes() }
        let faceBoxes: [CGRect] = wantsSkin ? autoreleasepool {
            let request = VNDetectFaceRectanglesRequest()
            do {
                try VNImageRequestHandler(ciImage: CIImage(ioSurface: surface), options: [:]).perform([request])
                return (request.results ?? []).map { $0.boundingBox.insetBy(dx: -0.025, dy: -0.025) }
            } catch { return [] }
        } : []
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let base = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        let rowBytes = surface.bytesPerRow
        // A straightened crop is in the turned frame: turn each sample back
        // to the photograph, as CropGeometry.turn(_:by: -angle, about:).
        let (sin, cos) = (Foundation.sin(-crop.angle * .pi / 180), Foundation.cos(-crop.angle * .pi / 180))
        let (cx, cy) = (size.width / 2, size.height / 2)
        for row in 0..<rows {
            if Task.isCancelled { return ImageScopes() }
            for column in 0..<columns {
                let dx = area.minX + (Double(column) + 0.5) * area.width / Double(columns) - cx
                let dy = area.minY + (Double(row) + 0.5) * area.height / Double(rows) - cy
                let x = Int((cx + dx * cos - dy * sin).rounded(.down))
                let y = Int((cy + dx * sin + dy * cos).rounded(.down))
                guard x >= 0, x < surface.width, y >= 0, y < surface.height else { continue }
                let pixel = base + y * rowBytes + x * 4
                let (r, g, b) = (Int(pixel[2]), Int(pixel[1]), Int(pixel[0]))
                if wantsHistogram {
                    histogram.red[r] += 1; histogram.green[g] += 1; histogram.blue[b] += 1
                }
                var vx = 0, vy = 0, cr = 0.0, cb = 0.0, rf = 0.0, gf = 0.0, bf = 0.0, luma = 0.0
                if wantsVectorscope {
                    (rf, gf, bf) = (Double(r) / 255, Double(g) / 255, Double(b) / 255)
                    luma = 0.2126 * rf + 0.7152 * gf + 0.0722 * bf
                    cb = (bf - luma) / (2 * (1 - 0.0722))
                    cr = (rf - luma) / (2 * (1 - 0.2126))
                    vx = min(vectorSize - 1, max(0, Int(((cb + 0.5) * Double(vectorSize - 1)).rounded())))
                    vy = min(vectorSize - 1, max(0, Int(((0.5 - cr) * Double(vectorSize - 1)).rounded())))
                    let bin = vy * vectorSize + vx
                    vectorBins[bin] += 1
                }
                // Skin estimate follows the studio vectorscope's hue analysis,
                // limited to a broad chroma envelope. It is not a semantic mask.
                if wantsSkin {
                    let point = CGPoint(x: Double(x) / Double(surface.width), y: 1 - Double(y) / Double(surface.height))
                    let withinFace = faceBoxes.contains { $0.contains(point) }
                    let looksLikeSkin = withinFace && luma > 0.08 && cr > 0.025 && cr < 0.28 && cb > -0.18 && cb < 0.12
                        && rf > gf && gf > bf * 0.72
                    if looksLikeSkin {
                        skinSamples += 1
                        let angle = atan2(cr, cb) * 180 / .pi
                        let delta = wrappedDegrees(angle - 123)
                        skinAngles += delta
                        if abs(delta) <= 12 { onTarget += 1 }
                        else if delta < 0 { tooMagenta += 1 }
                        else { tooGreen += 1 }
                        let bin = vy * vectorSize + vx
                        skinBins[bin] += 1
                    }
                }
                guard wantsWaveform else { continue }
                let shownColumn: Int
                switch turn {
                case 1: shownColumn = rows - 1 - row
                case 2: shownColumn = columns - 1 - column
                case 3: shownColumn = row
                default: shownColumn = column
                }
                let waveX = shownColumn * waveWidth / shownColumns
                red[r * waveWidth + waveX] += 1; green[g * waveWidth + waveX] += 1; blue[b * waveWidth + waveX] += 1
            }
        }
        let analysis = SkinAnalysis(sampledPixels: sampleCount, candidatePixels: skinSamples,
            meanDeviationDegrees: skinSamples > 0 ? skinAngles / Double(skinSamples) : nil,
            withinTolerancePercent: skinSamples > 0 ? 100 * Double(onTarget) / Double(skinSamples) : 0,
            tooMagentaPercent: skinSamples > 0 ? 100 * Double(tooMagenta) / Double(skinSamples) : 0,
            tooGreenPercent: skinSamples > 0 ? 100 * Double(tooGreen) / Double(skinSamples) : 0)
        return ImageScopes(histogram: histogram,
            waveform: wantsWaveform ? Waveform(width: waveWidth, red: red, green: green, blue: blue) : Waveform(),
            vectorscope: wantsVectorscope ? Vectorscope(size: vectorSize, bins: vectorBins, skinBins: skinBins) : Vectorscope(),
            skinAnalysis: wantsSkin ? analysis : SkinAnalysis())
    }

    static func sample(_ surface: IOSurface, sourcePoint: CGPoint) -> ColorSample? {
        guard surface.width > 0, surface.height > 0, surface.bytesPerElement == 4,
              (0...1).contains(sourcePoint.x), (0...1).contains(sourcePoint.y) else { return nil }
        let x = min(Int(sourcePoint.x * CGFloat(surface.width)), surface.width - 1)
        let y = min(Int(sourcePoint.y * CGFloat(surface.height)), surface.height - 1)
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let pixel = surface.baseAddress.assumingMemoryBound(to: UInt8.self) + y * surface.bytesPerRow + x * 4
        return ColorSample(red: pixel[2], green: pixel[1], blue: pixel[0])
    }
}

private func wrappedDegrees(_ angle: Double) -> Double {
    var value = angle
    while value > 180 { value -= 360 }
    while value < -180 { value += 360 }
    return value
}

struct SkinAnalysis: Equatable, Sendable {
    var sampledPixels = 0
    var candidatePixels = 0
    var meanDeviationDegrees: Double?
    var withinTolerancePercent = 0.0
    var tooMagentaPercent = 0.0
    var tooGreenPercent = 0.0
    var candidatePercent: Double { sampledPixels > 0 ? 100 * Double(candidatePixels) / Double(sampledPixels) : 0 }
    var coveragePercent: Double { min(100, candidatePercent / 6 * 100) }
    var status: String {
        guard let meanDeviationDegrees, coveragePercent > 4 else { return "No reliable skin sample" }
        if meanDeviationDegrees < -12 { return "Too magenta" }
        if meanDeviationDegrees > 12 { return "Too green" }
        return "Near skin-tone line"
    }
}

struct Vectorscope: Equatable, Sendable {
    let size: Int
    let bins: [UInt32]
    let skinBins: [UInt32]

    init(size: Int = 128, bins: [UInt32] = [], skinBins: [UInt32] = []) {
        self.size = size
        self.bins = bins
        self.skinBins = skinBins
    }

    var sampleCount: Int { bins.reduce(0) { $0 + Int($1) } }
    var skinSampleCount: Int { skinBins.reduce(0) { $0 + Int($1) } }
}

/// Filled channels and fine outlines echo Sawmill's histogram.
struct HistogramView: View {
    let histogram: Histogram?

    var body: some View {
        Canvas { context, size in
            scopeGrid(context: &context, size: size)
            guard let histogram, histogram.peak > 0 else { return }
            let peak = log1p(Double(histogram.peak))
            for (bins, color) in [(histogram.red, Color(red: 1, green: 0.42, blue: 0.42)),
                                  (histogram.green, Color(red: 0.42, green: 0.8, blue: 0.47)),
                                  (histogram.blue, Color(red: 0.3, green: 0.59, blue: 1))] {
                var line = Path()
                for (index, count) in bins.enumerated() {
                    let density = peak > 0 ? log1p(Double(count)) / peak : 0
                    let point = CGPoint(x: size.width * CGFloat(index) / CGFloat(bins.count - 1),
                                        y: size.height * (1 - min(density, 1)))
                    if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
                }
                var fill = line
                fill.addLine(to: CGPoint(x: size.width, y: size.height))
                fill.addLine(to: CGPoint(x: 0, y: size.height))
                fill.closeSubpath()
                // A restrained source-over fill keeps overlapping channel
                // distributions from accumulating into a misleading gray slab.
                context.fill(fill, with: .color(color.opacity(0.12)))
                context.stroke(line, with: .color(color.opacity(0.9)), lineWidth: 1)
            }
            context.draw(Text("LOG  ·  PREVIEW RGB")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.dim), at: CGPoint(x: 62, y: 10))
            context.draw(Text("\(histogram.sampleCount.formatted()) px")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.dim), at: CGPoint(x: size.width - 38, y: 10))
        }
        .padding(.horizontal, 4).padding(.top, 6)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 3))
        .accessibilityElement()
        .accessibilityLabel("Histogram")
        .accessibilityValue(histogram.map { "Red, green, and blue tones of the developed preview; logarithmic vertical scale; \($0.sampleCount) pixels counted" } ?? "No developed photograph")
    }
}

struct WaveformView: View {
    let waveform: Waveform?

    var body: some View {
        HStack(spacing: 4) {
            VStack {
                ForEach([100, 75, 50, 25, 0], id: \.self) { level in
                    Text("\(level)").font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.dim)
                    if level != 0 { Spacer(minLength: 0) }
                }
            }
            .frame(width: 22)
            Canvas { context, size in
                let labelHeight: CGFloat = 13
                let plot = CGRect(x: 0, y: labelHeight, width: size.width,
                                  height: max(0, size.height - labelHeight))
                if let image = waveform?.image {
                    context.draw(Image(decorative: image, scale: 1), in: plot)
                    for (index, label) in ["R", "G", "B"].enumerated() {
                        let tint: Color = [Color(red: 1, green: 0.36, blue: 0.34),
                                           Color(red: 0.38, green: 0.9, blue: 0.48),
                                           Color(red: 0.34, green: 0.62, blue: 1)][index]
                        let center = size.width * (CGFloat(index) + 0.5) / 3
                        context.draw(Text(label).font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(tint.opacity(0.86)), at: CGPoint(x: center, y: 7))
                    }
                }
                // Draw the graticule over the density image so the levels
                // remain readable at a glance without overpowering the trace.
                var grid = Path()
                for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
                    let y = plot.minY + plot.height * fraction
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(grid, with: .color(.white.opacity(0.12)), lineWidth: 0.6)
                var separators = Path()
                for fraction in [1.0 / 3, 2.0 / 3] {
                    separators.move(to: CGPoint(x: size.width * fraction, y: plot.minY))
                    separators.addLine(to: CGPoint(x: size.width * fraction, y: plot.maxY))
                }
                context.stroke(separators, with: .color(.white.opacity(0.16)), lineWidth: 0.7)
            }
        }
        .padding(6)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 3))
        .accessibilityElement()
        .accessibilityLabel("RGB waveform")
        .accessibilityValue(waveform == nil ? "No developed photograph" : "Red, green, and blue signal levels from zero to one hundred percent across the developed photograph")
    }
}

private func scopeGrid(context: inout GraphicsContext, size: CGSize) {
    var grid = Path()
    for fraction in [0.25, 0.5, 0.75] {
        grid.move(to: CGPoint(x: 0, y: size.height * fraction))
        grid.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
    }
    context.stroke(grid, with: .color(Theme.line), lineWidth: 0.5)
}

enum ScopeMode: String, CaseIterable, Sendable {
    case histogram = "Histogram", waveform = "Waveform", vectorscope = "Vectorscope", skin = "Skin Analysis"
    case picker = "Color Picker"

    var symbol: String {
        switch self {
        case .histogram: "chart.bar.xaxis"
        case .waveform: "waveform.path"
        case .vectorscope: "circle.hexagongrid"
        case .skin: "person.crop.circle"
        case .picker: "eyedropper"
        }
    }

    var signalLabel: String {
        switch self {
        case .histogram, .waveform: "RGB"
        case .vectorscope: "Cb · Cr"
        case .skin: "FACE CHROMA"
        case .picker: "SAMPLE"
        }
    }
}

struct ScopePanelView: View {
    let histogram: Histogram?
    let waveform: Waveform?
    let vectorscope: Vectorscope?
    let skinAnalysis: SkinAnalysis?
    var colorSample: ColorSample?
    var isUpdating = false
    var setScopeMode: (ScopeMode) -> Void = { _ in }
    var clippingEnabled = false
    var setClippingEnabled: (Bool) -> Void = { _ in }
    var falseColorEnabled = false
    var setFalseColorEnabled: (Bool) -> Void = { _ in }
    var saturationOverlayEnabled = false
    var setSaturationOverlayEnabled: (Bool) -> Void = { _ in }
    var saturationOverlayMode: SaturationOverlayMode = .monoBalance
    var setSaturationOverlayMode: (SaturationOverlayMode) -> Void = { _ in }
    var skinToneOverlayEnabled = false
    var setSkinToneOverlayEnabled: (Bool) -> Void = { _ in }
    var neutralCandidatesEnabled = false
    var setNeutralCandidatesEnabled: (Bool) -> Void = { _ in }
    @AppStorage("scopeMode") private var mode = ScopeMode.histogram
    /// Dragged with the handle below the scope; remembered.
    @AppStorage("scopeHeight.compactInspector") private var height = ScopePanelView.defaultHeight
    /// The height while the handle is dragged, saved to `height` when it's let go.
    @State private var dragHeight: Double?
    /// Compact dock leaves room for adjustments; expanded is available for
    /// judging scope detail. The grabber still allows any intermediate size.
    static let heights = 72.0...360.0
    static let compactHeight = 88.0
    static let expandedHeight = 200.0
    static let defaultHeight = compactHeight

    var body: some View {
        VStack(spacing: StudioStyle.Space.compact) {
            scopeToolbar
            Group {
                VStack(spacing: StudioStyle.Space.compact) {
                    if falseColorEnabled { FalseColorLegend().padding(.horizontal, 3) }
                    if saturationOverlayEnabled { SaturationOverlayLegend(mode: saturationOverlayMode).padding(.horizontal, 3) }
                    if skinToneOverlayEnabled { SkinToneOverlayLegend().padding(.horizontal, 3) }
                    if neutralCandidatesEnabled { NeutralCandidateLegend().padding(.horizontal, 3) }
                    switch mode {
                    case .histogram: HistogramView(histogram: histogram)
                    case .waveform: WaveformView(waveform: waveform)
                    case .vectorscope: VectorscopeView(vectorscope: vectorscope, skinOnly: false)
                    case .skin: VectorscopeView(vectorscope: vectorscope, skinOnly: true, skinAnalysis: skinAnalysis)
                    case .picker: ColorPickerScopeView(sample: colorSample)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Scope view")
            .frame(height: Self.clamped(dragHeight ?? height))
            .overlay {
                if histogram == nil {
                    Text("No developed photograph").font(Theme.text(13, italic: true)).foregroundStyle(Theme.dim)
                }
            }
            resizeHandle
        }
        .onAppear { setScopeMode(mode) }
        .onChange(of: mode) { _, value in setScopeMode(value) }
    }

    private var scopeToolbar: some View {
        HStack {
                Menu {
                    ForEach(ScopeMode.allCases, id: \.self) { option in
                        Button {
                            mode = option
                        } label: {
                            if mode == option { Label(option.rawValue, systemImage: "checkmark") }
                            else { Text(option.rawValue) }
                        }
                    }
                } label: {
                    Label(mode.rawValue, systemImage: mode.symbol).lineLimit(1).minimumScaleFactor(0.8)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .controlSize(.small)
                .accessibilityLabel("Scope view")
                if isUpdating {
                    ProgressView().controlSize(.mini).help("Updating scope for the current preview")
                }
                Button {
                    setClippingEnabled(!clippingEnabled)
                } label: {
                    Image(systemName: clippingEnabled ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(clippingEnabled ? Color.blue : Color.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Clipping indicators")
                .help("Toggle clipping colors on the photograph. Red marks clipped highlights; blue marks near-black or crushed shadows.")
                Button {
                    setFalseColorEnabled(!falseColorEnabled)
                } label: {
                    Image(systemName: "camera.filters")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(falseColorEnabled ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("False Color")
                .help("Show a false-colour exposure map over the developed photograph.")
                Menu {
                    Button { setSaturationOverlayEnabled(false) } label: {
                        if !saturationOverlayEnabled { Label("Off", systemImage: "checkmark") }
                        else { Text("Off") }
                    }
                    Divider()
                    ForEach(SaturationOverlayMode.allCases) { option in
                        Button {
                            setSaturationOverlayMode(option)
                            setSaturationOverlayEnabled(true)
                        } label: {
                            if saturationOverlayEnabled && saturationOverlayMode == option {
                                Label(option.title, systemImage: "checkmark")
                            } else { Text(option.title) }
                        }
                    }
                } label: {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(saturationOverlayEnabled ? Color.green : Color.secondary)
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Saturation overlay method")
                .help("Choose MONO-Balance RGB spread or CIECAM02 appearance saturation for the developed photograph.")
                Button {
                    setSkinToneOverlayEnabled(!skinToneOverlayEnabled)
                } label: {
                    Image(systemName: skinToneOverlayEnabled ? "person.crop.circle.fill" : "person.crop.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(skinToneOverlayEnabled ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Skin tone overlay")
                .help("Mark skin-hue pixels by their position relative to the vectorscope skin-tone line.")
                Button {
                    setNeutralCandidatesEnabled(!neutralCandidatesEnabled)
                } label: {
                    Image(systemName: neutralCandidatesEnabled ? "circle.lefthalf.filled" : "circle.lefthalf.striped.horizontal")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(neutralCandidatesEnabled ? Color.green : Color.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Highlight neutrals")
                .help("Highlight pixels whose RGB channels are each within 2% and whose mean brightness exceeds 10%.")
                Spacer()
                Text(mode.signalLabel)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A grabber under the scope: drag to resize, double-click for the default height.
    private var resizeHandle: some View {
        Capsule().fill(Theme.track).frame(width: 32, height: 3)
            .frame(maxWidth: .infinity, minHeight: 8)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            // Measured in the window: the handle moves with the height, so in its own
            // coordinates the translation shrank as the scope grew (half speed, jitter).
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    dragHeight = Self.clamped(height + drag.translation.height)
                }
                .onEnded { drag in
                    height = Self.clamped(height + drag.translation.height)
                    dragHeight = nil
                })
            .onTapGesture(count: 2) { height = Self.defaultHeight }
            .help("Drag to resize the scope")
            .accessibilityLabel("Scope height")
            .accessibilityValue("\(Int(height)) points")
            .accessibilityAdjustableAction { direction in
                height = Self.clamped(height + (direction == .increment ? 20 : -20))
            }
    }

    /// Whole points keep the grid lines and plot edges from shimmering mid-drag.
    private static func clamped(_ height: Double) -> Double {
        min(max(height.rounded(), heights.lowerBound), heights.upperBound)
    }
}

private struct NeutralCandidateLegend: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Color.green).frame(width: 7, height: 7)
            Text("RGB channel spread <2% · mean brightness >10%")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Spacer(minLength: 0)
        }
    }
}

private struct FalseColorLegend: View {
    private let stops: [(String, Color)] = [
        (".02", Color(red: 0.00, green: 0.04, blue: 0.04)), (".08", Color(red: 0.05, green: 0.09, blue: 0.19)),
        (".14", Color(red: 0.05, green: 0.17, blue: 0.28)), (".22", Color(red: 0.13, green: 0.29, blue: 0.21)),
        (".33", Color(red: 0.18, green: 0.40, blue: 0.27)), (".46", Color(red: 0.46, green: 0.46, blue: 0.46)),
        (".60", Color(red: 0.67, green: 0.65, blue: 0.22)), (".73", Color(red: 0.62, green: 0.39, blue: 0.18)),
        (".91", Color(red: 0.33, green: 0.15, blue: 0.07)), (".96+", Color(red: 0.26, green: 0.05, blue: 0.05))
    ]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(stops.enumerated()), id: \.offset) { _, stop in
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2).fill(stop.1).frame(height: 5)
                    Text(stop.0).font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            Text("Y").font(.system(size: 8, weight: .semibold, design: .monospaced)).foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rec.709 luma false color scale using the Mono Balance exposure bands")
    }
}

private struct SaturationOverlayLegend: View {
    let mode: SaturationOverlayMode

    var body: some View {
        let colors = [Color(red: 0.00, green: 0.04, blue: 0.04),
                      Color(red: 0.03, green: 0.06, blue: 0.12),
                      Color(red: 0.05, green: 0.09, blue: 0.19),
                      Color(red: 0.05, green: 0.17, blue: 0.28),
                      Color(red: 0.13, green: 0.29, blue: 0.21),
                      Color(red: 0.18, green: 0.40, blue: 0.27),
                      Color(red: 0.46, green: 0.46, blue: 0.46),
                      Color(red: 0.67, green: 0.65, blue: 0.22),
                      Color(red: 0.62, green: 0.39, blue: 0.18),
                      Color(red: 0.52, green: 0.25, blue: 0.22),
                      Color(red: 0.41, green: 0.19, blue: 0.16),
                      Color(red: 0.37, green: 0.07, blue: 0.07),
                      Color(red: 0.30, green: 0.01, blue: 0.01)]
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Text(mode == .monoBalance ? "SAT · ΔRGB" : "CIECAM02 · s")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                HStack(spacing: 0) {
                    ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                        Rectangle().fill(color)
                    }
                }
                .frame(height: 7)
                Text(mode == .monoBalance ? "0–100%" : "s 0–107.4")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 3) {
                if mode == .monoBalance {
                    Text("0–1% near-neutral")
                    Spacer(minLength: 2)
                    Text("16–22% midrange").foregroundStyle(Color(red: 0.72, green: 0.72, blue: 0.44))
                    Spacer(minLength: 2)
                    Text("74%+ strong · no fixed target")
                } else {
                    Text("CIECAM02 saturation correlate s")
                    Spacer(minLength: 2)
                    Text("D65 · avg surround · Yb 20 · S&G ’16")
                }
            }
            .font(.system(size: 7, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mode == .monoBalance
            ? "MONO-Balance saturation heatmap: normalized Rec.709 RGB channel spread. Its bands are visual guidance, not a claim that a color is over-saturated."
            : "CIECAM02 saturation correlate s heatmap using D65, average surround, and background Yb 20. False-color scale is a visualization, not an over-saturation threshold.")
    }
}

private struct SkinToneOverlayLegend: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Color.yellow).frame(width: 7, height: 7)
            Text("Skin-tone line")
            Circle().fill(Color(red: 0.92, green: 0.08, blue: 0.78)).frame(width: 7, height: 7)
            Text("Magenta")
            Circle().fill(Color.green).frame(width: 7, height: 7)
            Text("Green")
            Text("· hue guide, not a skin mask")
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .font(.system(size: 8, weight: .medium, design: .monospaced))
        .foregroundStyle(Theme.dim)
        .lineLimit(1)
        .minimumScaleFactor(0.72)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Skin hue guide: yellow is near the skin-tone line, magenta indicates magenta deviation, and green indicates green deviation. This is not a skin mask.")
    }
}

private struct ColorPickerScopeView: View {
    let sample: ColorSample?
    private var swatchColor: Color {
        guard let sample else { return StudioStyle.plot }
        return Color(.sRGB, red: Double(sample.red) / 255, green: Double(sample.green) / 255,
                     blue: Double(sample.blue) / 255, opacity: 1)
    }
    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6).fill(swatchColor)
                .frame(width: 54, height: 54).overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line, lineWidth: 1))
            sampleDetails
            Spacer(minLength: 0)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioStyle.panel, in: RoundedRectangle(cornerRadius: StudioStyle.Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: StudioStyle.Radius.panel).strokeBorder(StudioStyle.outline, lineWidth: 0.8))
        .accessibilityElement(children: .combine).accessibilityLabel(sample.map { "Color sample \($0.hex), red \($0.red), green \($0.green), blue \($0.blue)" } ?? "Color picker. Click the photo to sample a color")
    }

    @ViewBuilder private var sampleDetails: some View {
        if let sample {
            VStack(alignment: .leading, spacing: 5) {
                Text(sample.hex).font(Theme.text(12, weight: 700)).foregroundStyle(Theme.label)
                Text(String(format: "R %3d   G %3d   B %3d", sample.red, sample.green, sample.blue))
                Text(String(format: "CIE xy   %.4f   %.4f", sample.xy.0, sample.xy.1))
            }.font(Theme.text(10, weight: 500)).monospacedDigit()
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Text("Click the photo to sample a color").font(Theme.text(11, weight: 600)).foregroundStyle(Theme.label)
                Text("Samples the developed image").font(Theme.text(10)).foregroundStyle(Theme.dim)
            }
        }
    }
}

private struct VectorscopeView: View {
    let vectorscope: Vectorscope?
    let skinOnly: Bool
    var skinAnalysis: SkinAnalysis? = nil

    var body: some View {
        VStack(spacing: StudioStyle.Space.compact) {
            Canvas { context, size in
                let side = min(size.width, size.height)
                let origin = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
                let center = CGPoint(x: origin.x + side / 2, y: origin.y + side / 2)
                // Use more of the scope well so the actual signal is easy to
                // read at the compact inspector size.
                let radius = side * 0.435
                let plot = CGRect(x: center.x - radius, y: center.y - radius,
                                  width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: plot), with: .color(StudioStyle.plot))

                let targets: [(String, Double, Double)] = [
                    ("R", 103, 0), ("Y", 167, 1.0 / 6), ("G", 241, 2.0 / 6),
                    ("C", 283, 3.0 / 6), ("B", 347, 4.0 / 6), ("M", 61, 5.0 / 6)
                ]
                for fraction in [0.25, 0.5, 0.75, 1.0] {
                    let rect = CGRect(x: center.x - radius * fraction, y: center.y - radius * fraction,
                                      width: radius * fraction * 2, height: radius * fraction * 2)
                    let opacity = fraction == 1 ? 0.48 : fraction == 0.75 ? 0.34 : 0.14
                    context.stroke(Path(ellipseIn: rect), with: .color(.primary.opacity(opacity)),
                                   lineWidth: fraction == 1 ? 0.9 : 0.65)
                }
                var ticks = Path()
                for index in 0..<72 {
                    let angle = Double(index) * .pi / 36
                    let major = index % 6 == 0
                    let inner = radius - (major ? 7.0 : 3.5)
                    ticks.move(to: CGPoint(x: center.x + cos(angle) * inner,
                                           y: center.y - sin(angle) * inner))
                    ticks.addLine(to: CGPoint(x: center.x + cos(angle) * radius,
                                              y: center.y - sin(angle) * radius))
                }
                context.stroke(ticks, with: .color(Color(red: 0.58, green: 0.46, blue: 0.12).opacity(0.8)), lineWidth: 0.65)
                var cross = Path()
                cross.move(to: CGPoint(x: center.x - radius, y: center.y)); cross.addLine(to: CGPoint(x: center.x + radius, y: center.y))
                cross.move(to: CGPoint(x: center.x, y: center.y - radius)); cross.addLine(to: CGPoint(x: center.x, y: center.y + radius))
                context.stroke(cross, with: .color(.primary.opacity(0.28)), lineWidth: 0.8)

                for (label, degrees, _) in targets {
                    let angle = degrees * .pi / 180
                    let tint = Color(red: 0.62, green: 0.49, blue: 0.15)
                    var spoke = Path()
                    spoke.move(to: center)
                    spoke.addLine(to: CGPoint(x: center.x + cos(angle) * radius,
                                              y: center.y - sin(angle) * radius))
                    context.stroke(spoke, with: .color(tint.opacity(0.08)), lineWidth: 0.55)

                    // The small outlined squares mark the broadcast 75% hue targets.
                    let targetCenter = CGPoint(x: center.x + cos(angle) * radius * 0.75,
                                               y: center.y - sin(angle) * radius * 0.75)
                    let targetSize = max(7, side * 0.035)
                    let targetRect = CGRect(x: targetCenter.x - targetSize / 2,
                                            y: targetCenter.y - targetSize / 2,
                                            width: targetSize, height: targetSize)
                    context.stroke(Path(roundedRect: targetRect, cornerRadius: 1.5),
                                   with: .color(tint.opacity(0.84)), lineWidth: 0.8)
                    let labelCenter = CGPoint(x: center.x + cos(angle) * radius * 1.13,
                                              y: center.y - sin(angle) * radius * 1.13)
                    context.draw(Text(label).font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(tint.opacity(0.95)), at: labelCenter)
                }

                guard let vectorscope else { return }
                let counts = skinOnly ? vectorscope.skinBins : vectorscope.bins
                guard counts.count == vectorscope.size * vectorscope.size,
                      (skinOnly ? vectorscope.skinSampleCount : vectorscope.sampleCount) > 0 else {
                    context.draw(Text("No chroma samples")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary), at: center)
                    return
                }
                let occupied = counts.filter { $0 > 0 }.sorted()
                let reference = Double(occupied.isEmpty ? 1 : occupied[min(occupied.count - 1, Int(Double(occupied.count - 1) * 0.98))])
                for y in 0..<vectorscope.size {
                    for x in 0..<vectorscope.size {
                        let count = counts[y * vectorscope.size + x]
                        guard count > 0 else { continue }
                        let nx = Double(x) / Double(vectorscope.size - 1) * 2 - 1
                        let ny = Double(y) / Double(vectorscope.size - 1) * 2 - 1
                        guard nx * nx + ny * ny <= 1.05 else { continue }
                        let point = CGPoint(x: center.x + nx * radius, y: center.y + ny * radius)
                        // Fine, softly weighted points preserve sparse chroma
                        // detail without filling the whole gamut cloud into a
                        // hard-edged, opaque blob.
                        let dot = max(1.35, side / CGFloat(vectorscope.size) * 0.92)
                        let rect = CGRect(x: point.x - dot / 2, y: point.y - dot / 2, width: dot, height: dot)
                        let density = min(1, Double(count) / reference)
                        let strength = min(0.92, 0.10 + pow(density, 0.55) * 0.78)
                        let tint = skinOnly ? Color(red: 1.0, green: 0.84, blue: 0.28) : .white
                        context.fill(Path(ellipseIn: rect), with: .color(tint.opacity(strength)))
                    }
                }
                if skinOnly {
                    let angle = 123 * Double.pi / 180
                    var reference = Path()
                    reference.move(to: center)
                    reference.addLine(to: CGPoint(x: center.x + cos(angle) * radius, y: center.y - sin(angle) * radius))
                    context.stroke(reference, with: .color(StudioStyle.warning.opacity(0.95)),
                                   style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                }
            }
            if skinOnly, let skinAnalysis {
                HStack(spacing: 6) {
                    Text(skinAnalysis.status).font(.caption2.weight(.semibold))
                    Spacer()
                    Text(skinAnalysis.meanDeviationDegrees.map { String(format: "%+.1f°", $0) } ?? "—")
                    Text(String(format: "%.0f%% coverage", skinAnalysis.coveragePercent))
                }
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                Text("Face-box chroma estimate against the skin-tone reference line")
                    .font(.system(size: 9)).foregroundStyle(.tertiary).padding(.horizontal, 8)
            }
        }
        .padding(StudioStyle.Space.compact)
        .background(StudioStyle.panel, in: RoundedRectangle(cornerRadius: StudioStyle.Radius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: StudioStyle.Radius.panel)
                .strokeBorder(StudioStyle.outline, lineWidth: 0.8)
        }
        .accessibilityElement().accessibilityLabel(skinOnly ? "Skin tone vectorscope" : "Vectorscope")
        .accessibilityValue(skinOnly ? skinAnalysis?.status ?? "No developed photograph" : "Chroma distribution of the developed photograph")
    }
}
