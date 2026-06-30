import AppKit
import Vision
import CoreImage
import ImageIO

/// Native subject segmentation + mask compositing. The mask (DeviceGray, white =
/// keep) is editable, so the user can touch it up by hand.
enum BackgroundRemover {
    /// Loads an upright CGImage, baking in the EXIF orientation — phone photos store
    /// rotated pixels + an orientation tag, which Vision/CoreGraphics otherwise ignore
    /// (producing a sideways cutout).
    static func loadCGImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let orientation = (props?[kCGImagePropertyOrientation] as? UInt32) ?? 1
        guard orientation != 1 else { return cg }
        let ci = CIImage(cgImage: cg).oriented(forExifOrientation: Int32(orientation))
        return CIContext().createCGImage(ci, from: ci.extent) ?? cg
    }

    /// macOS Vision foreground mask as a DeviceGray 8-bit CGImage at image resolution.
    /// nil if no clear subject is found.
    static func visionMask(for cgImage: CGImage) -> CGImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard (try? handler.perform([request])) != nil,
              let result = request.results?.first, !result.allInstances.isEmpty,
              let buffer = try? result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
        else { return nil }

        let ci = CIImage(cvPixelBuffer: buffer)
        let target = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        let sx = target.width / ci.extent.width, sy = target.height / ci.extent.height
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        return CIContext().createCGImage(scaled, from: target, format: .L8,
                                         colorSpace: CGColorSpaceCreateDeviceGray())
    }

    /// Re-draw any mask image into a DeviceGray 8-bit (no-alpha) buffer at the given
    /// size — the format CGContext.clip(to:mask:) requires.
    static func normalizedGray(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// Composite original × mask (white = keep) → RGBA PNG.
    static func cutoutPNG(original: CGImage, mask: CGImage) -> Data? {
        let w = original.width, h = original.height
        guard let gray = normalizedGray(mask, width: w, height: h),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.clip(to: rect, mask: gray)
        ctx.draw(original, in: rect)
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
    }

    static func pngData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
