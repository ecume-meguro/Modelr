import Foundation
import AppKit
import CoreImage

/// High-performance thumbnail cache with GPU-accelerated image processing
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    /// In-memory cache for thumbnails (NSCache handles memory pressure automatically)
    private let cache = NSCache<NSString, NSImage>()

    /// Preloaded example images (loaded once at startup)
    private var exampleImages: [String: NSImage] = [:]

    /// Background queue for image processing
    private let processingQueue = DispatchQueue(label: "com.modelr.thumbnail", qos: .userInitiated, attributes: .concurrent)

    /// CIContext for GPU-accelerated rendering (reused for efficiency)
    private let ciContext: CIContext

    /// Thumbnail size
    private let thumbnailSize = CGSize(width: 400, height: 400) // 2x for Retina

    private init() {
        // Configure cache limits
        cache.countLimit = 100  // Max 100 thumbnails
        cache.totalCostLimit = 50 * 1024 * 1024  // ~50MB

        // Create Metal-backed CIContext for GPU acceleration
        if let metalDevice = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: metalDevice, options: [
                .cacheIntermediates: false,
                .priorityRequestLow: false
            ])
        } else {
            // Fallback to default context
            ciContext = CIContext(options: [.useSoftwareRenderer: false])
        }
    }

    // MARK: - Public API

    /// Get cached thumbnail or load from disk
    func thumbnail(for projectId: UUID) async -> NSImage? {
        let cacheKey = projectId.uuidString as NSString

        // Check cache first
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        // Load from disk
        let thumbnailURL = PathManager.projectThumbnailPath(for: projectId)
        guard let image = await loadImage(from: thumbnailURL) else { return nil }

        // Cache it
        cache.setObject(image, forKey: cacheKey, cost: imageCost(image))
        return image
    }

    /// Get example image (preloaded for instant display)
    func exampleImage(named name: String, url: URL) async -> NSImage? {
        // Check preloaded cache
        if let cached = exampleImages[name] {
            return cached
        }

        // Load and cache
        guard let image = await loadImage(from: url) else { return nil }
        exampleImages[name] = image
        return image
    }

    /// Preload all example images at startup
    func preloadExamples(_ examples: [(name: String, url: URL)]) {
        Task.detached(priority: .utility) { [weak self] in
            await withTaskGroup(of: (String, NSImage?).self) { group in
                for example in examples {
                    group.addTask {
                        let image = await self?.loadImage(from: example.url)
                        return (example.name, image)
                    }
                }

                for await (name, image) in group {
                    if let image = image {
                        await MainActor.run {
                            self?.exampleImages[name] = image
                        }
                    }
                }
            }
        }
    }

    /// Preload thumbnails for visible projects
    func preloadThumbnails(for projectIds: [UUID]) {
        Task.detached(priority: .utility) { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for projectId in projectIds {
                    group.addTask {
                        _ = await self?.thumbnail(for: projectId)
                    }
                }
            }
        }
    }

    /// Generate thumbnail using GPU-accelerated CoreImage
    func generateThumbnail(from sourceURL: URL, to destinationURL: URL) async -> Bool {
        return await withCheckedContinuation { continuation in
            processingQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: false)
                    return
                }

                // Use CIImage for GPU-accelerated processing
                guard let ciImage = CIImage(contentsOf: sourceURL) else {
                    continuation.resume(returning: false)
                    return
                }

                // Calculate scale to fit in thumbnail size
                let extent = ciImage.extent
                let scale = min(
                    self.thumbnailSize.width / extent.width,
                    self.thumbnailSize.height / extent.height
                )

                // Apply lanczos scale transform (high quality, GPU-accelerated)
                let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

                // Render to CGImage using Metal
                guard let cgImage = self.ciContext.createCGImage(scaledImage, from: scaledImage.extent) else {
                    continuation.resume(returning: false)
                    return
                }

                // Create PNG data
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                guard let tiffData = nsImage.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiffData),
                      let pngData = bitmap.representation(using: .png, properties: [.compressionFactor: 0.8]) else {
                    continuation.resume(returning: false)
                    return
                }

                // Write to disk
                do {
                    try pngData.write(to: destinationURL)
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    /// Invalidate cache for a specific project
    func invalidate(projectId: UUID) {
        let cacheKey = projectId.uuidString as NSString
        cache.removeObject(forKey: cacheKey)
    }

    /// Clear all cached thumbnails
    func clearCache() {
        cache.removeAllObjects()
    }

    // MARK: - Private Helpers

    private func loadImage(from url: URL) async -> NSImage? {
        return await withCheckedContinuation { continuation in
            processingQueue.async {
                // Use CIImage for fast loading
                if let ciImage = CIImage(contentsOf: url),
                   let cgImage = CIContext().createCGImage(ciImage, from: ciImage.extent) {
                    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    continuation.resume(returning: nsImage)
                } else {
                    // Fallback to NSImage
                    let image = NSImage(contentsOf: url)
                    continuation.resume(returning: image)
                }
            }
        }
    }

    private func imageCost(_ image: NSImage) -> Int {
        guard let rep = image.representations.first else { return 0 }
        return rep.pixelsWide * rep.pixelsHigh * 4 // Approximate bytes (RGBA)
    }
}

// MARK: - Preload Manager Extension

extension ThumbnailCache {
    /// Preload assets for the project browser
    func preloadBrowserAssets(projects: [Project], examples: [(name: String, url: URL)]) {
        // Preload example images first (higher priority - always visible)
        preloadExamples(examples)

        // Preload project thumbnails (visible ones)
        let visibleProjectIds = projects.prefix(12).map(\.id)
        preloadThumbnails(for: Array(visibleProjectIds))
    }
}
