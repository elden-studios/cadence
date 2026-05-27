import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Resizes and re-encodes a logo image for storage on `BusinessProfile.logoData`.
///
/// Pure CoreGraphics + ImageIO — no UIImage. Safe under Swift 6 strict
/// concurrency, callable from any actor / task.
///
/// `CGImageSourceCreateThumbnailAtIndex` is the memory-safe path for large
/// source images: a 50 MP photo would be ~150 MB decoded, but the thumbnail
/// path decodes directly at the target size (~4 MB at 1024 px).
public enum LogoImageProcessor {

    /// Max pixels on the longest dimension. Output is bounded by this; smaller
    /// inputs are NOT upscaled.
    public static let maxDimension: CGFloat = 1024

    /// Resize so largest dim ≤ `maxDimension` and re-encode as PNG (if the
    /// source has alpha) or JPEG quality 0.85 (otherwise). Returns nil on
    /// failure (e.g., non-image data, unsupported format).
    public static func process(_ data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCache: false,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOptions as CFDictionary) else {
            return nil
        }

        // Alpha-aware encode: PNG if alpha present, JPEG otherwise.
        let alphaInfo = cgImage.alphaInfo
        let hasAlpha = alphaInfo != .none && alphaInfo != .noneSkipFirst && alphaInfo != .noneSkipLast
        let utType: CFString = hasAlpha
            ? UTType.png.identifier as CFString
            : UTType.jpeg.identifier as CFString

        let outData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(outData as CFMutableData, utType, 1, nil) else {
            return nil
        }
        let properties: [CFString: Any] = hasAlpha
            ? [:]
            : [kCGImageDestinationLossyCompressionQuality: 0.85]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return outData as Data
    }
}
