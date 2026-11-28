import Foundation

/// Harmony rules used by the perceptual Color Harmonizer.
enum ColorSeparationPreset: String, CaseIterable, Identifiable {
    case manual
    case monochromatic
    case analogous
    case complementary
    case splitComplementary = "split_complementary"
    case triadic
    case tetradic
    case square

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: "Manual split tone"
        case .monochromatic: "Single tone"
        case .analogous: "Soft split tone"
        case .complementary: "Cinematic complementary"
        case .splitComplementary: "Split complementary"
        case .triadic: "Triadic color grade"
        case .tetradic: "Four-tone palette"
        case .square: "Square palette"
        }
    }

    private var firstAdditionalRybOffset: Double? {
        switch self {
        case .manual, .monochromatic: nil
        case .analogous: -1.0 / 12.0
        case .complementary: 6.0 / 12.0
        case .splitComplementary: 5.0 / 12.0
        case .triadic: 4.0 / 12.0
        case .tetradic: 1.0 / 12.0
        case .square: 3.0 / 12.0
        }
    }

    func complementaryHue(target: Double) -> Double {
        guard let offset = firstAdditionalRybOffset else { return target }
        let anchor = rgbHueToRyb(target / 360)
        return rybToRGBHue((anchor + offset).truncatingRemainder(dividingBy: 1)) * 360
    }

    static func matching(rule: String) -> Self {
        Self(rawValue: rule) ?? .manual
    }

    private static let rgbKnots = [0.0, 1.0 / 6, 2.0 / 6, 3.0 / 6, 4.0 / 6, 5.0 / 6, 1.0]
    private static let rybKnots = [0.0, 1.0 / 3, 0.472, 0.611, 0.715, 5.0 / 6, 1.0]

    private func rgbHueToRyb(_ hue: Double) -> Double {
        Self.interpolate(hue, x: Self.rgbKnots, y: Self.rybKnots)
    }

    private func rybToRGBHue(_ hue: Double) -> Double {
        Self.interpolate(hue, x: Self.rybKnots, y: Self.rgbKnots)
    }

    private static func interpolate(_ value: Double, x: [Double], y: [Double]) -> Double {
        let wrapped = value - floor(value)
        for index in 0..<(x.count - 1) where wrapped <= x[index + 1] {
            let t = (wrapped - x[index]) / (x[index + 1] - x[index])
            return y[index] + t * (y[index + 1] - y[index])
        }
        return 1
    }
}
