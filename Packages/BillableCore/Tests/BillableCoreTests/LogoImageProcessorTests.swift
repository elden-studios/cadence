import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import BillableCore

@Suite("LogoImageProcessor")
struct LogoImageProcessorTests {

    // Helper: generate a synthetic source image of (w x h) px, with or without alpha.
    private func makeImageData(width: Int, height: Int, hasAlpha: Bool) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = hasAlpha
            ? CGImageAlphaInfo.premultipliedLast.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )!
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: hasAlpha ? 0.7 : 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cg = context.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    private func dimensions(of data: Data) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }
        return (image.width, image.height)
    }

    @Test("Downscales 4000x3000 source so largest dim ≤ 1024")
    func downscalesLargeSource() {
        let source = makeImageData(width: 4000, height: 3000, hasAlpha: false)
        let processed = LogoImageProcessor.process(source)
        #expect(processed != nil)
        let (w, h) = dimensions(of: processed!)!
        #expect(max(w, h) <= 1024)
        // Aspect ratio preserved approximately (within 1px rounding)
        let ratio = Double(w) / Double(h)
        #expect(abs(ratio - 4.0 / 3.0) < 0.02)
    }

    @Test("Does NOT upscale a 32x32 source")
    func doesNotUpscale() {
        let source = makeImageData(width: 32, height: 32, hasAlpha: false)
        let processed = LogoImageProcessor.process(source)
        #expect(processed != nil)
        let (w, h) = dimensions(of: processed!)!
        #expect(w == 32 && h == 32)
    }

    @Test("Encodes JPEG for opaque source")
    func encodesJPEGForOpaque() {
        let source = makeImageData(width: 100, height: 100, hasAlpha: false)
        let processed = LogoImageProcessor.process(source)
        #expect(processed != nil)
        // JPEGs start with FF D8 FF
        let header = processed!.prefix(3)
        #expect(Array(header) == [0xFF, 0xD8, 0xFF])
    }

    @Test("Encodes PNG for transparent source")
    func encodesPNGForTransparent() {
        let source = makeImageData(width: 100, height: 100, hasAlpha: true)
        let processed = LogoImageProcessor.process(source)
        #expect(processed != nil)
        // PNGs start with 89 50 4E 47 (\x89PNG)
        let header = processed!.prefix(4)
        #expect(Array(header) == [0x89, 0x50, 0x4E, 0x47])
    }

    @Test("Returns nil for non-image data")
    func returnsNilForGarbage() {
        let garbage = Data("not an image, just words".utf8)
        let processed = LogoImageProcessor.process(garbage)
        #expect(processed == nil)
    }
}
