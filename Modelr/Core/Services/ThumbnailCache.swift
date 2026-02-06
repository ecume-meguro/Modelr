import Foundation
import AppKit
import CoreImage
import SceneKit
import ModelIO
import SceneKit.ModelIO

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

    /// Get cached thumbnail or load from disk (prefers 3D model preview for completed projects)
    func thumbnail(for projectId: UUID, workflowStep: Int = 1) async -> NSImage? {
        // Use different cache key for model previews
        let isComplete = workflowStep >= 4
        let cacheKey = (isComplete ? "model_\(projectId.uuidString)" : projectId.uuidString) as NSString

        // Check cache first
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        // For completed projects, try to load/generate 3D model preview
        if isComplete, let modelURL = PathManager.existingProjectModelPath(for: projectId) {
            // Check for existing model preview
            let previewPath = PathManager.projectDirectory(for: projectId).appendingPathComponent("model_preview.png")
            if let image = await loadImage(from: previewPath) {
                cache.setObject(image, forKey: cacheKey, cost: imageCost(image))
                return image
            }

            // Generate new preview from 3D model
            if let image = await generate3DModelPreview(from: modelURL, saveTo: previewPath) {
                cache.setObject(image, forKey: cacheKey, cost: imageCost(image))
                return image
            }
        }

        // Fallback to regular thumbnail
        let thumbnailURL = PathManager.projectThumbnailPath(for: projectId)
        guard let image = await loadImage(from: thumbnailURL) else { return nil }

        cache.setObject(image, forKey: cacheKey, cost: imageCost(image))
        return image
    }

    /// Legacy method for compatibility
    func thumbnail(for projectId: UUID) async -> NSImage? {
        await thumbnail(for: projectId, workflowStep: 1)
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

    /// Invalidate cache for a project (forces reload on next access)
    func invalidate(for projectId: UUID) {
        let cacheKey = projectId.uuidString as NSString
        let modelCacheKey = "model_\(projectId.uuidString)" as NSString
        cache.removeObject(forKey: cacheKey)
        cache.removeObject(forKey: modelCacheKey)
    }

    /// Invalidate cache for a project (legacy signature for backward compatibility)
    func invalidate(projectId: UUID) {
        invalidate(for: projectId)
    }

    /// Generate and save a 3D model preview with custom color
    func updateModelPreview(for projectId: UUID, modelURL: URL, color: NSColor?) async {
        let previewPath = PathManager.projectDirectory(for: projectId).appendingPathComponent("model_preview.png")

        // Generate new preview with color
        _ = await generate3DModelPreview(from: modelURL, saveTo: previewPath, color: color)

        // Invalidate cache so next load picks up new preview
        invalidate(for: projectId)
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

    /// Regenerate 3D model preview in background (call after generation completes)
    func regenerateModelPreview(for projectId: UUID) {
        // Invalidate cache first
        let modelCacheKey = "model_\(projectId.uuidString)" as NSString
        cache.removeObject(forKey: modelCacheKey)

        // Delete existing preview file
        let previewPath = PathManager.projectDirectory(for: projectId).appendingPathComponent("model_preview.png")
        try? FileManager.default.removeItem(at: previewPath)

        // Regenerate in background
        Task.detached(priority: .utility) { [weak self] in
            guard let modelURL = PathManager.existingProjectModelPath(for: projectId) else { return }

            // Generate new preview
            if let image = await self?.generate3DModelPreview(from: modelURL, saveTo: previewPath) {
                await MainActor.run {
                    self?.cache.setObject(image, forKey: modelCacheKey, cost: self?.imageCost(image) ?? 0)
                }
                print("[ThumbnailCache] Regenerated model preview for project \(projectId)")
            }
        }
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

    // MARK: - 3D Model Preview Generation

    /// Generate a preview image from a 3D model file using SceneKit
    private func generate3DModelPreview(from modelURL: URL, saveTo destinationURL: URL, color: NSColor? = nil) async -> NSImage? {
        return await withCheckedContinuation { continuation in
            processingQueue.async {
                // Load 3D model
                guard let mdlAsset = self.loadMDLAsset(from: modelURL) else {
                    continuation.resume(returning: nil)
                    return
                }

                // Create scene from asset
                let scene = SCNScene(mdlAsset: mdlAsset)

                // Apply custom color if provided
                if let color = color {
                    self.applyColorToScene(scene, color: color)
                }

                // Setup scene for thumbnail rendering
                self.setupSceneForThumbnail(scene)

                // Render to image
                let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
                renderer.scene = scene

                let size = CGSize(width: 400, height: 400)
                let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)

                // Save to disk
                if let tiffData = image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiffData),
                   let pngData = bitmap.representation(using: .png, properties: [:]) {
                    try? pngData.write(to: destinationURL)
                }

                continuation.resume(returning: image)
            }
        }
    }

    /// Apply a color to all materials in the scene
    private func applyColorToScene(_ scene: SCNScene, color: NSColor) {
        scene.rootNode.enumerateChildNodes { node, _ in
            if let geometry = node.geometry {
                for material in geometry.materials {
                    material.diffuse.contents = color
                }
            }
        }
    }

    /// Load MDL asset from URL (supports OBJ, GLB)
    private func loadMDLAsset(from url: URL) -> MDLAsset? {
        let ext = url.pathExtension.lowercased()

        if ext == "glb" || ext == "gltf" {
            // For GLB, try loading as scene first
            if let scene = try? SCNScene(url: url, options: [.checkConsistency: false]) {
                return MDLAsset(scnScene: scene)
            }
        }

        // Standard MDL loading for OBJ and fallback
        let asset = MDLAsset(url: url)
        guard asset.count > 0 else { return nil }
        return asset
    }

    /// Setup scene with camera, lighting for thumbnail rendering
    private func setupSceneForThumbnail(_ scene: SCNScene) {
        // Calculate bounding sphere to ensure consistent model sizing
        let (minBound, maxBound) = scene.rootNode.boundingBox
        let center = SCNVector3(
            (minBound.x + maxBound.x) / 2,
            (minBound.y + maxBound.y) / 2,
            (minBound.z + maxBound.z) / 2
        )

        // Calculate bounding sphere radius (diagonal of bounding box / 2)
        let dx = maxBound.x - minBound.x
        let dy = maxBound.y - minBound.y
        let dz = maxBound.z - minBound.z
        let diagonalSquared = dx * dx + dy * dy + dz * dz
        let boundingSphereRadius = sqrt(diagonalSquared) / 2.0

        // Calculate camera distance to fit the model consistently
        // Using FOV and desired fill percentage
        let fov: CGFloat = 45
        let fovRadians = fov * .pi / 180.0
        let fillFactor: CGFloat = 0.7  // Model should fill ~70% of frame
        let tanHalfFov = tan(fovRadians / 2.0)
        let distance = boundingSphereRadius / (tanHalfFov * fillFactor)

        // Create and position camera
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.fieldOfView = fov
        // Position camera with slight offset for 3/4 view angle
        cameraNode.position = SCNVector3(
            Float(CGFloat(center.x) + distance * 0.35),
            Float(CGFloat(center.y) + distance * 0.2),
            Float(CGFloat(center.z) + distance * 0.85)
        )
        cameraNode.look(at: center)
        scene.rootNode.addChildNode(cameraNode)

        // Add ambient light
        let ambientLight = SCNNode()
        ambientLight.light = SCNLight()
        ambientLight.light?.type = .ambient
        ambientLight.light?.intensity = 400
        ambientLight.light?.color = NSColor.white
        scene.rootNode.addChildNode(ambientLight)

        // Add directional light
        let directionalLight = SCNNode()
        directionalLight.light = SCNLight()
        directionalLight.light?.type = .directional
        directionalLight.light?.intensity = 800
        directionalLight.light?.color = NSColor.white
        directionalLight.position = SCNVector3(5, 10, 10)
        directionalLight.look(at: center)
        scene.rootNode.addChildNode(directionalLight)

        // Set background color
        scene.background.contents = NSColor(white: 0.15, alpha: 1.0)
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
