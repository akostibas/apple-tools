import AppKit
import Foundation

/// Shared utility for resizing images to dimensions suitable for LLM vision input.
public enum ImageResizer {

    /// Default max dimension matching Claude's vision input sweet spot.
    public static let defaultMaxDimension = 1568

    /// Resize image data to a JPEG suitable for LLM vision input.
    ///
    /// - Parameters:
    ///   - imageData: Raw image bytes (PNG, JPEG, HEIC, TIFF, etc.)
    ///   - maxDimension: Maximum width or height in pixels (default 1568)
    ///   - compressionQuality: JPEG compression factor 0.0–1.0 (default 0.85)
    /// - Returns: JPEG data, or nil if the image couldn't be decoded.
    public static func resizeForLLM(
        imageData: Data,
        maxDimension: Int = defaultMaxDimension,
        compressionQuality: Double = 0.85
    ) -> Data? {
        guard let nsImage = NSImage(data: imageData) else { return nil }

        // Use pixel dimensions from the bitmap rep (retina-aware).
        let pixelWidth: Int
        let pixelHeight: Int
        if let bitmapRep = nsImage.representations.first as? NSBitmapImageRep {
            pixelWidth = bitmapRep.pixelsWide
            pixelHeight = bitmapRep.pixelsHigh
        } else {
            pixelWidth = Int(nsImage.size.width)
            pixelHeight = Int(nsImage.size.height)
        }

        // Compute target size preserving aspect ratio.
        let targetWidth: Int
        let targetHeight: Int

        if pixelWidth <= maxDimension && pixelHeight <= maxDimension {
            targetWidth = pixelWidth
            targetHeight = pixelHeight
        } else if pixelWidth >= pixelHeight {
            let scale = Double(maxDimension) / Double(pixelWidth)
            targetWidth = maxDimension
            targetHeight = Int(Double(pixelHeight) * scale)
        } else {
            let scale = Double(maxDimension) / Double(pixelHeight)
            targetWidth = Int(Double(pixelWidth) * scale)
            targetHeight = maxDimension
        }

        // Draw into a new bitmap at the target size.
        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetWidth,
            pixelsHigh: targetHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: bitmapRep)
        NSGraphicsContext.current = context
        context?.imageInterpolation = .high
        nsImage.draw(in: NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        NSGraphicsContext.restoreGraphicsState()

        return bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }
}
