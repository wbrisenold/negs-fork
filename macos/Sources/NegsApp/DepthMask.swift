import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import IOSurface
import UniformTypeIdentifiers

/// Local Depth Anything inference and editable near/mid/far selection masks.
/// The inferred map is stored with the mask so range controls can rebuild the
/// mask without running the model again.
enum DepthMask {
    enum Preset: String, CaseIterable, Identifiable, Sendable {
        case near, middle, far

        var id: String { rawValue }
        var title: String {
            switch self {
            case .near: "Near"
            case .middle: "Middle"
            case .far: "Far"
            }
        }
        var symbol: String {
            switch self {
            case .near: "viewfinder"
            case .middle: "circle.dashed"
            case .far: "mountain.2"
            }
        }
        var defaultRange: ClosedRange<Double> {
            switch self {
            case .near: 0.66...1
            case .middle: 0.33...0.67
            case .far: 0...0.40
            }
        }
    }

    struct Result: @unchecked Sendable {
        let depthMapPNGBase64: String
        let maskPNGBase64: String
        let overlay: CGImage
    }

    enum Failure: LocalizedError {
        case missingRuntime, invalidImage, inference(String), invalidDepthMap, emptyRange

        var errorDescription: String? {
            switch self {
            case .missingRuntime: "The depth estimator is missing from this app package. Rebuild Negs to add it."
            case .invalidImage: "Could not prepare the preview for depth estimation."
            case .inference(let details): "Depth estimation failed: \(details)"
            case .invalidDepthMap: "The depth estimator returned an unreadable map."
            case .emptyRange: "Choose a depth range with some separation between its handles."
            }
        }
    }

    private static let modelName = "depth-anything-small-f32.gguf"
    private static let modelURL = URL(string: "https://huggingface.co/mudler/depth-anything.cpp-gguf/resolve/main/\(modelName)")!
    private static let modelSHA256 = "eab5597e01dedde1a20c038590ae8c887b85ec35b882581138c08308e92c41e5"
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func estimate(for surface: IOSurface, preset: Preset,
                         range: ClosedRange<Double>? = nil) async throws -> Result {
        guard let cli = runtimeURL else { throw Failure.missingRuntime }
        let model = try await installedModelURL()
        let sourceImage = CIImage(ioSurface: surface)
        let downscale = min(1.0, 1536.0 / Double(max(surface.width, surface.height)))
        let inferenceImage = downscale < 1
            ? sourceImage.transformed(by: CGAffineTransform(scaleX: downscale, y: downscale)) : sourceImage
        guard let cgImage = ciContext.createCGImage(inferenceImage, from: inferenceImage.extent) else {
            throw Failure.invalidImage
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("negs-depth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("preview.png")
        let output = folder.appendingPathComponent("depth.pfm")
        try writePNG(cgImage, to: input)

        let process = Process()
        process.executableURL = cli
        process.arguments = ["depth", "--model", model.path, "--input", input.path,
                             "--pfm", output.path, "--threads", "2"]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let data = try? Data(contentsOf: output) else {
            let details = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "The model process did not produce a depth map."
            throw Failure.inference(details.isEmpty ? "The model process did not produce a depth map." : details)
        }
        let depth = try decodePFM(data)
        let normalized = normalizeDepth(depth.values)
        let depthPNG = try makePNG(values: normalized, width: depth.width, height: depth.height)
        let encodedDepth = depthPNG.base64EncodedString()
        let selectedRange = range ?? preset.defaultRange
        let maskPNG = try maskPNG(depth: normalized, width: depth.width, height: depth.height,
                                  range: selectedRange)
        guard let overlay = BackgroundMask.overlay(fromPNGBase64: maskPNG.base64EncodedString()) else {
            throw Failure.invalidDepthMap
        }
        return Result(depthMapPNGBase64: encodedDepth, maskPNGBase64: maskPNG.base64EncodedString(), overlay: overlay)
    }

    static func mask(depthMapPNGBase64: String, range: ClosedRange<Double>) -> (String, CGImage)? {
        guard let data = Data(base64Encoded: depthMapPNGBase64),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let values = grayPixels(image) else { return nil }
        let mask = (try? maskPNG(depth: values.map { Float($0) / 255 }, width: image.width,
                                 height: image.height, range: range))
        guard let mask, let overlay = BackgroundMask.overlay(fromPNGBase64: mask.base64EncodedString()) else { return nil }
        return (mask.base64EncodedString(), overlay)
    }

    static func depthOverlay(depthMapPNGBase64: String) -> CGImage? {
        guard let data = Data(base64Encoded: depthMapPNGBase64),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let depth = grayPixels(image) else { return nil }
        var rgba = [UInt8](repeating: 0, count: depth.count * 4)
        for (index, byte) in depth.enumerated() {
            let amount = Double(byte) / 255
            // Cyan farther away, amber nearer; the photograph stays visible.
            let red = 35 + 220 * amount
            let green = 155 + 45 * (1 - amount)
            let blue = 225 * (1 - amount) + 35 * amount
            let alpha = 118.0
            let i = index * 4, a = alpha / 255
            rgba[i] = UInt8((red * a).rounded())
            rgba[i + 1] = UInt8((green * a).rounded())
            rgba[i + 2] = UInt8((blue * a).rounded())
            rgba[i + 3] = UInt8(alpha)
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Encodes hand edits as signed deltas from the current automatic range.
    /// This lets a later range change preserve brush work instead of replacing it.
    static func refinement(currentMaskPNGBase64: String, baseMaskPNGBase64: String) -> String? {
        guard let current = decodedPixels(currentMaskPNGBase64), let base = decodedPixels(baseMaskPNGBase64),
              current.width == base.width, current.height == base.height else { return nil }
        let deltas = zip(current.pixels, base.pixels).map { current, base in
            UInt8(min(max(Int(current) - Int(base) + 128, 0), 255))
        }
        return (try? pngData(deltas, width: current.width, height: current.height))?.base64EncodedString()
    }

    static func applyingRefinement(_ refinementPNGBase64: String, to baseMaskPNGBase64: String) -> String? {
        guard let refinement = decodedPixels(refinementPNGBase64), let base = decodedPixels(baseMaskPNGBase64),
              refinement.width == base.width, refinement.height == base.height else { return nil }
        let adjusted = zip(base.pixels, refinement.pixels).map { base, encodedDelta in
            UInt8(min(max(Int(base) + Int(encodedDelta) - 128, 0), 255))
        }
        return (try? pngData(adjusted, width: base.width, height: base.height))?.base64EncodedString()
    }

    private static var runtimeURL: URL? {
        if let override = ProcessInfo.processInfo.environment["NEGS_DEPTH_RUNTIME"],
           FileManager.default.isExecutableFile(atPath: override) { return URL(fileURLWithPath: override) }
        let packaged = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("da3-cli")
        if let packaged, FileManager.default.isExecutableFile(atPath: packaged.path) { return packaged }
        return nil
    }

    private static func installedModelURL() async throws -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Negs/Models", isDirectory: true)
        let model = support.appendingPathComponent(modelName)
        if validModel(at: model) { return model }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let (temporary, response) = try await URLSession.shared.download(from: modelURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              try sha256(of: temporary) == modelSHA256 else {
            try? FileManager.default.removeItem(at: temporary)
            throw Failure.inference("The downloaded model failed its SHA-256 check.")
        }
        try? FileManager.default.removeItem(at: model)
        try FileManager.default.moveItem(at: temporary, to: model)
        return model
    }

    private static func validModel(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let hash = try? sha256(of: url) else { return false }
        return hash == modelSHA256
    }

    private static func sha256(of url: URL) throws -> String {
        // `shasum` is available on supported macOS versions and lets the model
        // be checked without adding a crypto package to the app.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", url.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let line = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
            throw Failure.inference("Could not verify the model file.")
        }
        return String(line.prefix(64))
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.invalidImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.invalidImage }
    }

    private static func decodePFM(_ data: Data) throws -> (width: Int, height: Int, values: [Float]) {
        var offset = 0
        func line() -> String? {
            guard offset < data.count else { return nil }
            let start = offset
            while offset < data.count, data[offset] != 10 { offset += 1 }
            let end = offset
            if offset < data.count { offset += 1 }
            return String(data: data[start..<end], encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let magic = line(), magic == "Pf" || magic == "PF",
              let dimensions = line()?.split(whereSeparator: \.isWhitespace), dimensions.count == 2,
              let width = Int(dimensions[0]), let height = Int(dimensions[1]), width > 0, height > 0,
              let scaleLine = line(), let scale = Float(scaleLine), scale != 0 else { throw Failure.invalidDepthMap }
        let channels = magic == "Pf" ? 1 : 3
        let count = width * height
        guard data.count - offset >= count * channels * 4 else { throw Failure.invalidDepthMap }
        let littleEndian = scale < 0
        let scaleFactor = abs(scale)
        var values = [Float](repeating: 0, count: count)
        for index in 0..<count {
            // PFM stores scan lines from bottom to top. Convert to the
            // top-left origin used by CGImage and the editor's mask pipeline.
            let row = index / width
            let column = index % width
            let byteOffset = offset + ((height - 1 - row) * width + column) * channels * 4
            let bits: UInt32
            if littleEndian {
                bits = UInt32(data[byteOffset]) | UInt32(data[byteOffset + 1]) << 8
                    | UInt32(data[byteOffset + 2]) << 16 | UInt32(data[byteOffset + 3]) << 24
            } else {
                bits = UInt32(data[byteOffset]) << 24 | UInt32(data[byteOffset + 1]) << 16
                    | UInt32(data[byteOffset + 2]) << 8 | UInt32(data[byteOffset + 3])
            }
            values[index] = Float(bitPattern: bits) * scaleFactor
        }
        return (width, height, values)
    }

    /// Robustly scales relative depth to 0...1 with near objects at the high
    /// end, matching the default display convention used by the DA3 CLI.
    private static func normalizeDepth(_ values: [Float]) -> [Float] {
        let finite = values.filter(\.isFinite).sorted()
        guard finite.count > 1, let lo = finite.first, let hi = finite.last, hi > lo else {
            return Array(repeating: 0.5, count: values.count)
        }
        let low = finite[finite.count / 100]
        let high = finite[min(finite.count - 1, finite.count * 99 / 100)]
        let span = max(high - low, Float.leastNonzeroMagnitude)
        return values.map { value in
            guard value.isFinite else { return 0.5 }
            return 1 - min(max((value - low) / span, 0), 1)
        }
    }

    private static func maskPNG(depth: [Float], width: Int, height: Int,
                                range: ClosedRange<Double>) throws -> Data {
        guard range.upperBound > range.lowerBound else { throw Failure.emptyRange }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let low = Float(range.lowerBound), high = Float(range.upperBound)
        let feather = max((high - low) * 0.10, 0.005)
        for index in pixels.indices {
            let value = depth[index]
            let rise = smoothstep(low, min(low + feather, high), value)
            let fall = 1 - smoothstep(max(high - feather, low), high, value)
            pixels[index] = UInt8((min(max(rise * fall, 0), 1) * 255).rounded())
        }
        return try pngData(pixels, width: width, height: height)
    }

    private static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        guard edge1 > edge0 else { return x >= edge1 ? 1 : 0 }
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func makePNG(values: [Float], width: Int, height: Int) throws -> Data {
        try pngData(values.map { UInt8((min(max($0, 0), 1) * 255).rounded()) }, width: width, height: height)
    }

    private static func pngData(_ pixels: [UInt8], width: Int, height: Int) throws -> Data {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                                  bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw Failure.invalidDepthMap
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.invalidDepthMap
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.invalidDepthMap }
        return output as Data
    }

    private static func grayPixels(_ image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height)
        let ok = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return ok ? pixels : nil
    }

    private static func decodedPixels(_ encoded: String) -> (width: Int, height: Int, pixels: [UInt8])? {
        guard let data = Data(base64Encoded: encoded),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let pixels = grayPixels(image) else { return nil }
        return (image.width, image.height, pixels)
    }
}
